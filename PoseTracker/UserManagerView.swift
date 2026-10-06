import SwiftUI

/// 顯示目前登入者、歷史訓練摘要與登出入口。
struct UserManagerView: View {
    @ObservedObject var store: UserSessionStore
    @ObservedObject var authManager: AuthManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("目前帳號") {
                    LabeledContent("使用者名稱", value: store.user.displayName)
                    LabeledContent("個人最佳", value: "\(store.bestCount) 次")
                }

                Section("訓練歷史") {
                    if store.records.isEmpty {
                        Text("目前還沒有訓練紀錄")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.records) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(record.exerciseType.title)
                                        .fontWeight(.semibold)
                                    Text(record.level.title)
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(record.count) 次")
                                        .fontWeight(.semibold)
                                }
                                HStack {
                                    Text(record.timestamp, style: .date)
                                    Text(record.timestamp, style: .time)
                                    Spacer()
                                    Label(
                                        record.isCompleted ? "已過關" : "未過關",
                                        systemImage: record.isCompleted
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundStyle(record.isCompleted ? .mint : .secondary)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                Section {
                    Button("登出", role: .destructive) {
                        dismiss()
                        authManager.signOut()
                    }
                }
            }
            .navigationTitle("帳號與紀錄")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { store.reloadRecords() }
        }
    }
}
