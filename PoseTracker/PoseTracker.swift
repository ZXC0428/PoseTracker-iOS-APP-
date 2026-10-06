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

/// App 支援的運動項目。
enum ExerciseType: String, CaseIterable, Identifiable {
    case squat
    case jumpingJack
    case lunge

    var id: Self { self }

    var title: String {
        switch self {
        case .squat: "深蹲"
        case .jumpingJack: "開合跳"
        case .lunge: "弓箭步"
        }
    }

    var systemImage: String {
        switch self {
        case .squat: "figure.strengthtraining.traditional"
        case .jumpingJack: "figure.jumprope"
        case .lunge: "figure.flexibility"
        }
    }
}

/// 關卡難度、目標次數與每次觸發姿勢需要維持的時間。
enum Level: String, CaseIterable, Identifiable {
    case easy
    case medium
    case hard

    var id: Self { self }

    var title: String {
        switch self {
        case .easy: "簡單"
        case .medium: "中等"
        case .hard: "困難"
        }
    }

    var targetCount: Int {
        switch self {
        case .easy, .medium: 5
        case .hard: 8
        }
    }

    var holdDuration: TimeInterval {
        switch self {
        case .easy: 0
        case .medium: 2
        case .hard: 3
        }
    }

    /// 開合跳不維持姿勢，改以張開／合攏的完成速度區分難度。
    var jumpingJackTransitionLimit: TimeInterval {
        switch self {
        case .easy: 1.2
        case .medium: 0.9
        case .hard: 0.7
        }
    }

    var next: Level? {
        switch self {
        case .easy: .medium
        case .medium: .hard
        case .hard: nil
        }
    }

    var rank: Int {
        switch self {
        case .easy: 0
        case .medium: 1
        case .hard: 2
        }
    }
}

/// 從單張影像的人體骨架整理出的必要數值。
private struct PoseMetrics {
    let leftKneeAngle: Double?
    let rightKneeAngle: Double?
    /// 左右髖關節的平均垂直位置；Vision 座標由下往上增加。
    let hipHeight: CGFloat
    /// 可見腿部由髖到腳踝的平均長度，用來讓下降門檻隨拍攝距離縮放。
    let legLength: CGFloat
    let hipWidth: CGFloat?
    let ankleDistance: CGFloat?
    let leftAnkleHeight: CGFloat?
    let rightAnkleHeight: CGFloat?
    let leftWristHeight: CGFloat?
    let rightWristHeight: CGFloat?
    let neckHeight: CGFloat?

    var kneeAngle: Double? {
        switch (leftKneeAngle, rightKneeAngle) {
        case let (left?, right?) where abs(left - right) < 40: (left + right) / 2
        case let (left?, nil): left
        case let (nil, right?): right
        default: nil
        }
    }
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
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
    @Published private(set) var exerciseType: ExerciseType = .squat
    @Published private(set) var level: Level = .easy
    @Published private(set) var holdSecondsRemaining: Int?
    /// 每種運動分開記錄目前已解鎖的最高難度。
    @Published private(set) var highestUnlockedLevel: [ExerciseType: Level] = [
        .squat: .easy,
        .jumpingJack: .easy,
        .lunge: .easy
    ]

    var targetCount: Int { level.targetCount }
    var isLevelComplete: Bool { squatCount >= targetCount }

    func isLevelUnlocked(_ candidate: Level, for exercise: ExerciseType) -> Bool {
        candidate.rank <= (highestUnlockedLevel[exercise] ?? .easy).rank
    }

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
    // MARK: 深蹲狀態機暫存

    /// 使用者站直時的髖部高度基準。
    private var standingHipHeight: CGFloat?
    /// 站直時的腿長基準，避免自拍距離改變時使用固定畫面比例誤判。
    private var standingLegLength: CGFloat?
    /// 要求連續多幀成立，避免單幀雜訊造成誤計。
    private var loweredFrameCount = 0
    private var standingFrameCount = 0
    /// 短暫失去關節時先保留狀態，避免 UI 每幀閃爍。
    private var missingFrameCount = 0
    private var holdTimer: Timer?
    private var holdStartedAt: Date?
    /// 避免 0.1 秒更新一次的 Timer 在同一秒重複播報。
    private var lastSpokenHoldSecond: Int?
    private var activeLungeUsesLeftLeg = true
    /// 弓箭步角度短暫抖動時保留倒數，連續多幀失效才真正取消。
    private var lungeInvalidFrameCount = 0
    private var jumpingJackClosedAt: Date?
    private var jumpingJackOpenedAt: Date?
    private var leftGroundAnkleHeight: CGFloat?
    private var rightGroundAnkleHeight: CGFloat?
    private var jumpingJackSawTakeoff = false
    private var progressUserID: UUID?

    override init() { super.init() }

    /// 登入後載入該使用者各運動已解鎖的最高關卡。
    @MainActor
    func configureProgress(for userID: UUID) {
        progressUserID = userID
        let defaults: [ExerciseType: Level] = [
            .squat: .easy,
            .jumpingJack: .easy,
            .lunge: .easy
        ]
        let saved = (try? DatabaseManager.shared.fetchProgress(for: userID)) ?? [:]
        highestUnlockedLevel = defaults.merging(saved) { _, saved in saved }
        if !isLevelUnlocked(level, for: exerciseType) {
            level = highestUnlockedLevel[exerciseType] ?? .easy
        }
    }

    /// 請求相機權限並啟動預設後置鏡頭。
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
            self.configureSession(position: .back)
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
        cancelHold()
        squatCount = 0
        phase = kneeAngle == nil ? .searching : .standing
        standingHipHeight = nil
        standingLegLength = nil
        loweredFrameCount = 0
        standingFrameCount = 0
        missingFrameCount = 0
        lungeInvalidFrameCount = 0
        resetJumpingJackTracking()
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    @MainActor
    func selectExercise(_ exercise: ExerciseType) {
        guard exerciseType != exercise else { return }
        exerciseType = exercise
        if !isLevelUnlocked(level, for: exercise) {
            level = highestUnlockedLevel[exercise] ?? .easy
        }
        reset()
    }

    @MainActor
    func selectLevel(_ newLevel: Level) {
        guard level != newLevel,
              isLevelUnlocked(newLevel, for: exerciseType)
        else { return }
        level = newLevel
        reset()
    }

    /// 在自拍前鏡頭與拍攝他人的後鏡頭之間切換。
    @MainActor
    func toggleCamera() {
        cancelHoldAndSpeech()
        cameraPosition = cameraPosition == .front ? .back : .front
        let requestedPosition = cameraPosition
        kneeAngle = nil
        phase = .searching
        standingHipHeight = nil
        standingLegLength = nil
        loweredFrameCount = 0
        standingFrameCount = 0
        missingFrameCount = 0
        lungeInvalidFrameCount = 0
        resetJumpingJackTracking()

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

        isConfigured = true
    }

    /// 對一個 CMSampleBuffer 執行 Vision 人體姿態請求。
    private func process(_ sampleBuffer: CMSampleBuffer) {
        guard !isProcessingFrame,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        isProcessingFrame = true
        defer { isProcessingFrame = false }

        // connection 已經把直向與前鏡頭鏡像套用到輸出影像；若在這裡再用
        // .upMirrored，Vision 會把自拍畫面鏡像第二次，造成骨架座標不穩。
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up
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

        let leftHip = reliablePoint(points[.leftHip])
        let rightHip = reliablePoint(points[.rightHip])
        let visibleHips = [leftHip, rightHip].compactMap { $0 }
        guard !visibleHips.isEmpty else { return nil }

        let legLengths = [
            distance(from: leftHip, to: reliablePoint(points[.leftAnkle])),
            distance(from: rightHip, to: reliablePoint(points[.rightAnkle]))
        ].compactMap { $0 }
        let leftAnkle = reliablePoint(points[.leftAnkle])
        let rightAnkle = reliablePoint(points[.rightAnkle])

        return PoseMetrics(
            leftKneeAngle: leftAngle,
            rightKneeAngle: rightAngle,
            hipHeight: visibleHips.map(\.location.y).reduce(0, +)
                / CGFloat(visibleHips.count),
            legLength: legLengths.isEmpty
                ? 0
                : legLengths.reduce(0, +) / CGFloat(legLengths.count),
            hipWidth: horizontalDistance(from: leftHip, to: rightHip),
            ankleDistance: horizontalDistance(from: leftAnkle, to: rightAnkle),
            leftAnkleHeight: leftAnkle?.location.y,
            rightAnkleHeight: rightAnkle?.location.y,
            leftWristHeight: reliablePoint(points[.leftWrist])?.location.y,
            rightWristHeight: reliablePoint(points[.rightWrist])?.location.y,
            neckHeight: reliablePoint(points[.neck])?.location.y
        )
    }

    /// 自拍時其中一側常被身體遮住；只保留足夠可信的可見關節。
    private func reliablePoint(_ point: VNRecognizedPoint?) -> VNRecognizedPoint? {
        guard let point, point.confidence >= 0.3 else { return nil }
        return point
    }

    private func distance(
        from first: VNRecognizedPoint?,
        to second: VNRecognizedPoint?
    ) -> CGFloat? {
        guard let first, let second else { return nil }
        return hypot(
            first.location.x - second.location.x,
            first.location.y - second.location.y
        )
    }

    private func horizontalDistance(
        from first: VNRecognizedPoint?,
        to second: VNRecognizedPoint?
    ) -> CGFloat? {
        guard let first, let second else { return nil }
        return abs(first.location.x - second.location.x)
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
            self.missingFrameCount = 0
            self.kneeAngle = metrics.kneeAngle

            switch self.exerciseType {
            case .squat:
                self.updateSquat(with: metrics)
            case .jumpingJack:
                self.updateJumpingJack(with: metrics)
            case .lunge:
                self.updateLunge(with: metrics)
            }
        }
    }

    private func updateSquat(with metrics: PoseMetrics) {
        guard let angle = metrics.kneeAngle, metrics.legLength > 0 else {
            cancelTriggeredPose()
            return
        }

        // 站直門檻：膝角大於 150 度。
        if angle > 150 {
            if phase == .lowered {
                    // 從 lowered 回到 standing 必須連續三幀才完成一次。
                standingFrameCount += 1
                if standingFrameCount >= 3 {
                    completeRepetition()
                    standingHipHeight = metrics.hipHeight
                    standingLegLength = metrics.legLength
                    }
                } else {
                    // 尚未下蹲時持續緩慢校正個人的站立髖部高度。
                cancelHoldAndSpeech()
                phase = .standing
                standingHipHeight = smoothedStandingHeight(
                        current: metrics.hipHeight
                    )
                standingLegLength = smoothedStandingLegLength(
                        current: metrics.legLength
                    )
                loweredFrameCount = 0
                }
            return
        }

        standingFrameCount = 0
            // 下蹲門檻：膝角小於 110 度，且髖部下降至少站立腿長的 10%。
            // 使用人體比例而非固定畫面高度，自拍距離遠近都能維持相近靈敏度。
        guard angle < 110,
                  let standingHeight = self.standingHipHeight,
                  let standingLegLength = self.standingLegLength,
                  metrics.hipHeight < standingHeight - standingLegLength * 0.10
            else {
            cancelTriggeredPose()
            return
            }

        beginOrContinueHold()
    }

    private func updateJumpingJack(with metrics: PoseMetrics) {
        guard let leftWrist = metrics.leftWristHeight,
              let rightWrist = metrics.rightWristHeight,
              let neck = metrics.neckHeight,
              let ankleDistance = metrics.ankleDistance,
              let hipWidth = metrics.hipWidth,
              let leftAnkleHeight = metrics.leftAnkleHeight,
              let rightAnkleHeight = metrics.rightAnkleHeight,
              hipWidth > 0
        else {
            cancelTriggeredPose()
            return
        }

        let isOpen = leftWrist > neck && rightWrist > neck
            && ankleDistance > hipWidth * 2
        let isClosed = leftWrist < neck && rightWrist < neck
            && ankleDistance < hipWidth * 1.5

        let now = Date()

        // 合攏站立時建立左右腳的地面高度基準。必須兩腳同步高於基準，
        // 才視為真的離地，避免慢慢把手腳張開也被當成開合跳。
        if phase == .standing,
           let leftGroundAnkleHeight,
           let rightGroundAnkleHeight {
            let takeoffThreshold = max(metrics.legLength * 0.025, 0.01)
            if leftAnkleHeight > leftGroundAnkleHeight + takeoffThreshold,
               rightAnkleHeight > rightGroundAnkleHeight + takeoffThreshold {
                jumpingJackSawTakeoff = true
            }
        }

        if isOpen, phase == .standing {
            guard let closedAt = jumpingJackClosedAt,
                  now.timeIntervalSince(closedAt) <= level.jumpingJackTransitionLimit,
                  jumpingJackSawTakeoff
            else {
                // 太慢或沒有離地：保持準備狀態，不接受這次張開動作。
                jumpingJackClosedAt = nil
                jumpingJackSawTakeoff = false
                return
            }
            phase = .lowered
            jumpingJackOpenedAt = now
        } else if isClosed {
            cancelHoldAndSpeech()
            if phase == .lowered,
               let openedAt = jumpingJackOpenedAt,
               now.timeIntervalSince(openedAt) <= level.jumpingJackTransitionLimit {
                completeRepetition()
            }
            phase = .standing
            jumpingJackClosedAt = now
            jumpingJackOpenedAt = nil
            jumpingJackSawTakeoff = false
            leftGroundAnkleHeight = smoothedGroundHeight(
                previous: leftGroundAnkleHeight,
                current: leftAnkleHeight
            )
            rightGroundAnkleHeight = smoothedGroundHeight(
                previous: rightGroundAnkleHeight,
                current: rightAnkleHeight
            )
        } else if phase != .lowered {
            cancelHoldAndSpeech()
        }
    }

    private func smoothedGroundHeight(
        previous: CGFloat?,
        current: CGFloat
    ) -> CGFloat {
        guard let previous else { return current }
        return previous * 0.9 + current * 0.1
    }

    private func resetJumpingJackTracking() {
        jumpingJackClosedAt = nil
        jumpingJackOpenedAt = nil
        leftGroundAnkleHeight = nil
        rightGroundAnkleHeight = nil
        jumpingJackSawTakeoff = false
    }

    private func updateLunge(with metrics: PoseMetrics) {
        let visibleAngles = [metrics.leftKneeAngle, metrics.rightKneeAngle]
            .compactMap { $0 }
        guard let ankleDistance = metrics.ankleDistance,
              let hipWidth = metrics.hipWidth,
              hipWidth > 0,
              !visibleAngles.isEmpty
        else {
            handleInvalidLungePose()
            return
        }

        let isBent = visibleAngles.min()! < 100 && ankleDistance > hipWidth * 1.2
        let activeAngle = activeLungeUsesLeftLeg
            ? metrics.leftKneeAngle
            : metrics.rightKneeAngle
        let isStanding = (activeAngle ?? visibleAngles.min()!) > 150

        if isBent {
            lungeInvalidFrameCount = 0
            standingFrameCount = 0
            activeLungeUsesLeftLeg = (metrics.leftKneeAngle ?? 181)
                < (metrics.rightKneeAngle ?? 181)
            beginOrContinueHold()
        } else if isStanding {
            if holdStartedAt != nil {
                handleInvalidLungePose()
                return
            }
            lungeInvalidFrameCount = 0
            if phase == .lowered {
                standingFrameCount += 1
                guard standingFrameCount >= 3 else { return }
                completeRepetition()
            } else {
                cancelHoldAndSpeech()
                phase = .standing
            }
        } else if phase != .lowered {
            handleInvalidLungePose()
        }
    }

    private func handleInvalidLungePose() {
        guard phase != .lowered else { return }
        lungeInvalidFrameCount += 1
        // 約 0.25 秒的容錯，吸收角度臨界值抖動與短暫關節遺失。
        guard lungeInvalidFrameCount >= 8 else { return }
        lungeInvalidFrameCount = 0
        standingFrameCount = 0
        cancelTriggeredPose()
    }

    /// 觸發姿勢持續成立時啟動倒數；簡單關卡會立即通過。
    private func beginOrContinueHold() {
        guard phase != .lowered else { return }
        if holdStartedAt == nil {
            loweredFrameCount += 1
            guard loweredFrameCount >= 3 else { return }
        }
        guard level.holdDuration > 0 else {
            phase = .lowered
            return
        }
        guard holdStartedAt == nil else { return }

        holdStartedAt = Date()
        updateHoldCountdown(to: Int(ceil(level.holdDuration)))
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
            [weak self] timer in
            guard let self, let startedAt = self.holdStartedAt else {
                timer.invalidate()
                return
            }
            let remaining = self.level.holdDuration - Date().timeIntervalSince(startedAt)
            if remaining <= 0 {
                self.phase = .lowered
                self.cancelHold()
            } else {
                self.updateHoldCountdown(to: Int(ceil(remaining)))
            }
        }
    }

    /// 同步畫面文字並以台灣中文念出新的剩餘秒數。
    private func updateHoldCountdown(to seconds: Int) {
        holdSecondsRemaining = seconds
        guard seconds > 0, lastSpokenHoldSecond != seconds else { return }
        lastSpokenHoldSecond = seconds

        let utterance = AVSpeechUtterance(string: "\(seconds)")
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        utterance.rate = 0.48
        speechSynthesizer.speak(utterance)
    }

    private func cancelTriggeredPose() {
        loweredFrameCount = 0
        if phase != .lowered {
            cancelHoldAndSpeech()
        }
    }

    private func cancelHoldAndSpeech() {
        if holdStartedAt != nil {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        cancelHold()
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdStartedAt = nil
        holdSecondsRemaining = nil
        lastSpokenHoldSecond = nil
    }

    private func completeRepetition() {
        squatCount += 1
        speakCount(squatCount)
        if squatCount == targetCount, let nextLevel = level.next {
            let currentUnlocked = highestUnlockedLevel[exerciseType] ?? .easy
            if nextLevel.rank > currentUnlocked.rank {
                highestUnlockedLevel[exerciseType] = nextLevel
                if let progressUserID {
                    try? DatabaseManager.shared.saveProgress(
                        userID: progressUserID,
                        exerciseType: exerciseType,
                        level: nextLevel
                    )
                }
            }
        }
        phase = .standing
        loweredFrameCount = 0
        standingFrameCount = 0
        lungeInvalidFrameCount = 0
    }

    /// 以指數平滑更新站立基準，降低人體骨架座標的微小抖動。
    private func smoothedStandingHeight(current: CGFloat) -> CGFloat {
        guard let previous = standingHipHeight else { return current }
        return previous * 0.9 + current * 0.1
    }

    private func smoothedStandingLegLength(current: CGFloat) -> CGFloat {
        guard let previous = standingLegLength else { return current }
        return previous * 0.9 + current * 0.1
    }

    /// 姿態不完整時提供約數幀的容錯，避免短暫遮擋造成狀態閃爍。
    private func updateMissingPose() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.missingFrameCount += 1

            // 連續八個分析幀都無法取得姿態，才判定人體已離開畫面。
            guard self.missingFrameCount >= 8 else { return }
            self.cancelHoldAndSpeech()
            self.kneeAngle = nil
            self.phase = .searching
            self.loweredFrameCount = 0
            self.standingFrameCount = 0
            self.resetJumpingJackTracking()
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
