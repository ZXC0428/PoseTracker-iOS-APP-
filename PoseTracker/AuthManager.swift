import Foundation

/// 登入畫面可理解的驗證錯誤；伺服器錯誤則保留其訊息。
enum AuthenticationError: LocalizedError {
    case invalidInput(String)
    case accountAlreadyExists
    case accountNotFound
    case incorrectPassword
    case network(String)
    case invalidCredentials
    case serverUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message): message
        case .accountAlreadyExists: "這個帳號已經存在。"
        case .accountNotFound: "找不到這個使用者名稱。"
        case .incorrectPassword: "密碼不正確。"
        case .network(let message): message
        case .invalidCredentials: "帳號或密碼錯誤，或找不到此使用者。"
        case .serverUnavailable: "目前無法連線到伺服器，請稍後再試。"
        }
    }
}

/// 管理遠端登入狀態；使用者快取放 SQLite，token 則放 Keychain。
@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var currentUser: LocalUser?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    private let database: DatabaseManager
    private let apiClient: APIClient

    init(database: DatabaseManager = .shared, apiClient: APIClient = .shared) {
        self.database = database
        self.apiClient = apiClient
        currentUser = TokenStore.load() == nil ? nil : try? database.fetchCurrentUser()
    }

    /// 先驗證輸入，再向 backend 註冊並建立本機使用者快取。
    @discardableResult
    func register(userName: String, password: String) async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            let cleanedAccount = userName.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard cleanedAccount.count >= 3 else {
                throw AuthenticationError.invalidInput("使用者名稱至少需要 3 個字元。")
            }
            guard cleanedAccount.count <= 100 else {
                throw AuthenticationError.invalidInput("使用者名稱不可超過 100 個字元。")
            }
            guard password.count >= 8 else {
                throw AuthenticationError.invalidInput("密碼至少需要 8 個字元。")
            }
            guard password.count <= 128 else {
                throw AuthenticationError.invalidInput("密碼不可超過 128 個字元。")
            }
            let response = try await apiClient.register(
                username: cleanedAccount,
                password: password
            )
            try TokenStore.save(response.accessToken)
            currentUser = try database.upsertRemoteUser(
                id: response.userID,
                account: response.username
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = localizedRegistrationMessage(for: error)
            return false
        }
    }

    @discardableResult
    func signIn(userName: String, password: String) async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            let cleanedAccount = userName.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let response = try await apiClient.login(
                username: cleanedAccount,
                password: password
            )
            try TokenStore.save(response.accessToken)
            currentUser = try database.upsertRemoteUser(
                id: response.userID,
                account: response.username
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = localizedSignInMessage(for: error)
            return false
        }
    }

    /// 清除目前使用者 session 與 Keychain token，但保留歷史訓練。
    func signOut() {
        do {
            try database.setCurrentUser(id: nil)
            TokenStore.clear()
            currentUser = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 將註冊端點的 HTTP／網路錯誤統一轉成中文。
    private func localizedRegistrationMessage(for error: Error) -> String {
        if let authenticationError = error as? AuthenticationError {
            return authenticationError.localizedDescription
        }
        if let apiError = error as? APIError,
           case .server(let statusCode, _) = apiError {
            switch statusCode {
            case 409: return AuthenticationError.accountAlreadyExists.localizedDescription
            case 422: return "帳號或密碼格式不符合規定，請重新確認。"
            case 500...599: return AuthenticationError.serverUnavailable.localizedDescription
            default: return "建立帳號失敗，請稍後再試。"
            }
        }
        return localizedNetworkMessage(for: error)
    }

    /// 登入一律不區分「帳號不存在」與「密碼錯誤」，避免外部探測帳號。
    private func localizedSignInMessage(for error: Error) -> String {
        if let apiError = error as? APIError,
           case .server(let statusCode, _) = apiError {
            switch statusCode {
            case 401: return AuthenticationError.invalidCredentials.localizedDescription
            case 422: return "帳號或密碼格式不符合規定，請重新確認。"
            case 500...599: return AuthenticationError.serverUnavailable.localizedDescription
            default: return "登入失敗，請稍後再試。"
            }
        }
        return localizedNetworkMessage(for: error)
    }

    /// URLSession 的常見連線錯誤使用固定中文，避免顯示系統英文內容。
    private func localizedNetworkMessage(for error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "發生未知錯誤，請稍後再試。"
        }
        switch urlError.code {
        case .notConnectedToInternet:
            return "目前沒有網路連線，請檢查 Wi-Fi 或行動網路。"
        case .timedOut:
            return "連線逾時，請稍後再試。"
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return AuthenticationError.serverUnavailable.localizedDescription
        default:
            return "網路連線發生錯誤，請稍後再試。"
        }
    }

}
    /// 向 backend 驗證帳密；App 本身不保存或比對明文密碼。
