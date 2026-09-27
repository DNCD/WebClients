import SwiftUI

struct RootView: View {
    @Environment(AccountManager.self) private var manager
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            if manager.isRestoring && manager.accounts.isEmpty {
                LaunchView()
            } else if let step = manager.loginStep {
                switch step {
                case .credentials: LoginView()
                case .twoFactor: TwoFactorView()
                case .mailboxPassword: MailboxPasswordView()
                }
            } else if let account = manager.activeAccount, case .failed(let message) = account.state, manager.readyAccounts.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load your mailbox", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await account.load(settings: settings) } }
                        .buttonStyle(.borderedProminent)
                    Button("Sign Out", role: .destructive) { Task { await manager.signOut(account.id) } }
                }
            } else if manager.readyAccounts.isEmpty {
                LaunchView()
            } else {
                MainView()
            }
        }
        .tint(Theme.brand)
        .animation(.smooth, value: manager.loginStep)
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            AuthBackground()
            VStack(spacing: 16) {
                AppMark(size: 88)
                ProgressView().tint(.white)
            }
        }
    }
}

/// Shared chrome for the sign-in steps: gradient backdrop, app mark, title and a card of content.
private struct AuthScreen<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            AuthBackground()
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        AppMark(size: 76)
                        Text(title)
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        Text(subtitle)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(.top, 56)

                    VStack(spacing: 14) {
                        content
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 20, y: 10)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct AuthBackground: View {
    var body: some View {
        Theme.brandGradient
            .overlay(alignment: .topTrailing) {
                Circle().fill(.white.opacity(0.08)).frame(width: 320).offset(x: 120, y: -120)
            }
            .overlay(alignment: .bottomLeading) {
                Circle().fill(.white.opacity(0.06)).frame(width: 260).offset(x: -110, y: 90)
            }
            .ignoresSafeArea()
    }
}

struct AppMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            Image(systemName: "envelope.fill")
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(Theme.brandGradient)
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: size * 0.26, weight: .bold))
                .foregroundStyle(.white, Theme.protection)
                .offset(x: size * 0.26, y: size * 0.22)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct FieldStyle: ViewModifier {
    let systemImage: String

    func body(content: Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            content
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension View {
    func authField(_ systemImage: String) -> some View { modifier(FieldStyle(systemImage: systemImage)) }
}

private struct PrimaryButton: View {
    let title: String
    let isBusy: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isBusy ? 0 : 1)
                if isBusy { ProgressView().tint(.white) }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(!isEnabled || isBusy)
    }
}

private struct ErrorBanner: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

struct LoginView: View {
    @Environment(AccountManager.self) private var manager
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focused: Field?

    private enum Field { case username, password }

    var body: some View {
        AuthScreen(title: manager.accounts.isEmpty ? "Mail" : "Add Account", subtitle: "End-to-end encrypted email,\nwith trackers blocked by default.") {
            TextField("Email or username", text: $username)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .username)
                .submitLabel(.next)
                .onSubmit { focused = .password }
                .authField("person")
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focused, equals: .password)
                .submitLabel(.go)
                .onSubmit(signIn)
                .authField("lock")
            ErrorBanner(message: manager.errorMessage)
            PrimaryButton(title: "Sign In", isBusy: manager.isBusy, isEnabled: !username.isEmpty && !password.isEmpty, action: signIn)
            Label("Your password never leaves this device (SRP).", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !manager.accounts.isEmpty {
                Button("Cancel", role: .cancel) { manager.cancelLogin() }
                    .font(.subheadline)
            }
        }
    }

    private func signIn() {
        guard !username.isEmpty, !password.isEmpty else { return }
        focused = nil
        Task { await manager.login(username: username, password: password) }
    }
}

struct TwoFactorView: View {
    @Environment(AccountManager.self) private var manager
    @State private var code = ""

    var body: some View {
        AuthScreen(title: "Verify It's You", subtitle: "Enter the 6-digit code from your authenticator app.") {
            TextField("123456", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .font(.title2.monospacedDigit().weight(.semibold))
                .multilineTextAlignment(.center)
                .authField("number")
                .onChange(of: code) { _, newValue in
                    code = String(newValue.filter(\.isNumber).prefix(6))
                    if code.count == 6 { submit() }
                }
            ErrorBanner(message: manager.errorMessage)
            PrimaryButton(title: "Verify", isBusy: manager.isBusy, isEnabled: code.count == 6, action: submit)
            Button("Cancel", role: .cancel) { manager.cancelLogin() }
                .font(.subheadline)
        }
    }

    private func submit() {
        guard !manager.isBusy else { return }
        Task { await manager.submitTwoFactor(code: code) }
    }
}

struct MailboxPasswordView: View {
    @Environment(AccountManager.self) private var manager
    @State private var password = ""

    var body: some View {
        AuthScreen(title: "Unlock Mailbox", subtitle: "Your mailbox password decrypts your keys on this device.") {
            SecureField("Mailbox password", text: $password)
                .onSubmit(submit)
                .authField("key")
            ErrorBanner(message: manager.errorMessage)
            PrimaryButton(title: "Unlock", isBusy: manager.isBusy, isEnabled: !password.isEmpty, action: submit)
            Button("Cancel", role: .cancel) { manager.cancelLogin() }
                .font(.subheadline)
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        Task { await manager.submitMailboxPassword(password) }
    }
}

struct ErrorSection: View {
    let message: String?

    var body: some View {
        if let message {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}
