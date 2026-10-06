import SwiftUI

/// 顯示今日／本週排行榜，並提供下拉更新與分數來源明細。
struct LeaderboardView: View {
    @State private var period: LeaderboardPeriod = .daily
    @State private var exerciseType: ExerciseType = .squat
    @State private var entries: [LeaderboardEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            // 變更任一 Picker 會改變 task id，自動重新取得排行榜。
            // 依載入、錯誤、空資料及正常資料四種狀態呈現內容。
            Section {
                Picker("統計期間", selection: $period) {
                    ForEach(LeaderboardPeriod.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Picker("運動項目", selection: $exerciseType) {
                    ForEach(ExerciseType.allCases) { exercise in
                        Text(exercise.title).tag(exercise)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                if isLoading && entries.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("載入排行榜…")
                        Spacer()
                    }
                } else if let errorMessage {
                    ContentUnavailableView(
                        "無法載入排行榜",
                        systemImage: "wifi.exclamationmark",
                        description: Text(errorMessage)
                    )
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        "還沒有排名",
                        systemImage: "trophy",
                        description: Text("完成這項運動的關卡後，就會出現在排行榜。")
                    )
                } else {
                    ForEach(entries) { entry in
                        leaderboardRow(entry)
                    }
                }
            } header: {
                Text("簡單 ×1・中等 ×1.5・困難 ×2")
            }
        }
        .navigationTitle("排行榜")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(period.rawValue)-\(exerciseType.rawValue)") {
            await loadLeaderboard()
        }
        .refreshable { await loadLeaderboard() }
    }

    /// 一列排名包含總分摘要與各難度的次數、倍率、獎勵。
    private func leaderboardRow(_ entry: LeaderboardEntry) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Text(entry.rank <= 3 ? ["🥇", "🥈", "🥉"][entry.rank - 1] : "\(entry.rank)")
                    .font(entry.rank <= 3 ? .title2 : .headline)
                    .frame(width: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.username).font(.headline)
                    Text("\(entry.totalCount) 次・\(entry.completedWorkouts) 場完成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formattedScore(entry.score))
                        .font(.title3.bold())
                        .foregroundStyle(.mint)
                    Text("積分").font(.caption2).foregroundStyle(.secondary)
                }
            }

            let details = entry.breakdown.filter { $0.count > 0 }
            if !details.isEmpty {
                VStack(spacing: 5) {
                    ForEach(details) { detail in
                        HStack {
                            Text(
                                "\(detail.title)・\(detail.count) 次 × \(detail.multiplier)"
                                + " ＋過關獎勵 \(formattedScore(detail.completionBonus))"
                            )
                            Spacer()
                            Text("\(formattedScore(detail.score)) 分")
                                .fontWeight(.semibold)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if entry.allLevelsBonus > 0 {
                        HStack {
                            Label("三關全過獎勵", systemImage: "star.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Text("＋\(formattedScore(entry.allLevelsBonus)) 分")
                                .fontWeight(.bold)
                                .foregroundStyle(.orange)
                        }
                        .font(.caption)
                    }
                }
                .padding(.leading, 52)
            }
        }
        .padding(.vertical, 5)
    }

    /// 整數不顯示小數；1.5 之類的分數最多保留一位。
    private func formattedScore(_ score: Double) -> String {
        score.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// 使用目前 Keychain token 查詢；失敗時保留畫面並顯示原因。
    @MainActor
    private func loadLeaderboard() async {
        guard let token = TokenStore.load() else {
            errorMessage = "請重新登入。"
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            entries = try await APIClient.shared.fetchLeaderboard(
                period: period,
                exerciseType: exerciseType,
                token: token
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
