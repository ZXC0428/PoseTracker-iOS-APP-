import Foundation

/// 管理目前登入者的永久訓練紀錄。
@MainActor
final class UserSessionStore: ObservableObject {
    let user: LocalUser
    @Published private(set) var records: [DatabaseWorkoutRecord] = []
    @Published private(set) var databaseErrorMessage: String?
    @Published private(set) var syncMessage: String?

    init(user: LocalUser) {
        self.user = user
        reloadRecords()
    }

    /// 建立一筆完整紀錄並立即嘗試同步；保留給非草稿式流程使用。
    @discardableResult
    func addRecord(
        count: Int,
        exerciseType: ExerciseType,
        level: Level,
        isCompleted: Bool
    ) -> Bool {
        guard count > 0 else { return false }
        do {
            try DatabaseManager.shared.saveRecord(
                userID: user.id,
                userName: user.displayName,
                exerciseType: exerciseType,
                level: level,
                count: count,
                isCompleted: isCompleted
            )
            databaseErrorMessage = nil
            reloadRecords()
            Task { await syncPendingRecords() }
            return true
        } catch {
            databaseErrorMessage = error.localizedDescription
            return false
        }
    }

    /// 每次計數都更新同一筆本機草稿，避免使用者忘記按結束而遺失成果。
    func saveDraft(
        id: UUID?,
        count: Int,
        exerciseType: ExerciseType,
        level: Level,
        isCompleted: Bool
    ) -> UUID? {
        do {
            let recordID = id ?? UUID()
            if id == nil {
                try DatabaseManager.shared.saveRecord(
                    id: recordID,
                    userID: user.id,
                    userName: user.displayName,
                    exerciseType: exerciseType,
                    level: level,
                    count: count,
                    isCompleted: isCompleted
                )
            } else {
                try DatabaseManager.shared.updateRecord(
                    id: recordID,
                    count: count,
                    isCompleted: isCompleted
                )
            }
            databaseErrorMessage = nil
            reloadRecords()
            return recordID
        } catch {
            databaseErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// 將草稿定稿後觸發同步；同步失敗不會讓本機保存失敗。
    func finishDraft(id: UUID, count: Int, isCompleted: Bool) async -> Bool {
        do {
            try DatabaseManager.shared.updateRecord(
                id: id,
                count: count,
                isCompleted: isCompleted
            )
            reloadRecords()
            await syncPendingRecords()
            return true
        } catch {
            databaseErrorMessage = error.localizedDescription
            return false
        }
    }

    /// 從 SQLite 重新整理畫面使用的歷史紀錄快取。
    func reloadRecords() {
        do {
            records = try DatabaseManager.shared.fetchRecords(for: user.id)
            databaseErrorMessage = nil
        } catch {
            databaseErrorMessage = error.localizedDescription
        }
    }

    /// 個人歷史中單場最高完成次數。
    var bestCount: Int {
        records.map(\.count).max() ?? 0
    }

    /// 離線優先：SQLite 永遠先保存；API 成功後才標記 isSynced。
    func syncPendingRecords() async {
        guard let token = TokenStore.load() else { return }
        do {
            let pending = try DatabaseManager.shared.fetchUnsyncedRecords(for: user.id)
            guard !pending.isEmpty else { return }
            let syncedIDs = try await APIClient.shared.syncWorkouts(pending, token: token)
            for id in syncedIDs {
                try DatabaseManager.shared.markAsSynced(id: id)
            }

            for record in pending where record.isCompleted {
                let unlockedLevel = record.level.next ?? record.level
                try? await APIClient.shared.updateProgress(
                    exerciseType: record.exerciseType,
                    level: unlockedLevel,
                    token: token
                )
            }
            syncMessage = nil
            reloadRecords()
        } catch {
            // 網路失敗不影響本機訓練；紀錄維持未同步，之後會重試。
            syncMessage = "紀錄已保存在手機，連線恢復後會再次同步。"
        }
    }
}
