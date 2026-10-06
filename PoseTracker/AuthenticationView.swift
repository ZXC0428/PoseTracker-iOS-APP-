import SwiftUI

/// App 的本機登入／建立帳號入口。
struct AuthenticationView: View {
    @ObservedObject var authManager: AuthManager
    @State private var isRegistering = false
    @State private var userName = ""
    @State private var password = ""
    @State private var showsPassword = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.white, Color(.systemGray6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 50)
                    Image(systemName: "figure.run.circle.fill")
                        .font(.system(size: 82))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.mint, .gray.opacity(0.22))
                    VStack(spacing: 6) {
                        Text("POSE TRACKER")
                            .font(.title.bold())
                        Text(isRegistering ? "建立雲端訓練帳號" : "登入並繼續訓練")
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 14) {
                        TextField("使用者名稱", text: $userName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Group {
                                if showsPassword {
                                    TextField("密碼（至少 8 個字元）", text: $password)
                                } else {
                                    SecureField("密碼（至少 8 個字元）", text: $password)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            // 本機帳號不使用 iCloud 建議的隨機強密碼，避免使用者
                            // 未察覺欄位被替換，登出後無法重現同一組密碼。
                            .textContentType(.password)

                            Button {
                                showsPassword.toggle()
                            } label: {
                                Image(systemName: showsPassword ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(.separator), lineWidth: 0.5)
                        )

                        if let error = authManager.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button(action: submit) {
                            Group {
                                if authManager.isLoading {
                                    ProgressView().tint(.black)
                                } else {
                                    Text(isRegistering ? "建立帳號" : "登入")
                                }
                            }
                            .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .foregroundStyle(.black)
                                .background(.mint, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(userName.isEmpty || password.isEmpty || authManager.isLoading)

                        Button(isRegistering ? "已經有帳號？登入" : "沒有帳號？建立帳號") {
                            isRegistering.toggle()
                            password = ""
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .padding(22)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    private func submit() {
        // Task 讓網路登入非同步執行，避免阻塞 SwiftUI 主畫面。
        Task {
            if isRegistering {
                await authManager.register(
                    userName: userName,
                    password: password
                )
            } else {
                await authManager.signIn(userName: userName, password: password)
            }
        }
    }
}
