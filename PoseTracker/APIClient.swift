import Foundation

/// 將網路層常見失敗轉成可直接顯示給使用者的錯誤訊息。
enum APIError: LocalizedError {
    case invalidResponse
    case server(statusCode: Int, message: String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "伺服器回傳了無法解析的資料。"
        case .server(_, let message):
            message
        case .notAuthenticated:
            "登入已失效，請重新登入。"
        }
    }
}

/// 排行榜可查詢的統計區間；rawValue 必須與 backend query 相同。
enum LeaderboardPeriod: String, CaseIterable, Identifiable {
    case daily
    case weekly

    var id: Self { self }
    var title: String { self == .daily ? "今日" : "本週" }
}

/// 排行榜中一位使用者的總排名與各難度分數明細。
struct LeaderboardEntry: Decodable, Identifiable {
    let rank: Int
    let username: String
    let totalCount: Int
    let completedWorkouts: Int
    let score: Double
    let allLevelsBonus: Double
    let breakdown: [LeaderboardBreakdown]

    var id: String { "\(rank)-\(username)" }

    enum CodingKeys: String, CodingKey {
        case rank, username, score, breakdown
        case totalCount = "total_count"
        case completedWorkouts = "completed_workouts"
        case allLevelsBonus = "all_levels_bonus"
    }
}

/// 單一難度的完成次數、過關獎勵與加權後分數。
struct LeaderboardBreakdown: Decodable, Identifiable {
    let level: String
    let count: Int
    let completedWorkouts: Int
    let completionBonus: Double
    let score: Double

    var id: String { level }
    var title: String {
        switch level {
        case "easy": "簡單"
        case "medium": "中等"
        case "hard": "困難"
        default: level
        }
    }
    var multiplier: String {
        switch level {
        case "easy": "1"
        case "medium": "1.5"
        case "hard": "2"
        default: "0"
        }
    }

    enum CodingKeys: String, CodingKey {
        case level, count, score
        case completedWorkouts = "completed_workouts"
        case completionBonus = "completion_bonus"
    }
}

/// 註冊及登入成功後由 backend 回傳的使用者與 Bearer token。
struct AuthTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let userID: UUID
    let username: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case userID = "user_id"
        case username
    }
}

/// 登入／註冊送出的 JSON；private 避免 UI 直接依賴傳輸格式。
private struct AuthRequest: Encodable {
    let username: String
    let password: String
}

/// FastAPI HTTPException 的標準錯誤格式。
private struct ServerError: Decodable {
    let detail: String
}

/// 批次同步包裝，避免每一筆訓練都建立一次 HTTP request。
private struct WorkoutSyncRequest: Encodable {
    let records: [WorkoutUpload]
}

/// 將本機 SQLite 紀錄轉成 backend 接受的 snake_case JSON。
private struct WorkoutUpload: Encodable {
    let id: UUID
    let exerciseType: String
    let level: String
    let count: Int
    let isCompleted: Bool
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case id, level, count, timestamp
        case exerciseType = "exercise_type"
        case isCompleted = "is_completed"
    }
}

/// backend 已確認保存的 UUID；只有這些 UUID 可以標為 isSynced。
private struct WorkoutSyncResponse: Decodable {
    let syncedIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case syncedIDs = "synced_ids"
    }
}

/// 上傳某運動目前最高解鎖難度的 request body。
private struct ProgressRequest: Encodable {
    let exerciseType: String
    let highestUnlockedLevel: String

    enum CodingKeys: String, CodingKey {
        case exerciseType = "exercise_type"
        case highestUnlockedLevel = "highest_unlocked_level"
    }
}

/// 從伺服器下載的單項運動解鎖進度。
private struct ProgressResponse: Decodable {
    let exerciseType: String
    let highestUnlockedLevel: String

    enum CodingKeys: String, CodingKey {
        case exerciseType = "exercise_type"
        case highestUnlockedLevel = "highest_unlocked_level"
    }
}

/// REST API 的單一入口。目前使用 HTTP 公網 IP 僅供開發測試。
final class APIClient {
    static let shared = APIClient()

    private let baseURL = URL(string: "http://120.113.70.251:8000")!
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    /// 建立遠端帳號，成功時同時取得第一枚 access token。
    func register(username: String, password: String) async throws -> AuthTokenResponse {
        try await send(
            path: "/auth/register",
            method: "POST",
            body: AuthRequest(username: username, password: password)
        )
    }

    /// 驗證帳密並取得新的 access token。
    func login(username: String, password: String) async throws -> AuthTokenResponse {
        try await send(
            path: "/auth/login",
            method: "POST",
            body: AuthRequest(username: username, password: password)
        )
    }

    /// 批次上傳尚未同步的本機訓練紀錄。
    func syncWorkouts(_ records: [DatabaseWorkoutRecord], token: String) async throws -> [UUID] {
        guard !records.isEmpty else { return [] }
        let payload = WorkoutSyncRequest(records: records.map {
            WorkoutUpload(
                id: $0.id,
                exerciseType: $0.exerciseType.rawValue,
                level: $0.level.rawValue,
                count: $0.count,
                isCompleted: $0.isCompleted,
                timestamp: $0.timestamp
            )
        })
        let response: WorkoutSyncResponse = try await send(
            path: "/workouts/sync",
            method: "POST",
            body: payload,
            token: token
        )
        return response.syncedIDs
    }

    /// 將單項運動的最高解鎖難度寫回伺服器。
    func updateProgress(
        exerciseType: ExerciseType,
        level: Level,
        token: String
    ) async throws {
        let _: EmptyResponse = try await send(
            path: "/progress",
            method: "PUT",
            body: ProgressRequest(
                exerciseType: exerciseType.rawValue,
                highestUnlockedLevel: level.rawValue
            ),
            token: token
        )
    }

    /// 下載所有運動的解鎖進度，並忽略未知的新版 enum 值。
    func fetchProgress(token: String) async throws -> [ExerciseType: Level] {
        let response: [ProgressResponse] = try await sendWithoutBody(
            path: "/progress",
            method: "GET",
            token: token
        )
        return Dictionary(uniqueKeysWithValues: response.compactMap { item in
            guard let exercise = ExerciseType(rawValue: item.exerciseType),
                  let level = Level(rawValue: item.highestUnlockedLevel)
            else { return nil }
            return (exercise, level)
        })
    }

    /// 依期間與運動類型下載最多 100 名排行榜資料。
    func fetchLeaderboard(
        period: LeaderboardPeriod,
        exerciseType: ExerciseType,
        token: String
    ) async throws -> [LeaderboardEntry] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/leaderboard"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "period", value: period.rawValue),
            URLQueryItem(name: "exercise_type", value: exerciseType.rawValue),
        ]
        guard let url = components.url else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(ServerError.self, from: data).detail)
                ?? "伺服器錯誤（\(http.statusCode)）"
            throw APIError.server(statusCode: http.statusCode, message: message)
        }
        return try decoder.decode([LeaderboardEntry].self, from: data)
    }

    /// 共用的「具有 JSON body」request 處理，集中加入 token 與解析錯誤。
    private func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        token: String? = nil
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(ServerError.self, from: data).detail)
                ?? "伺服器錯誤（\(http.statusCode)）"
            throw APIError.server(statusCode: http.statusCode, message: message)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// GET 等沒有 request body 的共用處理流程。
    private func sendWithoutBody<Response: Decodable>(
        path: String,
        method: String,
        token: String
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(ServerError.self, from: data).detail)
                ?? "伺服器錯誤（\(http.statusCode)）"
            throw APIError.server(statusCode: http.statusCode, message: message)
        }
        return try decoder.decode(Response.self, from: data)
    }
}

/// 用於忽略不需要使用的 JSON 回傳欄位。
private struct EmptyResponse: Decodable {}
