import SwiftUI

/// 使用者管理頁：新增／切換使用者，並查看暫存成績。
struct UserManagerView: View {
    @ObservedObject var store: UserSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var newUserName = ""

    var body: some View {
        NavigationStack {
            List {
                // MARK: 新增使用者
                Section("新增使用者") {
                    HStack {
                        TextField("輸入暱稱", text: $newUserName)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .onSubmit(addUser)
                        Button("新增", action: addUser)
                            .disabled(
                                newUserName.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty
                            )
                    }
                }

                // MARK: 使用者選擇
                Section("選擇使用者") {
                    ForEach(store.users) { user in
                        Button {
                            store.select(user)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(user.name)
                                        .foregroundStyle(.primary)
                                    Text("最佳 \(store.bestCount(for: user)) 次")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if store.selectedUserID == user.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.mint)
                                }
                            }
                        }
                    }
                }

                // MARK: 目前使用者的訓練歷史
                if let user = store.selectedUser {
                    Section("\(user.name) 的本次紀錄") {
                        let records = store.records(for: user)
                        if records.isEmpty {
                            Text("目前還沒有完成的訓練")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(records) { record in
                                HStack {
                                    Text(record.completedAt, style: .time)
                                    Spacer()
                                    Text("\(record.squatCount) 次")
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    }
                }

                // 明確提醒此版本不會永久保存資料。
                Section {
                    Text("目前資料只保留在記憶體中；關閉 App 後會全部清空。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("使用者與紀錄")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    /// 清理輸入後交由 Store 建立使用者。
    private func addUser() {
        store.addUser(named: newUserName)
        newUserName = ""
    }
}
