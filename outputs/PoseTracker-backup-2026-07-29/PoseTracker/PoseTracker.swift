import AVFoundation
import Combine
import ImageIO
import Vision

/// 深蹲判斷狀態機。
///
/// searching：沒有取得完整且可信的雙腿姿態。
/// standing：已看到站直姿勢，可建立髖部高度基準。
/// lowered：已確認雙膝彎曲且髖部下降，等待重新站直。
enum SquatPhase {
    case searching
    case standing
    case lowered
}

/// 從單張影像的人體骨架整理出的必要數值。
private struct PoseMetrics {
    /// 左右膝角度的平均值。
    let kneeAngle: Double
    /// 左右髖關節的平均垂直位置；Vision 座標由下往上增加。
    let hipHeight: CGFloat
}

/// 相機、Vision 人體姿態偵測、深蹲狀態機與語音播報的核心控制器。
final class PoseTracker: NSObject, ObservableObject {
    /// 相機預覽與影像輸出共用同一個 Session。
    let session = AVCaptureSession()

    // MARK: 提供給 SwiftUI 顯示的狀態

    @Published private(set) var kneeAngle: Double?
    @Published private(set) var squatCount = 0
    @Published private(set) var phase: SquatPhase = .searching
    @Published private(set) var authorizationDenied = false
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .front

    // MARK: 相機與分析工具

    /// 相機設定與 startRunning 不能阻塞主執行緒，因此使用專用 Queue。
    private let sessionQueue = DispatchQueue(label: "com.posetracker.camera.session")
    /// 影像幀與 Vision 分析在另一條序列 Queue 中執行。
    private let videoQueue = DispatchQueue(label: "com.posetracker.camera.frames")
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    private var isConfigured = false
    /// 防止上一幀尚未分析完又送入下一幀。
    private var isProcessingFrame = false
    /// 前鏡頭影像需要鏡像；後鏡頭不需要。
    private var imageOrientation: CGImagePropertyOrientation = .upMirrored

    // MARK: 深蹲狀態機暫存

    /// 使用者站直時的髖部高度基準。
    private var standingHipHeight: CGFloat?
    /// 要求連續多幀成立，避免單幀雜訊造成誤計。
    private var loweredFrameCount = 0
    private var standingFrameCount = 0
    /// 短暫失去關節時先保留狀態，避免 UI 每幀閃爍。
    private var missingFrameCount = 0

    /// 請求相機權限並啟動前鏡頭。
    /// UI 狀態在 MainActor 更新，相機工作則派到 sessionQueue。
    @MainActor
    func start() async {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            granted = false
        }

        authorizationDenied = !granted
        guard granted else { return }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession(position: .front)
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    /// 停止擷取；已設定的 Session 可在下次 start 時重用。
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// 清除本次計數與深蹲狀態，但不影響使用者歷史紀錄。
    @MainActor
    func reset() {
        squatCount = 0
        phase = kneeAngle == nil ? .searching : .standing
        standingHipHeight = nil
        loweredFrameCount = 0
        standingFrameCount = 0
        missingFrameCount = 0
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    /// 在自拍前鏡頭與拍攝他人的後鏡頭之間切換。
    @MainActor
    func toggleCamera() {
        cameraPosition = cameraPosition == .front ? .back : .front
        let requestedPosition = cameraPosition
        kneeAngle = nil
        phase = .searching
        standingHipHeight = nil
        loweredFrameCount = 0
        standingFrameCount = 0
        missingFrameCount = 0

        sessionQueue.async { [weak self] in
            self?.configureSession(position: requestedPosition)
        }
    }

    /// 建立或切換 AVCaptureSession 的相機輸入與影像輸出。
    private func configureSession(position: AVCaptureDevice.Position) {
        session.beginConfiguration()
        session.sessionPreset = .high
        defer { session.commitConfiguration() }

        // 移除舊鏡頭輸入，但保留 VideoDataOutput。
        for input in session.inputs {
            session.removeInput(input)
        }

        // 依指定位置尋找廣角相機並加入 Session。
        guard
            let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: position
            ),
            let input = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(input)
        else {
            return
        }
        session.addInput(input)

        // 首次建立影像輸出；切鏡頭時直接重用，避免重複 Delegate。
        let output: AVCaptureVideoDataOutput
        if let existingOutput = session.outputs.compactMap({
            $0 as? AVCaptureVideoDataOutput
        }).first {
            output = existingOutput
        } else {
            output = AVCaptureVideoDataOutput()
            // 分析速度跟不上時丟棄舊幀，確保畫面反應維持即時。
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            output.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
        }

        if let connection = output.connection(with: .video) {
            // 專案鎖定直向，因此把輸出旋轉 90 度。
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            // 自拍預覽符合鏡子直覺；後鏡頭維持正常方向。
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = position == .front
            }
        }

        imageOrientation = position == .front ? .upMirrored : .up
        isConfigured = true
    }

    /// 對一個 CMSampleBuffer 執行 Vision 人體姿態請求。
    private func process(_ sampleBuffer: CMSampleBuffer) {
        guard !isProcessingFrame,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        isProcessingFrame = true
        defer { isProcessingFrame = false }

        // imageOrientation 依目前前／後鏡頭決定是否鏡像。
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: imageOrientation
        )

        do {
            try handler.perform([poseRequest])
            // 只追蹤 Vision 找到的第一個人。
            guard let observation = poseRequest.results?.first,
                  let metrics = try poseMetrics(from: observation)
            else {
                updateMissingPose()
                return
            }
            update(with: metrics)
        } catch {
            updateMissingPose()
        }
    }

    /// 從人體骨架取出左右腿角度與髖部高度。
    ///
    /// 優先平均左右腿；若只有一側可信，則使用清楚的那一側。
    ///
    /// 當左右腿都可見但角度差過大時仍拒絕該幀，避免單腳動作誤判。
    /// 若其中一側只是被遮擋，則可依另一側繼續追蹤；後續仍必須通過
    /// 「髖部確實下降」條件，因此單純抬腿不會形成完整深蹲。
    private func poseMetrics(
        from observation: VNHumanBodyPoseObservation
    ) throws -> PoseMetrics? {
        let points = try observation.recognizedPoints(.all)

        let leftAngle = angle(
            hip: points[.leftHip],
            knee: points[.leftKnee],
            ankle: points[.leftAnkle]
        )
        let rightAngle = angle(
            hip: points[.rightHip],
            knee: points[.rightKnee],
            ankle: points[.rightAnkle]
        )

        let resolvedAngle: Double
        switch (leftAngle, rightAngle) {
        case let (left?, right?) where abs(left - right) < 40:
            resolvedAngle = (left + right) / 2
        case let (left?, nil):
            resolvedAngle = left
        case let (nil, right?):
            resolvedAngle = right
        default:
            return nil
        }

        guard let leftHip = points[.leftHip],
              let rightHip = points[.rightHip],
              leftHip.confidence >= 0.3,
              rightHip.confidence >= 0.3
        else { return nil }

        return PoseMetrics(
            kneeAngle: resolvedAngle,
            hipHeight: (leftHip.location.y + rightHip.location.y) / 2
        )
    }

    /// 計算 hip-knee-ankle 在膝關節形成的夾角。
    ///
    /// 使用兩個以膝蓋為起點的向量，透過：
    /// cos θ = (A · B) / (|A| × |B|)
    /// 得到 0～180 度的膝角度。
    private func angle(
        hip: VNRecognizedPoint?,
        knee: VNRecognizedPoint?,
        ankle: VNRecognizedPoint?
    ) -> Double? {
        // 信心值過低通常代表關節被遮擋或已超出畫面。
        let minimumConfidence: VNConfidence = 0.3
        guard let hip, let knee, let ankle,
              hip.confidence >= minimumConfidence,
              knee.confidence >= minimumConfidence,
              ankle.confidence >= minimumConfidence
        else { return nil }

        let vectorA = CGVector(
            dx: hip.location.x - knee.location.x,
            dy: hip.location.y - knee.location.y
        )
        let vectorB = CGVector(
            dx: ankle.location.x - knee.location.x,
            dy: ankle.location.y - knee.location.y
        )
        // 點積與向量長度用來求兩向量間的角度。
        let dot = vectorA.dx * vectorB.dx + vectorA.dy * vectorB.dy
        let magnitudeA = hypot(vectorA.dx, vectorA.dy)
        let magnitudeB = hypot(vectorB.dx, vectorB.dy)
        guard magnitudeA > 0, magnitudeB > 0 else { return nil }

        // 浮點誤差可能略超出 [-1, 1]，先夾住再交給 acos。
        let cosine = max(-1, min(1, dot / (magnitudeA * magnitudeB)))
        return acos(cosine) * 180 / .pi
    }

    /// 將每幀姿態數值送進深蹲狀態機。
    private func update(with metrics: PoseMetrics) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let angle = metrics.kneeAngle
            self.missingFrameCount = 0
            self.kneeAngle = angle

            // 站直門檻：膝角大於 150 度。
            if angle > 150 {
                if self.phase == .lowered {
                    // 從 lowered 回到 standing 必須連續三幀才完成一次。
                    self.standingFrameCount += 1
                    if self.standingFrameCount >= 3 {
                        self.squatCount += 1
                        self.speakCount(self.squatCount)
                        self.phase = .standing
                        self.loweredFrameCount = 0
                        self.standingFrameCount = 0
                        self.standingHipHeight = metrics.hipHeight
                    }
                } else {
                    // 尚未下蹲時持續緩慢校正個人的站立髖部高度。
                    self.phase = .standing
                    self.standingHipHeight = self.smoothedStandingHeight(
                        current: metrics.hipHeight
                    )
                    self.loweredFrameCount = 0
                }
                return
            }

            self.standingFrameCount = 0
            // 下蹲門檻：雙膝平均角度小於 110 度，
            // 且髖部比站立基準下降至少畫面高度的 6%。
            guard angle < 110,
                  let standingHeight = self.standingHipHeight,
                  metrics.hipHeight < standingHeight - 0.06
            else {
                self.loweredFrameCount = 0
                return
            }

            // 連續三幀符合才正式標記為 lowered。
            self.loweredFrameCount += 1
            if self.loweredFrameCount >= 3 {
                self.phase = .lowered
            }
        }
    }

    /// 以指數平滑更新站立基準，降低人體骨架座標的微小抖動。
    private func smoothedStandingHeight(current: CGFloat) -> CGFloat {
        guard let previous = standingHipHeight else { return current }
        return previous * 0.9 + current * 0.1
    }

    /// 姿態不完整時提供約數幀的容錯，避免短暫遮擋造成狀態閃爍。
    private func updateMissingPose() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.missingFrameCount += 1

            // 連續八個分析幀都無法取得姿態，才判定人體已離開畫面。
            guard self.missingFrameCount >= 8 else { return }
            self.kneeAngle = nil
            self.phase = .searching
            self.loweredFrameCount = 0
            self.standingFrameCount = 0
        }
    }

    /// 每完成一次，以台灣中文語音讀出目前總次數。
    private func speakCount(_ count: Int) {
        let utterance = AVSpeechUtterance(string: "\(count)")
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        utterance.rate = 0.48
        speechSynthesizer.speak(utterance)
    }
}

/// 接收 AVCaptureVideoDataOutput 的每一幀相機影像。
extension PoseTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        process(sampleBuffer)
    }
}
