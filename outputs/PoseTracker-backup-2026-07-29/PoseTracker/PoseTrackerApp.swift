import SwiftUI

/// App 的進入點。SwiftUI 會從這裡建立第一個畫面。
@main
struct PoseTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            // ContentView 負責組合相機預覽、姿態資訊與使用者介面。
            ContentView()
        }
    }
}
