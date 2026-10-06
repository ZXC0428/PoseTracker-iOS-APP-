import Foundation

/// App 本次執行期間使用的使用者資料。
/// 這是純記憶體模型，沒有寫入資料庫或檔案。
struct WorkoutUser: Identifiable, Equatable {
    let id = UUID()
    var name: String
}

/// 一次完成的深蹲訓練紀錄。
struct WorkoutRecord: Identifiable {
    let id = UUID()
    let userID: UUID
    let squatCount: Int
    let completedAt: Date
}

/// 管理使用者、目前選擇以及暫存訓練紀錄。
///
/// ObservableObject 讓 SwiftUI 能在資料變化時自動更新畫面。
/// App 結束後此物件會消失，因此所有資料都會清空。
final class UserSessionStore: ObservableObject {
    /// 預設提供一位使用者，讓 App 第一次開啟即可直接使用。
    @Published private(set) var users: [WorkoutUser] = [
        WorkoutUser(name: "使用者 1")
    ]
    @Published var selectedUserID: UUID?
    @Published private(set) var records: [WorkoutRecord] = []

    /// 初始化時自動選擇第一位使用者。
    init() {
        selectedUserID = users.first?.id
    }

    /// 依 selectedUserID 找出目前訓練所屬的使用者。
    var selectedUser: WorkoutUser? {
        users.first { $0.id == selectedUserID }
    }

    /// 建立新使用者，並立即切換到該使用者。
    func addUser(named name: String) {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return }
        let user = WorkoutUser(name: cleanedName)
        users.append(user)
        selectedUserID = user.id
    }

    /// 切換目前使用者。
    func select(_ user: WorkoutUser) {
        selectedUserID = user.id
    }

    /// 將非零的深蹲次數記錄到目前使用者名下。
    func addRecord(squatCount: Int) {
        guard let selectedUserID, squatCount > 0 else { return }
        records.insert(
            WorkoutRecord(
                userID: selectedUserID,
                squatCount: squatCount,
                completedAt: Date()
            ),
            at: 0
        )
    }

    /// 取得指定使用者在本次 App 執行期間的所有紀錄。
    func records(for user: WorkoutUser) -> [WorkoutRecord] {
        records.filter { $0.userID == user.id }
    }

    /// 從使用者紀錄中找出最高次數。
    func bestCount(for user: WorkoutUser) -> Int {
        records(for: user).map(\.squatCount).max() ?? 0
    }
}
