import SwiftUI

/// App 的主畫面。
///
/// 這裡只負責呈現 UI 與轉送使用者操作；相機及 AI 判斷交給 PoseTracker，
/// 使用者與成績則交給 UserSessionStore，避免把所有邏輯塞在 View 裡。
struct ContentView: View {
    /// 姿態偵測器的生命週期與主畫面相同。
    @StateObject private var poseTracker = PoseTracker()
    /// 純記憶體使用者資料；App 結束後不保留。
    @StateObject private var userStore = UserSessionStore()
    /// 控制使用者管理 Sheet 與記錄完成提示。
    @State private var showingUsers = false
    @State private var showingSavedMessage = false
    /// 記錄清零前的次數，供 Alert 顯示。
    @State private var lastSavedCount = 0

    var body: some View {
        ZStack {
            // 相機畫面鋪滿整個背景。
            CameraPreview(session: poseTracker.session)
                .ignoresSafeArea()

            // 漸層讓白色文字在各種相機背景上都保持清楚。
            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // 主要資訊疊加在相機畫面上方。
            VStack(spacing: 20) {
                header
                Spacer()
                statusCard
                actionButtons
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            // 權限遭拒時，遮住無法使用的相機畫面並提供說明。
            if poseTracker.authorizationDenied {
                permissionMessage
            }
        }
        .task {
            // 畫面出現後請求權限、設定並啟動相機。
            await poseTracker.start()
        }
        .onDisappear {
            // 離開畫面時停止相機，節省電力與裝置溫度。
            poseTracker.stop()
        }
        // 使用者按右上角人物按鈕後顯示管理頁。
        .sheet(isPresented: $showingUsers) {
            UserManagerView(store: userStore)
        }
        // 成功寫入「本次記憶體紀錄」後顯示確認訊息。
        .alert("已記錄本次訓練", isPresented: $showingSavedMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text("\(userStore.selectedUser?.name ?? "使用者")完成 \(lastSavedCount) 次深蹲。")
        }
    }

    /// 頂端品牌、目前使用者與鏡頭切換按鈕。
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("POSE TRACKER")
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(.mint)
                Text("AI 深蹲計數器")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            Spacer()
            HStack(spacing: 10) {
                Button {
                    showingUsers = true
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.title3)
                        Text(userStore.selectedUser?.name ?? "使用者")
                            .font(.system(size: 9, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("選擇使用者")

                Button {
                    // 前鏡頭適合自拍，後鏡頭適合拍攝他人。
                    poseTracker.toggleCamera()
                } label: {
                    Image(systemName: "camera.rotate.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(
                    poseTracker.cameraPosition == .front ? "切換到後鏡頭" : "切換到前鏡頭"
                )
            }
        }
    }

    /// 即時顯示平均膝角度、完成次數與狀態提示。
    private var statusCard: some View {
        VStack(spacing: 18) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("膝關節角度")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(poseTracker.kneeAngle.map { "\(Int($0.rounded()))°" } ?? "--°")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    Text("完成次數")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                    Text("\(poseTracker.squatCount)")
                        .font(.system(size: 64, weight: .black, design: .rounded))
                        .foregroundStyle(.mint)
                        .contentTransition(.numericText())
                }
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(poseTracker.phase.color)
                    .frame(width: 9, height: 9)
                Text(poseTracker.phase.message)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Text(poseTracker.cameraPosition == .front ? "自拍" : "拍攝他人")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
    }

    /// 左側只清除目前計數；右側把訓練歸檔到目前使用者後再清零。
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                poseTracker.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.headline)
                    .frame(width: 52)
                    .padding(.vertical, 15)
                    .foregroundStyle(.white)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
            .accessibilityLabel("重新計數")

            Button {
                // 記住次數、加入記錄，再清除姿態狀態機。
                lastSavedCount = poseTracker.squatCount
                userStore.addRecord(squatCount: lastSavedCount)
                poseTracker.reset()
                showingSavedMessage = true
            } label: {
                Label("完成並記錄", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .foregroundStyle(.black)
                    .background(.mint, in: RoundedRectangle(cornerRadius: 18))
            }
            .disabled(poseTracker.squatCount == 0)
            .opacity(poseTracker.squatCount == 0 ? 0.55 : 1)
        }
    }

    /// 相機權限被拒絕時顯示的引導內容。
    private var permissionMessage: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
            Text("需要相機權限")
                .font(.title3.bold())
            Text("請到「設定」中允許 PoseTracker 使用相機，才能進行姿態偵測。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(30)
    }
}

/// 將偵測器狀態轉換成適合 UI 呈現的中文提示與顏色。
private extension SquatPhase {
    var message: String {
        switch self {
        case .searching: "請讓全身進入畫面"
        case .standing: "準備好，開始下蹲"
        case .lowered: "很好，站起來完成動作"
        }
    }

    var color: Color {
        switch self {
        case .searching: .orange
        case .standing: .mint
        case .lowered: .cyan
        }
    }
}
