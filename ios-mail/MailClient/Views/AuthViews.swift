import SwiftUI

struct RootView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        switch session.state {
        case .launching:
            ProgressView()
        case .signedOut:
            LoginView()
        case .twoFactor:
            TwoFactorView()
        case .mailboxPassword:
            MailboxPasswordView()
        case .loadFailed(let message):
            ContentUnavailableView {
                Label("Couldn't load your mailbox", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await session.loadMailbox() } }
                Button("Sign Out", role: .destructive) { Task { await session.signOut() } }
            }
        case .ready(let service):
            MainView(service: service)
        }
    }
}

struct LoginView: View {
    @Environment(SessionModel.self) private var session
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email or username", text: $username)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("Your password is verified with SRP and never sent to the server.")
                }
                ErrorSection(message: session.errorMessage)
                Section {
                    Button {
                        Task { await session.login(username: username, password: password) }
                    } label: {
                        BusyLabel(title: "Sign In", isBusy: session.isBusy)
                    }
                    .disabled(username.isEmpty || password.isEmpty || session.isBusy)
                }
            }
            .navigationTitle("Sign In")
        }
    }
}

struct TwoFactorView: View {
    @Environment(SessionModel.self) private var session
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Enter the code from your authenticator app") {
                    TextField("123456", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                }
                ErrorSection(message: session.errorMessage)
                Section {
                    Button {
                        Task { await session.submitTwoFactor(code: code) }
                    } label: {
                        BusyLabel(title: "Verify", isBusy: session.isBusy)
                    }
                    .disabled(code.count < 6 || session.isBusy)
                    Button("Cancel", role: .cancel) { Task { await session.signOut() } }
                }
            }
            .navigationTitle("Two-Factor Authentication")
        }
    }
}

struct MailboxPasswordView: View {
    @Environment(SessionModel.self) private var session
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Mailbox password", text: $password)
                } footer: {
                    Text("Your mailbox password unlocks your encryption keys on this device.")
                }
                ErrorSection(message: session.errorMessage)
                Section {
                    Button {
                        Task { await session.submitMailboxPassword(password) }
                    } label: {
                        BusyLabel(title: "Unlock", isBusy: session.isBusy)
                    }
                    .disabled(password.isEmpty || session.isBusy)
                    Button("Cancel", role: .cancel) { Task { await session.signOut() } }
                }
            }
            .navigationTitle("Unlock Mailbox")
        }
    }
}

struct ErrorSection: View {
    let message: String?

    var body: some View {
        if let message {
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }
}

struct BusyLabel: View {
    let title: String
    let isBusy: Bool

    var body: some View {
        HStack {
            Text(title)
            if isBusy {
                Spacer()
                ProgressView()
            }
        }
    }
}
