import SwiftUI

/// App 的主畫面。
///
/// 這裡只負責呈現 UI 與轉送使用者操作；相機及 AI 判斷交給 PoseTracker，
/// 使用者與成績則交給 UserSessionStore，避免把所有邏輯塞在 View 裡。
struct ContentView: View {
    @ObservedObject var authManager: AuthManager
    let configuration: TrainingConfiguration
    let onChooseWorkout: () -> Void
    let onStartNextLevel: (Level) -> Void
    /// 姿態偵測器的生命週期與主畫面相同。
    @StateObject private var poseTracker = PoseTracker()
    /// 管理本次使用者狀態；完成的訓練會另存到 SQLite。
    @StateObject private var userStore: UserSessionStore
    /// 控制使用者管理 Sheet 與記錄完成提示。
    @State private var showingUsers = false
    @State private var showingDatabaseError = false
    @State private var activeRecordID: UUID?
    @State private var showingLevelCompletion = false
    /// 進入本次相機畫面前，今天同運動、同難度已完成的累積次數。
    @State private var previousTodayCount = 0

    init(
        authManager: AuthManager,
        user: LocalUser,
        configuration: TrainingConfiguration,
        onChooseWorkout: @escaping () -> Void,
        onStartNextLevel: @escaping (Level) -> Void
    ) {
        self.authManager = authManager
        self.configuration = configuration
        self.onChooseWorkout = onChooseWorkout
        self.onStartNextLevel = onStartNextLevel
        _userStore = StateObject(wrappedValue: UserSessionStore(user: user))
    }

    var body: some View {
        ZStack {
            // 相機畫面鋪滿整個背景。
            CameraPreview(session: poseTracker.session)
                .ignoresSafeArea()

            // 漸層讓白色文字在各種相機背景上都保持清楚。
            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // 主要資訊疊加在相機畫面上方。
            VStack(spacing: 20) {
                header
                workoutSettingsButton
                statusCard
                Spacer()
                actionButtons
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            if let seconds = poseTracker.holdSecondsRemaining {
                holdCountdownOverlay(seconds: seconds)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .allowsHitTesting(false)
            }

            // 權限遭拒時，遮住無法使用的相機畫面並提供說明。
            if poseTracker.authorizationDenied {
                permissionMessage
            }
        }
        .animation(.easeInOut(duration: 0.18), value: poseTracker.holdSecondsRemaining)
        .task {
            // 畫面出現後請求權限、設定並啟動相機。
            loadPreviousTodayCount()
            poseTracker.configureProgress(for: userStore.user.id)
            poseTracker.selectExercise(configuration.exerciseType)
            poseTracker.selectLevel(configuration.level)
            await poseTracker.start()
            await userStore.syncPendingRecords()
        }
        .onDisappear {
            // 離開畫面時停止相機，節省電力與裝置溫度。
            poseTracker.stop()
            if let recordID = activeRecordID, poseTracker.squatCount > 0 {
                let finalCount = poseTracker.squatCount
                persistDraft(count: finalCount)
                Task {
                    _ = await userStore.finishDraft(
                        id: recordID,
                        count: finalCount,
                        isCompleted: finalCount >= poseTracker.targetCount
                    )
                }
            }
        }
        .onChange(of: poseTracker.squatCount) { _, newCount in
            if newCount == 0 {
                activeRecordID = nil
            } else {
                persistDraft(count: newCount)
                if newCount == poseTracker.targetCount {
                    showingLevelCompletion = true
                }
            }
        }
        .confirmationDialog(
            "關卡通過！",
            isPresented: $showingLevelCompletion,
            titleVisibility: .visible
        ) {
            if let nextLevel = poseTracker.level.next {
                Button("挑戰下一關：\(nextLevel.title)") {
                    finishAndStartNextLevel(nextLevel)
                }
            }
            Button("繼續目前難度") {}
            Button("返回選擇訓練") {
                finishAndReturnToSelection()
            }
        } message: {
            if let nextLevel = poseTracker.level.next {
                Text("已完成\(poseTracker.level.title)關卡。要繼續累積次數，還是進入\(nextLevel.title)關卡？")
            } else {
                Text("已完成最高難度。可以繼續累積次數，或結束本次訓練。")
            }
        }
        // 使用者按右上角人物按鈕後顯示管理頁。
        .sheet(isPresented: $showingUsers) {
            UserManagerView(store: userStore, authManager: authManager)
        }
        .alert("無法儲存訓練", isPresented: $showingDatabaseError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(userStore.databaseErrorMessage ?? "請稍後再試。")
        }
    }

    /// 主畫面只保留一列目前設定，避免兩組選擇器長駐而遮住相機。
    private var workoutSettingsButton: some View {
        Button {
            onChooseWorkout()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: poseTracker.exerciseType.systemImage)
                Text(poseTracker.exerciseType.title)
                    .fontWeight(.semibold)
                Text("·")
                    .foregroundStyle(.white.opacity(0.55))
                Text(poseTracker.level.title)
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.mint)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(Color.black.opacity(0.34), in: Capsule())
            .overlay {
                Capsule().stroke(.white.opacity(0.18), lineWidth: 1)
            }
        }
        .accessibilityLabel("選擇運動項目與關卡難度")
    }

    /// 頂端品牌與目前使用者；鏡頭切換移至底部主要操作列。
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("POSE TRACKER")
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(.mint)
                Text("AI 運動計數器")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            Spacer()
            Button {
                showingUsers = true
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title3)
                    Text(userStore.user.displayName)
                        .font(.system(size: 9, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("使用者管理")
        }
    }

    /// 即時顯示平均膝角度、完成次數與狀態提示。
    private var statusCard: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("膝關節角度")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(poseTracker.kneeAngle.map { "\(Int($0.rounded()))°" } ?? "--°")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    Text("本次進度")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(poseTracker.isLevelComplete
                         ? "\(poseTracker.squatCount) 次"
                         : "\(poseTracker.squatCount)/\(poseTracker.targetCount)")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                        .foregroundStyle(.mint)
                        .contentTransition(.numericText())
                    Text("今日累積 \(previousTodayCount + poseTracker.squatCount) 次")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.82))
                        .contentTransition(.numericText())
                }
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(poseTracker.phase.color)
                    .frame(width: 9, height: 9)
                Text(poseTracker.phase.message(for: poseTracker.exerciseType))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(poseTracker.cameraPosition == .front ? "自拍" : "拍攝他人")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.7))
            }


            if poseTracker.isLevelComplete {
                Text("關卡完成！")
                    .font(.title3.bold())
                    .foregroundStyle(.mint)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color.black.opacity(0.34),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
    }

    private func holdCountdownOverlay(seconds: Int) -> some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                Text("請維持姿勢")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("\(seconds)")
                    .font(.system(size: 150, weight: .black, design: .rounded))
                    .minimumScaleFactor(0.65)
                    .foregroundStyle(.yellow)
                    .contentTransition(.numericText())
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                Text("秒")
                    .font(.title3.bold())
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("請維持姿勢，剩餘 \(seconds) 秒")
    }

    /// 訓練會自動保存，因此底部只保留鏡頭切換。
    private var actionButtons: some View {
        Button {
            poseTracker.toggleCamera()
        } label: {
            Label(
                poseTracker.cameraPosition == .front ? "目前自拍・切換後鏡頭" : "目前後鏡頭・切換自拍",
                systemImage: "camera.rotate.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(.white)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .accessibilityLabel(
            poseTracker.cameraPosition == .front ? "切換到後鏡頭" : "切換到前鏡頭"
        )
    }

    private func persistDraft(count: Int) {
        guard count > 0 else { return }
        activeRecordID = userStore.saveDraft(
            id: activeRecordID,
            count: count,
            exerciseType: poseTracker.exerciseType,
            level: poseTracker.level,
            isCompleted: count >= poseTracker.targetCount
        )
    }

    private func loadPreviousTodayCount() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        let startOfToday = calendar.startOfDay(for: Date())
        let records = (try? DatabaseManager.shared.fetchRecords(for: userStore.user.id)) ?? []
        previousTodayCount = records
            .filter {
                $0.exerciseType == configuration.exerciseType
                    && $0.level == configuration.level
                    && $0.timestamp >= startOfToday
            }
            .reduce(0) { $0 + $1.count }
    }

    private func finishAndStartNextLevel(_ nextLevel: Level) {
        guard let recordID = activeRecordID else {
            showingDatabaseError = true
            return
        }
        let finalCount = poseTracker.squatCount
        Task {
            let saved = await userStore.finishDraft(
                id: recordID,
                count: finalCount,
                isCompleted: true
            )
            if saved {
                activeRecordID = nil
                poseTracker.reset()
                onStartNextLevel(nextLevel)
            } else {
                showingDatabaseError = true
            }
        }
    }

    private func finishAndReturnToSelection() {
        guard let recordID = activeRecordID else {
            onChooseWorkout()
            return
        }
        let finalCount = poseTracker.squatCount
        Task {
            let saved = await userStore.finishDraft(
                id: recordID,
                count: finalCount,
                isCompleted: poseTracker.isLevelComplete
            )
            if saved {
                activeRecordID = nil
                poseTracker.reset()
                onChooseWorkout()
            } else {
                showingDatabaseError = true
            }
        }
    }

    /// 相機權限被拒絕時顯示的引導內容。
    private var permissionMessage: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
            Text("需要相機權限")
                .font(.title3.bold())
            Text("請到「設定」中允許 PoseTracker 使用相機，才能進行姿態偵測。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(30)
    }
}

/// 將偵測器狀態轉換成適合 UI 呈現的中文提示與顏色。
private extension SquatPhase {
    func message(for exercise: ExerciseType) -> String {
        switch self {
        case .searching: "請讓全身進入畫面"
        case .standing:
            switch exercise {
            case .squat: "準備好，開始下蹲"
            case .jumpingJack: "手腳張開開始動作"
            case .lunge: "前後跨步並彎曲膝蓋"
            }
        case .lowered:
            switch exercise {
            case .squat, .lunge: "很好，站起來完成動作"
            case .jumpingJack: "很好，手腳合攏完成動作"
            }
        }
    }

    var color: Color {
        switch self {
        case .searching: .orange
        case .standing: .mint
        case .lowered: .cyan
        }
    }
}
