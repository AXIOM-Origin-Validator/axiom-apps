import Foundation
import CryptoKit
import LocalAuthentication

// =================================================================
// AppSecurity — the app-password gate + Touch ID, both Mac-side.
//
// The app password is a SEPARATE credential from the per-wallet
// `wallet_key`. The wallet key still gates signing (verified per-send
// in SendView / BundleDetailView / HealConfirmSheet); the app password
// only unlocks the app session at the login screen.
//
// Storage: the app password is a salted SHA-256 verifier in
// UserDefaults — no plaintext at rest. It is deliberately NOT in the
// Keychain: ad-hoc-signed dev builds get a fresh code signature on
// every rebuild, and the Keychain gates a generic-password item on the
// signing identity, so each rebuild made macOS treat the wallet as a
// new app and prompt "allow access" for the verifier the prior build
// created. The verifier is a salted hash — not a recoverable secret —
// and only gates the app *session* (the wallet key independently gates
// signing), so a UserDefaults plist is an adequate store for it.
//
// Touch ID stores NOTHING: a successful biometric check is itself the
// authorization, because the wallet files open without the app
// password (it only gates the login screen). So biometric unlock is
// just `evaluatePolicy` → on success, open the session. This sidesteps
// the biometric-ACL Keychain entirely — that needs a
// `keychain-access-groups` entitlement an ad-hoc build cannot obtain.
//
// Onboarding sets the app password independently of the first
// pair's wallet key by default — a shoulder-surf defense, so that
// learning one credential doesn't immediately yield the other.
// (Each pair the user creates later has its OWN wallet key; the
// app password is single per Mac install and gates the login
// screen for every pair.) The user can opt in to "use this first
// wallet key as the app password too" via a tickbox on the
// onboarding password step (see OnboardingState.shareAppPassword);
// in either case the two are stored separately and can be
// diverged or re-converged later via Settings → Security.
// =================================================================

private let kVerifierKey = "axiom.appPasswordVerifier"
private let kBiometricEnabledKey = "axiom.biometricEnabled"

/// The app-password gate. Verifier-only at rest (salted SHA-256).
enum AppPassword {
    /// True once an app password has been established — by onboarding,
    /// or by first-login migration of a wallet created before this
    /// feature / by the CLI.
    static func isSet() -> Bool {
        UserDefaults.standard.data(forKey: kVerifierKey) != nil
    }

    /// Store (or replace) the app-password verifier.
    static func set(_ password: String) {
        // `UInt8.random` draws from the system CSPRNG on Apple
        // platforms — adequate for a 16-byte salt.
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let blob = salt + sha256(salt + Data(password.utf8))
        UserDefaults.standard.set(blob, forKey: kVerifierKey)
    }

    /// Constant-time check of a typed password against the verifier.
    static func verify(_ password: String) -> Bool {
        guard let blob = UserDefaults.standard.data(forKey: kVerifierKey),
              blob.count == 48
        else {
            return false
        }
        let salt = blob.prefix(16)
        let stored = blob.suffix(32)
        return constantTimeEqual(Data(stored), sha256(Data(salt) + Data(password.utf8)))
    }

    /// Verify `old`, then store `new`. Returns false (no change) if
    /// `old` is wrong.
    static func change(old: String, new: String) -> Bool {
        guard verify(old) else { return false }
        set(new)
        return true
    }

    /// Wipe the app password + any biometric enrolment. Used by the
    /// Recovery "erase everything" path.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: kVerifierKey)
        Biometric.disable()
    }
}

/// Touch ID / Face ID unlock — optional, layered on the app password.
enum Biometric {
    /// Whether this Mac has usable biometric hardware with an
    /// enrolled fingerprint/face.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Human label for UI copy — "Touch ID" / "Face ID" / "biometrics".
    static var typeName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .touchID: return "Touch ID"
        case .faceID:  return "Face ID"
        default:       return "biometrics"
        }
    }

    /// Whether the user has enabled biometric unlock. A plain
    /// UserDefaults flag — no secret is stored for biometrics.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: kBiometricEnabledKey)
    }

    /// Turn biometric unlock on. No secret is stored — a passing
    /// biometric check is itself the authorization at login time.
    static func enable() {
        UserDefaults.standard.set(true, forKey: kBiometricEnabledKey)
    }

    /// Turn biometric unlock off.
    static func disable() {
        UserDefaults.standard.set(false, forKey: kBiometricEnabledKey)
    }

    /// Present the system biometric prompt. Returns true if the user
    /// authenticated, false on cancel / failure.
    ///
    /// Uses `.deviceOwnerAuthenticationWithBiometrics` — biometric ONLY,
    /// no password fallback. This is the login-screen convenience
    /// path: the app password is already the canonical credential for
    /// "open the session," and we'd rather fall back to the typed
    /// password field than offer the macOS login password (which is
    /// what `.deviceOwnerAuthentication` would surface).
    static func authenticate(reason: String) async -> Bool {
        await withCheckedContinuation { cont in
            LAContext().evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            ) { success, _ in cont.resume(returning: success) }
        }
    }

    /// Stronger device-owner challenge for destructive, irreversible
    /// operations (currently: ERASE EVERYTHING). Uses
    /// `.deviceOwnerAuthentication` — accepts a biometric OR, on
    /// biometric failure / hardware absence, falls back to the macOS
    /// login password. macOS owns the prompt UI entirely; we just
    /// receive a Bool.
    ///
    /// Why this policy rather than the biometric-only one used at
    /// login: ERASE is reached from the Recovery sheet, which is
    /// itself the "I forgot the app password" path — so we can't
    /// gate on the AxiomWallet app password. We need a credential
    /// that lives OUTSIDE this app. The Mac's device owner
    /// (biometric or login password) is the cleanest such credential.
    /// It's not perfect against the "unlocked Mac in front of an
    /// adversary" threat — an attacker at an unlocked session
    /// plausibly knows the Mac password too — but it raises the
    /// floor meaningfully for casual snoops and matches the
    /// "the wallet's owner has consented to this destructive act"
    /// semantic.
    static func authenticateForDestructiveAction(reason: String) async -> Bool {
        await withCheckedContinuation { cont in
            LAContext().evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            ) { success, _ in cont.resume(returning: success) }
        }
    }
}

// ── crypto primitives ──────────────────────────────────────────────

private func sha256(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
}

private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}
