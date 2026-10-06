import Foundation
import SQLite3

/// SQLite 中一筆永久保存的訓練紀錄。
struct DatabaseWorkoutRecord: Identifiable, Equatable {
    let id: UUID
    let userName: String
    let exerciseType: ExerciseType
    let level: Level
    let count: Int
    let isCompleted: Bool
    let timestamp: Date
    let isSynced: Bool
}

/// 儲存在本機的 App 帳號；密碼本身永遠不會寫入資料庫。
struct LocalUser: Identifiable, Equatable {
    let id: UUID
    let account: String
    let displayName: String
    let passwordHash: String
    let passwordSalt: String
    let createdAt: Date
    let lastLoginAt: Date?
}

enum DatabaseError: LocalizedError {
    case openFailed(String)
    case statementFailed(String)
    case invalidStoredRecord

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): "無法開啟訓練資料庫：\(message)"
        case .statementFailed(let message): "資料庫操作失敗：\(message)"
        case .invalidStoredRecord: "資料庫中有無法解析的訓練紀錄。"
        }
    }
}

/// 管理 App 的本機 SQLite 訓練資料庫。
///
/// 所有 SQLite 操作都在同一條序列 Queue 上執行，避免相機與 UI 同時存取
/// 資料庫時互相競爭。資料庫位於 Application Support/PoseTracker.sqlite3。
final class DatabaseManager {
    static let shared = try! DatabaseManager()

    private let queue = DispatchQueue(label: "com.posetracker.database")
    private var database: OpaquePointer?

    init(databaseURL: URL? = nil) throws {
        let url = try databaseURL ?? Self.defaultDatabaseURL()
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &connection,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) }
                ?? "未知錯誤"
            sqlite3_close(connection)
            throw DatabaseError.openFailed(message)
        }
        database = connection
        try createWorkoutRecordTable()
    }

    deinit {
        sqlite3_close(database)
    }

    /// 訓練結束時建立紀錄；isSynced 預設為 false，等待 REST API 上傳。
    @discardableResult
    func saveRecord(
        id: UUID = UUID(),
        userID: UUID,
        userName: String,
        exerciseType: ExerciseType,
        level: Level,
        count: Int,
        isCompleted: Bool,
        timestamp: Date = Date(),
        isSynced: Bool = false
    ) throws -> DatabaseWorkoutRecord {
        try queue.sync {
            let sql = """
                INSERT INTO WorkoutRecord
                (id, userId, userName, exerciseType, level, count, isCompleted, timestamp, isSynced)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }

            bind(id.uuidString, at: 1, in: statement)
            bind(userID.uuidString, at: 2, in: statement)
            bind(userName, at: 3, in: statement)
            bind(exerciseType.rawValue, at: 4, in: statement)
            bind(level.rawValue, at: 5, in: statement)
            sqlite3_bind_int(statement, 6, Int32(count))
            sqlite3_bind_int(statement, 7, isCompleted ? 1 : 0)
            sqlite3_bind_double(statement, 8, timestamp.timeIntervalSince1970)
            sqlite3_bind_int(statement, 9, isSynced ? 1 : 0)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw statementError()
            }
            return DatabaseWorkoutRecord(
                id: id,
                userName: userName,
                exerciseType: exerciseType,
                level: level,
                count: count,
                isCompleted: isCompleted,
                timestamp: timestamp,
                isSynced: isSynced
            )
        }
    }

    /// 建立本機帳號。account 使用 NOCASE 唯一索引，避免大小寫重複。
    func createUser(
        account: String,
        displayName: String,
        passwordHash: String,
        passwordSalt: String
    ) throws -> LocalUser {
        try queue.sync {
            let user = LocalUser(
                id: UUID(),
                account: account,
                displayName: displayName,
                passwordHash: passwordHash,
                passwordSalt: passwordSalt,
                createdAt: Date(),
                lastLoginAt: Date()
            )
            let statement = try prepare("""
                INSERT INTO User
                (id, account, displayName, passwordHash, passwordSalt, createdAt, lastLoginAt)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(statement) }
            bind(user.id.uuidString, at: 1, in: statement)
            bind(user.account, at: 2, in: statement)
            bind(user.displayName, at: 3, in: statement)
            bind(user.passwordHash, at: 4, in: statement)
            bind(user.passwordSalt, at: 5, in: statement)
            sqlite3_bind_double(statement, 6, user.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 7, user.lastLoginAt!.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw statementError()
            }
            try setCurrentUserLocked(id: user.id)
            return user
        }
    }

    /// 將 REST API 回傳的使用者保存成本機快取，讓既有紀錄與關卡邏輯
    /// 仍可使用同一個伺服器 UUID。密碼只送到 API，不落地到 SQLite。
    func upsertRemoteUser(id: UUID, account: String) throws -> LocalUser {
        try queue.sync {
            let now = Date()
            let statement = try prepare("""
                INSERT INTO User
                (id, account, displayName, passwordHash, passwordSalt, createdAt, lastLoginAt)
                VALUES (?, ?, ?, '', '', ?, ?)
                ON CONFLICT(account) DO UPDATE SET
                    id = excluded.id,
                    displayName = excluded.displayName,
                    passwordHash = '',
                    passwordSalt = '',
                    lastLoginAt = excluded.lastLoginAt;
                """)
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, at: 1, in: statement)
            bind(account, at: 2, in: statement)
            bind(account, at: 3, in: statement)
            sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
            sqlite3_bind_double(statement, 5, now.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
            try setCurrentUserLocked(id: id)

            let userStatement = try prepare("SELECT * FROM User WHERE id = ? LIMIT 1;")
            defer { sqlite3_finalize(userStatement) }
            bind(id.uuidString, at: 1, in: userStatement)
            guard sqlite3_step(userStatement) == SQLITE_ROW else {
                throw DatabaseError.invalidStoredRecord
            }
            return try decodeUser(from: userStatement)
        }
    }

    func fetchUser(account: String) throws -> LocalUser? {
        try queue.sync {
            let statement = try prepare("SELECT * FROM User WHERE account = ? COLLATE NOCASE LIMIT 1;")
            defer { sqlite3_finalize(statement) }
            bind(account, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeUser(from: statement)
        }
    }

    /// 相容舊版同時具有「顯示名稱」與「帳號」的資料；兩者皆可登入。
    func fetchUser(loginIdentifier: String) throws -> LocalUser? {
        try queue.sync {
            let statement = try prepare("""
                SELECT * FROM User
                WHERE account = ? COLLATE NOCASE OR displayName = ? COLLATE NOCASE
                LIMIT 1;
                """)
            defer { sqlite3_finalize(statement) }
            bind(loginIdentifier, at: 1, in: statement)
            bind(loginIdentifier, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeUser(from: statement)
        }
    }

    func fetchUser(id: UUID) throws -> LocalUser? {
        try queue.sync {
            let statement = try prepare("SELECT * FROM User WHERE id = ? LIMIT 1;")
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decodeUser(from: statement)
        }
    }

    func setCurrentUser(id: UUID?) throws {
        try queue.sync { try setCurrentUserLocked(id: id) }
    }

    func fetchCurrentUser() throws -> LocalUser? {
        try queue.sync {
            let statement = try prepare("SELECT currentUserId FROM AppSession WHERE singletonId = 1;")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: text))
            else { return nil }
            let userStatement = try prepare("SELECT * FROM User WHERE id = ? LIMIT 1;")
            defer { sqlite3_finalize(userStatement) }
            bind(id.uuidString, at: 1, in: userStatement)
            guard sqlite3_step(userStatement) == SQLITE_ROW else { return nil }
            return try decodeUser(from: userStatement)
        }
    }

    func updateLastLogin(for id: UUID, at date: Date = Date()) throws {
        try queue.sync {
            let statement = try prepare("UPDATE User SET lastLoginAt = ? WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            bind(id.uuidString, at: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
            try setCurrentUserLocked(id: id)
        }
    }

    func saveProgress(userID: UUID, exerciseType: ExerciseType, level: Level) throws {
        try queue.sync {
            let statement = try prepare("""
                INSERT INTO UserProgress (userId, exerciseType, highestUnlockedLevel, updatedAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(userId, exerciseType) DO UPDATE SET
                    highestUnlockedLevel = excluded.highestUnlockedLevel,
                    updatedAt = excluded.updatedAt;
                """)
            defer { sqlite3_finalize(statement) }
            bind(userID.uuidString, at: 1, in: statement)
            bind(exerciseType.rawValue, at: 2, in: statement)
            bind(level.rawValue, at: 3, in: statement)
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
        }
    }

    func fetchProgress(for userID: UUID) throws -> [ExerciseType: Level] {
        try queue.sync {
            let statement = try prepare("""
                SELECT exerciseType, highestUnlockedLevel FROM UserProgress WHERE userId = ?;
                """)
            defer { sqlite3_finalize(statement) }
            bind(userID.uuidString, at: 1, in: statement)
            var result: [ExerciseType: Level] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let exerciseText = sqlite3_column_text(statement, 0),
                      let levelText = sqlite3_column_text(statement, 1),
                      let exercise = ExerciseType(rawValue: String(cString: exerciseText)),
                      let level = Level(rawValue: String(cString: levelText))
                else { continue }
                result[exercise] = level
            }
            return result
        }
    }

    /// 依使用者名稱取得歷史成果；由新到舊排列。
    /// 呼叫端可用 isCompleted、exerciseType 與 level 推導已通過的關卡。
    func fetchRecords(for userName: String) throws -> [DatabaseWorkoutRecord] {
        try queue.sync {
            let sql = """
                SELECT id, userName, exerciseType, level, count,
                       isCompleted, timestamp, isSynced
                FROM WorkoutRecord
                WHERE userName = ?
                ORDER BY timestamp DESC;
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bind(userName, at: 1, in: statement)

            var records: [DatabaseWorkoutRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                records.append(try decodeRecord(from: statement))
            }
            return records
        }
    }

    func fetchRecords(for userID: UUID) throws -> [DatabaseWorkoutRecord] {
        try queue.sync {
            let statement = try prepare("""
                SELECT id, userName, exerciseType, level, count,
                       isCompleted, timestamp, isSynced
                FROM WorkoutRecord WHERE userId = ? ORDER BY timestamp DESC;
                """)
            defer { sqlite3_finalize(statement) }
            bind(userID.uuidString, at: 1, in: statement)
            var records: [DatabaseWorkoutRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                records.append(try decodeRecord(from: statement))
            }
            return records
        }
    }

    func fetchUnsyncedRecords(for userID: UUID) throws -> [DatabaseWorkoutRecord] {
        try queue.sync {
            let statement = try prepare("""
                SELECT id, userName, exerciseType, level, count,
                       isCompleted, timestamp, isSynced
                FROM WorkoutRecord
                WHERE userId = ? AND isSynced = 0
                ORDER BY timestamp ASC;
                """)
            defer { sqlite3_finalize(statement) }
            bind(userID.uuidString, at: 1, in: statement)
            var records: [DatabaseWorkoutRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                records.append(try decodeRecord(from: statement))
            }
            return records
        }
    }

    /// REST API 成功接收指定紀錄後，將其標示為已同步。
    func markAsSynced(id: UUID) throws {
        try queue.sync {
            let statement = try prepare(
                "UPDATE WorkoutRecord SET isSynced = 1 WHERE id = ?;"
            )
            defer { sqlite3_finalize(statement) }
            bind(id.uuidString, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw statementError()
            }
        }
    }

    func updateRecord(
        id: UUID,
        count: Int,
        isCompleted: Bool,
        isSynced: Bool = false
    ) throws {
        try queue.sync {
            let statement = try prepare("""
                UPDATE WorkoutRecord
                SET count = ?, isCompleted = ?, isSynced = ?
                WHERE id = ?;
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(count))
            sqlite3_bind_int(statement, 2, isCompleted ? 1 : 0)
            sqlite3_bind_int(statement, 3, isSynced ? 1 : 0)
            bind(id.uuidString, at: 4, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
        }
    }

    private static func defaultDatabaseURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDirectory = directory.appendingPathComponent(
            "PoseTracker",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true
        )
        return appDirectory.appendingPathComponent("PoseTracker.sqlite3")
    }

    private func createWorkoutRecordTable() throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS WorkoutRecord (
                id TEXT PRIMARY KEY NOT NULL,
                userId TEXT,
                userName TEXT NOT NULL,
                exerciseType TEXT NOT NULL,
                level TEXT NOT NULL,
                count INTEGER NOT NULL,
                isCompleted INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                isSynced INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_workout_user_timestamp
            ON WorkoutRecord(userName, timestamp DESC);
            CREATE TABLE IF NOT EXISTS User (
                id TEXT PRIMARY KEY NOT NULL,
                account TEXT NOT NULL COLLATE NOCASE UNIQUE,
                displayName TEXT NOT NULL,
                passwordHash TEXT NOT NULL,
                passwordSalt TEXT NOT NULL,
                createdAt REAL NOT NULL,
                lastLoginAt REAL
            );
            CREATE TABLE IF NOT EXISTS UserProgress (
                userId TEXT NOT NULL,
                exerciseType TEXT NOT NULL,
                highestUnlockedLevel TEXT NOT NULL,
                updatedAt REAL NOT NULL,
                PRIMARY KEY (userId, exerciseType)
            );
            CREATE TABLE IF NOT EXISTS AppSession (
                singletonId INTEGER PRIMARY KEY CHECK (singletonId = 1),
                currentUserId TEXT
            );
            INSERT OR IGNORE INTO AppSession (singletonId, currentUserId) VALUES (1, NULL);
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw statementError()
        }
        try addColumnIfNeeded(
            table: "WorkoutRecord",
            column: "userId",
            definition: "TEXT"
        )
    }

    private func addColumnIfNeeded(
        table: String,
        column: String,
        definition: String
    ) throws {
        var exists = false
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 1),
               String(cString: text) == column {
                exists = true
                break
            }
        }
        if !exists, sqlite3_exec(
            database,
            "ALTER TABLE \(table) ADD COLUMN \(column) \(definition);",
            nil, nil, nil
        ) != SQLITE_OK {
            throw statementError()
        }
    }

    private func setCurrentUserLocked(id: UUID?) throws {
        let statement = try prepare("UPDATE AppSession SET currentUserId = ? WHERE singletonId = 1;")
        defer { sqlite3_finalize(statement) }
        if let id {
            bind(id.uuidString, at: 1, in: statement)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw statementError() }
    }

    private func decodeUser(from statement: OpaquePointer) throws -> LocalUser {
        guard let idText = sqlite3_column_text(statement, 0),
              let accountText = sqlite3_column_text(statement, 1),
              let displayText = sqlite3_column_text(statement, 2),
              let hashText = sqlite3_column_text(statement, 3),
              let saltText = sqlite3_column_text(statement, 4),
              let id = UUID(uuidString: String(cString: idText))
        else { throw DatabaseError.invalidStoredRecord }
        let lastLogin: Date? = sqlite3_column_type(statement, 6) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        return LocalUser(
            id: id,
            account: String(cString: accountText),
            displayName: String(cString: displayText),
            passwordHash: String(cString: hashText),
            passwordSalt: String(cString: saltText),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            lastLoginAt: lastLogin
        )
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw statementError() }
        return statement
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func decodeRecord(from statement: OpaquePointer) throws -> DatabaseWorkoutRecord {
        guard let idText = sqlite3_column_text(statement, 0),
              let userText = sqlite3_column_text(statement, 1),
              let exerciseText = sqlite3_column_text(statement, 2),
              let levelText = sqlite3_column_text(statement, 3),
              let id = UUID(uuidString: String(cString: idText)),
              let exercise = ExerciseType(rawValue: String(cString: exerciseText)),
              let level = Level(rawValue: String(cString: levelText))
        else { throw DatabaseError.invalidStoredRecord }

        return DatabaseWorkoutRecord(
            id: id,
            userName: String(cString: userText),
            exerciseType: exercise,
            level: level,
            count: Int(sqlite3_column_int(statement, 4)),
            isCompleted: sqlite3_column_int(statement, 5) != 0,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            isSynced: sqlite3_column_int(statement, 7) != 0
        )
    }

    private func statementError() -> DatabaseError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "資料庫尚未開啟"
        return .statementFailed(message)
    }
}
