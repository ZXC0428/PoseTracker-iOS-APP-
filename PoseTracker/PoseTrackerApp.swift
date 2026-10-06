import SwiftUI

/// App 的進入點。SwiftUI 會從這裡建立第一個畫面。
@main
struct PoseTrackerApp: App {
    @StateObject private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if let user = authManager.currentUser {
                    AuthenticatedFlowView(user: user, authManager: authManager)
                        .id(user.id)
                } else {
                    AuthenticationView(authManager: authManager)
                }
            }
        }
    }
}
