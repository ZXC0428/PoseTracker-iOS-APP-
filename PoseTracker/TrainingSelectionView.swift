import SwiftUI

/// 從選擇頁傳給相機頁的不可變訓練設定。
struct TrainingConfiguration: Equatable {
    let exerciseType: ExerciseType
    let level: Level
}

/// 登入後的獨立訓練入口；相機只會在使用者確認設定後建立。
struct TrainingSelectionView: View {
    /// 今天單一難度的累積次數與是否至少完成一場。
    private struct TodayLevelResult {
        var count = 0
        var isCompleted = false
    }

    let user: LocalUser
    @ObservedObject var authManager: AuthManager
    let onStart: (TrainingConfiguration) -> Void

    @State private var selectedExercise: ExerciseType = .squat
    @State private var selectedLevel: Level = .easy
    @State private var unlocked: [ExerciseType: Level] = [:]
    @State private var todayResults: [ExerciseType: [Level: TodayLevelResult]] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("你好，\(user.displayName)")
                            .font(.largeTitle.bold())
                        Text("今天想進行哪一項訓練？")
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink {
                        LeaderboardView()
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "trophy.fill")
                                .font(.title2)
                                .foregroundStyle(.yellow)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("排行榜").font(.headline)
                                Text("查看今日與本週的加權積分排名")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(
                            Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 18)
                        )
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("運動項目")
                            .font(.headline)
                        ForEach(ExerciseType.allCases) { exercise in
                            selectionRow(
                                title: exercise.title,
                                subtitle: exerciseDescription(exercise),
                                systemImage: exercise.systemImage,
                                isSelected: selectedExercise == exercise
                            ) {
                                selectedExercise = exercise
                                if !isUnlocked(selectedLevel, for: exercise) {
                                    selectedLevel = unlocked[exercise] ?? .easy
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("關卡難易度")
                            .font(.headline)
                        ForEach(Level.allCases) { level in
                            let canSelect = isUnlocked(level, for: selectedExercise)
                            let result = todayResults[selectedExercise]?[level]
                            Button {
                                selectedLevel = level
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: levelIcon(
                                        canSelect: canSelect,
                                        isCompleted: result?.isCompleted == true
                                    ))
                                        .foregroundStyle(
                                            result?.isCompleted == true
                                                ? .green
                                                : (canSelect ? .mint : .secondary)
                                        )
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(level.title)
                                            .font(.headline)
                                            .foregroundStyle(canSelect ? .primary : .secondary)
                                        Text(levelDescription(level))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(todayResultDescription(result))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(
                                                result?.isCompleted == true ? .green : .secondary
                                            )
                                    }
                                    Spacer()
                                    if selectedLevel == level {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.mint)
                                    }
                                }
                                .padding(16)
                                .background(
                                    selectedLevel == level
                                        ? Color.mint.opacity(0.12)
                                        : Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 18)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSelect)
                        }
                    }

                    Button {
                        onStart(TrainingConfiguration(
                            exerciseType: selectedExercise,
                            level: selectedLevel
                        ))
                    } label: {
                        Label("開始訓練", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .foregroundStyle(.black)
                            .background(.mint, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("選擇訓練")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("登出", role: .destructive) { authManager.signOut() }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .task { await loadProgress() }
        }
    }

    /// 建立運動項目的共用可選列，保持三種運動版面一致。
    private func selectionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.mint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint)
                }
            }
            .padding(16)
            .background(
                isSelected ? Color.mint.opacity(0.12) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 18)
            )
        }
        .buttonStyle(.plain)
    }

    /// 先讀本機進度立即顯示，再與伺服器資料合併並寫回 SQLite。
    @MainActor
    private func loadProgress() async {
        unlocked = (try? DatabaseManager.shared.fetchProgress(for: user.id)) ?? [:]
        loadTodayResults()
        guard let token = TokenStore.load(),
              let remote = try? await APIClient.shared.fetchProgress(token: token)
        else { return }
        for (exercise, level) in remote {
            let merged = level.rank > (unlocked[exercise] ?? .easy).rank
                ? level
                : (unlocked[exercise] ?? .easy)
            unlocked[exercise] = merged
            try? DatabaseManager.shared.saveProgress(
                userID: user.id,
                exerciseType: exercise,
                level: merged
            )
        }
    }

    /// 依台灣日界線統計同運動、同難度今天完成的次數。
    private func loadTodayResults() {
        guard let records = try? DatabaseManager.shared.fetchRecords(for: user.id) else {
            todayResults = [:]
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        let startOfToday = calendar.startOfDay(for: Date())
        var result: [ExerciseType: [Level: TodayLevelResult]] = [:]
        for record in records where record.timestamp >= startOfToday {
            var levelResult = result[record.exerciseType]?[record.level] ?? TodayLevelResult()
            levelResult.count += record.count
            levelResult.isCompleted = levelResult.isCompleted || record.isCompleted
            result[record.exerciseType, default: [:]][record.level] = levelResult
        }
        todayResults = result
    }

    /// 已過關使用勾勾、可選使用旗幟、尚未解鎖使用鎖頭。
    private func levelIcon(canSelect: Bool, isCompleted: Bool) -> String {
        if isCompleted { return "checkmark.seal.fill" }
        return canSelect ? "flag.fill" : "lock.fill"
    }

    /// 將今日統計轉成關卡列下方的簡短中文說明。
    private func todayResultDescription(_ result: TodayLevelResult?) -> String {
        guard let result, result.count > 0 else { return "今天尚未訓練" }
        if result.isCompleted {
            return "今日已過關・\(result.count) 次"
        }
        return "今日累積・\(result.count) 次（尚未過關）"
    }

    /// 只有 rank 不高於目前最高解鎖難度的關卡可選。
    private func isUnlocked(_ level: Level, for exercise: ExerciseType) -> Bool {
        level.rank <= (unlocked[exercise] ?? .easy).rank
    }

    /// 運動列的簡短偵測方式說明。
    private func exerciseDescription(_ exercise: ExerciseType) -> String {
        switch exercise {
        case .squat: "膝角與髖部下降偵測"
        case .jumpingJack: "離地、張開與合攏節奏偵測"
        case .lunge: "建議從身體側面拍攝"
        }
    }

    /// 顯示各難度目標；開合跳以動作速度取代維持秒數。
    private func levelDescription(_ level: Level) -> String {
        if selectedExercise == .jumpingJack {
            return "完成 \(level.targetCount) 次，每段需在 \(level.jumpingJackTransitionLimit.formatted(.number.precision(.fractionLength(1)))) 秒內"
        }
        if level.holdDuration == 0 {
            return "完成 \(level.targetCount) 次，不限維持時間"
        }
        return "完成 \(level.targetCount) 次，每次維持 \(Int(level.holdDuration)) 秒"
    }
}

/// 登入後先選訓練，再建立相機頁面。
struct AuthenticatedFlowView: View {
    let user: LocalUser
    @ObservedObject var authManager: AuthManager
    @State private var configuration: TrainingConfiguration?

    var body: some View {
        // configuration 為 nil 時選關卡；有值後才建立相機與 Vision 資源。
        if let configuration {
            ContentView(
                authManager: authManager,
                user: user,
                configuration: configuration,
                onChooseWorkout: { self.configuration = nil },
                onStartNextLevel: { nextLevel in
                    self.configuration = TrainingConfiguration(
                        exerciseType: configuration.exerciseType,
                        level: nextLevel
                    )
                }
            )
            .id("\(configuration.exerciseType.rawValue)-\(configuration.level.rawValue)")
        } else {
            TrainingSelectionView(
                user: user,
                authManager: authManager,
                onStart: { configuration = $0 }
            )
        }
    }
}
