import Foundation
import Observation

/// App-wide sign-in state machine.
@MainActor
@Observable
final class SessionModel {
    enum State {
        case launching
        case signedOut
        case twoFactor
        case mailboxPassword
        case loadFailed(String)
        case ready(MailService)
    }

    private(set) var state: State = .launching

    /// Identifies the current screen, for animating between sign-in steps.
    var stateID: String {
        switch state {
        case .launching: return "launching"
        case .signedOut: return "signedOut"
        case .twoFactor: return "twoFactor"
        case .mailboxPassword: return "mailboxPassword"
        case .loadFailed: return "loadFailed"
        case .ready: return "ready"
        }
    }
    var errorMessage: String?
    private(set) var isBusy = false

    private let api = APIClient()
    private var auth: AuthService { AuthService(api: api) }
    /// Kept in memory only between the password and 2FA steps, to unlock keys afterwards.
    private var pendingPassword: String?
    private var pendingPasswordMode = 1

    func restore() async {
        await api.setOnTokensChanged { tokens in SessionStore.tokens = tokens }
        guard let tokens = SessionStore.tokens, SessionStore.passphrases != nil else {
            SessionStore.clear()
            state = .signedOut
            return
        }
        await api.setTokens(tokens)
        await loadMailbox()
    }

    func loadMailbox() async {
        guard let passphrases = SessionStore.passphrases else {
            state = .signedOut
            return
        }
        do {
            state = .ready(try await MailService.load(api: api, passphrases: passphrases))
        } catch APIError.sessionExpired, APIError.unauthorized {
            SessionStore.clear()
            errorMessage = APIError.sessionExpired.errorDescription
            state = .signedOut
        } catch CryptoError.wrongMailboxPassword {
            // The password changed elsewhere; ask for it again.
            SessionStore.passphrases = nil
            state = .mailboxPassword
        } catch {
            state = .loadFailed(error.localizedDescription)
        }
    }

    func login(username: String, password: String) async {
        await run {
            switch try await self.auth.login(username: username, password: password) {
            case .needsTwoFactor(let passwordMode):
                self.pendingPassword = password
                self.pendingPasswordMode = passwordMode
                self.state = .twoFactor
            case .needsMailboxPassword:
                self.state = .mailboxPassword
            case .unlocked(let passphrases):
                await self.finish(passphrases)
            }
        }
    }

    func submitTwoFactor(code: String) async {
        await run {
            try await self.auth.submitTwoFactor(code: code)
            if self.pendingPasswordMode == 2 {
                self.pendingPassword = nil
                self.state = .mailboxPassword
            } else if let password = self.pendingPassword, case .unlocked(let passphrases) = try await self.auth.unlock(password: password) {
                await self.finish(passphrases)
            }
        }
    }

    func submitMailboxPassword(_ password: String) async {
        await run {
            if case .unlocked(let passphrases) = try await self.auth.unlock(password: password) {
                await self.finish(passphrases)
            }
        }
    }

    func signOut() async {
        await auth.logout()
        SessionStore.clear()
        pendingPassword = nil
        state = .signedOut
    }

    private func finish(_ passphrases: [String: String]) async {
        pendingPassword = nil
        SessionStore.passphrases = passphrases
        await loadMailbox()
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
