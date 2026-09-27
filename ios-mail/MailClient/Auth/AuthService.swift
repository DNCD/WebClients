import Foundation
import ProtonCoreCryptoGoInterface

/// Sign-in with SRP (the password never leaves the device), mirroring the web client's
/// `getInfo` → `auth` → `auth2FA` calls in `packages/shared/lib/api/auth.ts`.
struct AuthService {
    enum Step {
        case needsTwoFactor(passwordMode: Int)
        case needsMailboxPassword
        case unlocked(passphrases: [String: String])
    }

    let api: APIClient

    func login(username: String, password: String) async throws -> Step {
        let info: AuthInfoResponse = try await api.send(.post("core/v4/auth/info", [
            "Username": username,
            "Intent": "Proton",
        ], authenticated: false))

        let srp = try Crypto.call {
            CryptoGo.SrpNewAuth(info.version, username, Data(password.utf8), info.salt ?? "", info.modulus, info.serverEphemeral, $0)
        }
        let proofs = try srp.generateProofs(2048)
        guard let clientEphemeral = proofs.clientEphemeral,
              let clientProof = proofs.clientProof,
              let expectedServerProof = proofs.expectedServerProof else { throw CryptoError.unexpectedNil }

        let auth: AuthResponse = try await api.send(.post("core/v4/auth", [
            "Username": username,
            "ClientEphemeral": clientEphemeral.base64EncodedString(),
            "ClientProof": clientProof.base64EncodedString(),
            "SRPSession": info.srpSession,
            "PersistentCookies": 0,
        ], authenticated: false))

        guard Data(base64Encoded: auth.serverProof) == expectedServerProof else {
            throw CryptoError.serverProofMismatch
        }
        await api.setTokens(SessionTokens(uid: auth.uid, accessToken: auth.accessToken, refreshToken: auth.refreshToken))

        if let twoFactor = auth.twoFactor, twoFactor.enabled != 0 {
            if twoFactor.fido2Only {
                throw AuthError.securityKeyUnsupported
            }
            return .needsTwoFactor(passwordMode: auth.passwordMode)
        }
        return auth.needsMailboxPassword ? .needsMailboxPassword : try await unlock(password: password)
    }

    func submitTwoFactor(code: String) async throws {
        try await api.sendRaw(.post("core/v4/auth/2fa", ["TwoFactorCode": code]))
    }

    /// Derives the key passphrases and checks they actually unlock the keys.
    func unlock(password: String) async throws -> Step {
        async let user: UserResponse = api.send(.get("core/v4/users"))
        async let addresses: AddressesResponse = api.send(.get("core/v4/addresses"))
        async let salts: KeySaltsResponse = api.send(.get("core/v4/keys/salts"))
        let (u, a, s) = try await (user.user, addresses.addresses, salts.keySalts)

        let passphrases = try MailKeys.derivePassphrases(password: password, user: u, addresses: a, salts: s)
        _ = try MailKeys.unlock(user: u, addresses: a, passphrases: passphrases)
        return .unlocked(passphrases: passphrases)
    }

    func logout() async {
        _ = try? await api.sendRaw(APIRequest(method: .delete, path: "core/v4/auth"))
        await api.setTokens(nil)
    }
}

enum AuthError: LocalizedError {
    case securityKeyUnsupported

    var errorDescription: String? {
        "This account only allows security-key two-factor sign-in, which this app does not support yet. Add an authenticator app as a second method."
    }
}
