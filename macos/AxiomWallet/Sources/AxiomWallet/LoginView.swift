import SwiftUI
import AxiomSdk

/// Login screen — the entry point on app launch when at least one
/// wallet exists on disk. Mirrors `views/00_login.html` from the
/// design package, rendered with native SwiftUI primitives.
///
/// Per the integration rule: this screen NEVER opens its own
/// network sockets. All wallet interaction goes through the FFI
/// (`AxiomWallet.open` + `verifyWalletKey`).
struct LoginView: View {
    @EnvironmentObject private var session: AppSession

    @State private var walletDir: String = defaultWalletDir()
    @State private var appPassword: String = ""
    @State private var errorMessage: String? = nil
    @State private var isUnlocking: Bool = false
    @State private var showRecovery: Bool = false
    @State private var showLoadBackup: Bool = false
    @State private var showDiagnostic: Bool = false
    @State private var refreshTrigger: Int = 0
    @State private var recoveryNudge: String? = nil
    @State private var didOfferBiometric: Bool = false
    @FocusState private var passwordFieldFocused: Bool

    var body: some View {
        ZStack {
            DesignTokens.bgSecondary.ignoresSafeArea()
            VStack(spacing: 0) {
                loginCard
            }
        }
        .onAppear {
            // Brief delay so the window finishes activating before we
            // grab focus — without this, the password field claims
            // focus before macOS has actually made the app frontmost
            // and the focus gets clobbered.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                passwordFieldFocused = true
            }
            // Auto-offer Touch ID once per appearance when enrolled.
            // Cancelling the prompt just falls back to the password
            // field — no error, the field already has focus.
            if canUseBiometric && !didOfferBiometric {
                didOfferBiometric = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    unlockWithBiometric()
                }
            }
        }
        .sheet(isPresented: $showRecovery) {
            RecoveryView(
                onClose: { showRecovery = false },
                onRecovered: {
                    // After a successful reset, dismiss the sheet and
                    // surface a hint so the user knows the new password
                    // applies — they still need to type it into the
                    // login field.
                    showRecovery = false
                    recoveryNudge = "Password reset succeeded. Type your new password to unlock."
                    appPassword = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        passwordFieldFocused = true
                    }
                }
            )
        }
        .sheet(isPresented: $showDiagnostic) {
            DiagnosticSheet(onClose: { showDiagnostic = false })
        }
        .sheet(isPresented: $showLoadBackup) {
            LoadBackupSheet(
                onClose: { showLoadBackup = false },
                onImported: {
                    showLoadBackup = false
                    recoveryNudge = "Wallet imported. Type the wallet_key you used on the source device to unlock."
                    appPassword = ""
                    // Bump the trigger so walletEmailHint re-reads
                    // the newly-imported wallet's email from disk.
                    refreshTrigger &+= 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        passwordFieldFocused = true
                    }
                }
            )
        }
    }

    private var loginCard: some View {
        VStack(spacing: 0) {
            brandMark

            Text("Welcome back")
                .font(DesignTokens.Typography.heading)
                .padding(.top, DesignTokens.Spacing.xxs)

            Text(walletEmailHint)
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textSecondary)
                .padding(.top, DesignTokens.Spacing.xxs)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("APP PASSWORD")
                    .font(DesignTokens.Typography.sectionLabel)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .tracking(0.4)
                SecureField("Enter your app password", text: $appPassword)
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordFieldFocused)
                    .onSubmit(unlock)
                Text("This is the password you set when installing the wallet. It unlocks your wallet sets.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .padding(.top, DesignTokens.Spacing.lg)

            if let error = errorMessage {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(error)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                    if isCorruptionError(error) {
                        Button("Run wallet diagnostic") { showDiagnostic = true }
                            .buttonStyle(.plain)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.brandPrimary)
                    }
                }
                .padding(DesignTokens.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.statusRejectedBgSoft)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
                .padding(.top, DesignTokens.Spacing.xs)
            }
            if let nudge = recoveryNudge {
                Text(nudge)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusCleanFg)
                    .padding(.top, DesignTokens.Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: unlock) {
                if isUnlocking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.xxs)
                } else {
                    Text("Unlock")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.xxs)
                        .font(DesignTokens.Typography.bodyStrong)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.brandPrimary)
            .controlSize(.large)
            .disabled(appPassword.isEmpty || isUnlocking)
            .padding(.top, DesignTokens.Spacing.md)

            if canUseBiometric {
                Button(action: unlockWithBiometric) {
                    Label("Unlock with \(Biometric.typeName)", systemImage: "touchid")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.xxs)
                        .font(DesignTokens.Typography.label)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isUnlocking)
                .padding(.top, DesignTokens.Spacing.xs)
            }

            Divider().padding(.top, DesignTokens.Spacing.lg)

            VStack(spacing: DesignTokens.Spacing.xs) {
                Button("Load wallet from backup file") {
                    showLoadBackup = true
                }
                .buttonStyle(.plain)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.brandPrimary)

                Button("Forgot app password?") {
                    showRecovery = true
                }
                .buttonStyle(.plain)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.brandPrimary)
            }
            .padding(.top, DesignTokens.Spacing.sm)
            // Touch refreshTrigger so SwiftUI re-renders the email
            // hint after a successful backup import.
            .background(Color.clear.id(refreshTrigger))
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xxl, leading: DesignTokens.Spacing.xxl, bottom: DesignTokens.Spacing.xl, trailing: DesignTokens.Spacing.xxl))
        .frame(width: 380)
        .background(DesignTokens.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel)
                .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
        )
    }

    private var brandMark: some View {
        // Official AXIØM seal — vector reproduction of the v2
        // approved mark (`assets/AXIOM_Official_Logo_Package_v2/`).
        // Per the guidelines: monochrome black, native proportions
        // preserved, no stroke-only redrawing. The "Welcome back"
        // headline acts as the wordmark in this context.
        AxiomSeal(color: DesignTokens.axiomBlack, height: 60)
            .padding(.bottom, DesignTokens.Spacing.xxs)
    }

    private var walletEmailHint: String {
        // Best-effort: peek at the wallet directory and surface the
        // first wallet's email. If anything fails, show the directory
        // path. No network access — pure on-disk inspection.
        let firstWalletEmail = (try? quickPeekFirstWalletEmail(parentDir: walletDir))
            ?? walletDir
        return firstWalletEmail
    }

    /// Whether to offer the Touch ID button — hardware present, a
    /// fingerprint enrolled, and the user opted in via Settings.
    private var canUseBiometric: Bool {
        Biometric.isEnabled && Biometric.isAvailable
    }

    /// Shown when macOS blocked access to the wallet's at-rest encryption key
    /// (the user clicked Deny on the Keychain prompt, or the keychain is
    /// locked). This is NOT a wrong password, and — critically — the app does
    /// not reset or overwrite anything, so granting access recovers the wallet.
    private var keychainBlockedMessage: String {
        "macOS blocked access to this wallet's encryption key — this is NOT a wrong password. "
        + "Quit AxiomWallet and reopen it, and when macOS asks to use a key in your keychain, "
        + "click \"Always Allow\". Your wallet is intact; do NOT reset or erase anything."
    }

    private func unlock() {
        guard !appPassword.isEmpty else { return }
        errorMessage = nil
        isUnlocking = true

        // The app password is a Mac-side credential (Keychain verifier),
        // separate from the per-wallet `wallet_key` — the wallet key
        // still gates signing, prompted per-send. See AppSecurity.swift.
        Task { @MainActor in
            defer { isUnlocking = false }
            do {
                let loaded = try loadAllPairs(parentDir: walletDir)
                // Keychain access to the at-rest key was BLOCKED (Deny / locked
                // keychain). The wallets just "loaded" under a throwaway key, so
                // any password would read as wrong — show the real cause + the
                // safe recovery, and DON'T touch anything.
                if WalletKeychain.accessBlocked {
                    errorMessage = keychainBlockedMessage
                    return
                }
                guard !loaded.isEmpty else {
                    errorMessage = "No wallets found at \(walletDir)."
                    return
                }
                if AppPassword.isSet() {
                    guard AppPassword.verify(appPassword) else {
                        errorMessage = "Wrong password."
                        return
                    }
                    // Migration detection: if the typed app password
                    // ALSO verifies as the first pair's wallet key,
                    // the two credentials are the same string. That's
                    // the pre-2026-05-27 onboarding default (one
                    // password to remember). Settings → Security
                    // reads this flag to surface a migration notice
                    // recommending the user diverge them for the
                    // shoulder-surf defense.
                    let shared = loaded[0].normal.verifyWalletKey(walletKey: appPassword)
                    UserDefaults.standard.set(
                        shared,
                        forKey: "axiom.appPasswordSharedWithWalletKey"
                    )
                } else {
                    // Migration: a wallet created before the app-password
                    // existed at all (e.g. via the CLI) has no app
                    // password yet. Verify against the wallet key — as
                    // the old login did — and adopt that value as the
                    // app password. The pair will then be in the
                    // "shared" state, which the detection above will
                    // pick up on the next login.
                    guard loaded[0].normal.verifyWalletKey(walletKey: appPassword) else {
                        errorMessage = "Wrong password."
                        return
                    }
                    AppPassword.set(appPassword)
                    UserDefaults.standard.set(
                        true,
                        forKey: "axiom.appPasswordSharedWithWalletKey"
                    )
                }
                completeUnlock(loaded)
            } catch {
                errorMessage = WalletKeychain.accessBlocked
                    ? keychainBlockedMessage
                    : "Couldn't open wallet: \(error.localizedDescription)"
            }
        }
    }

    private func unlockWithBiometric() {
        errorMessage = nil
        isUnlocking = true
        Task { @MainActor in
            defer { isUnlocking = false }
            let ok = await Biometric.authenticate(reason: "unlock AXIOM Wallet")
            guard ok else {
                // Cancelled or failed — leave the password field for
                // the user to fall back to. No error noise.
                return
            }
            // A passing biometric check is the authorization — the
            // wallet files open without the app password.
            do {
                let loaded = try loadAllPairs(parentDir: walletDir)
                guard !loaded.isEmpty else {
                    errorMessage = "No wallets found at \(walletDir)."
                    return
                }
                completeUnlock(loaded)
            } catch {
                errorMessage = "Couldn't open wallet: \(error.localizedDescription)"
            }
        }
    }

    private func completeUnlock(_ loaded: [LoadedPair]) {
        // Setting `pairs` non-empty also arms the idle-lock watcher
        // (AppSession.pairs didSet).
        session.pairs = loaded
        session.activePairIndex = 0
        session.activeMode = .normal
    }
}

/// Open every wallet pair on disk into `LoadedPair` records.
///
/// Reads `pairs.json` (via the FFI's `listWalletPairs`) and opens
/// every wallet directory it references. Falls back to
/// "find any single wallet, treat it as a partial pair" when
/// pairs.json is empty or absent — typical after a CLI-only
/// `wallet create` that doesn't register a pair.
func loadAllPairs(parentDir: String) throws -> [LoadedPair] {
    let registered = (try? listWalletPairs(parentDir: parentDir)) ?? []
    if !registered.isEmpty {
        return try registered.map { pairView in
            let normal = pairView.normalWalletName.flatMap {
                try? AxiomWallet.openVaulted(dir: "\(parentDir)/\($0)")
            }
            let ark = pairView.arkWalletName.flatMap {
                try? AxiomWallet.openVaulted(dir: "\(parentDir)/\($0)")
            }
            guard let normal else {
                throw NSError(
                    domain: "AxiomWallet", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Wallet set '\(pairView.name)' has no Normal wallet."]
                )
            }
            return LoadedPair(name: pairView.name, normal: normal, ark: ark)
        }
    }

    // Fallback: no pairs.json. Find the first wallet on disk and
    // present it as a one-member pair named after its directory.
    let firstWalletDir = try findFirstWalletDir(parentDir: parentDir)
    let normal = try AxiomWallet.openVaulted(dir: firstWalletDir)
    let displayName = (firstWalletDir as NSString).lastPathComponent
    return [LoadedPair(name: displayName, normal: normal, ark: nil)]
}

// MARK: - Filesystem helpers (no network — defaultWalletDir lives in
// AxiomWalletApp.swift since it's shared with the routing check)

/// Peek the first wallet on disk and return its email. Pure local
/// inspection — opens the wallet via `AxiomWallet.open` and reads
/// `email()`. Any error is surfaced to the caller as a thrown.
private func quickPeekFirstWalletEmail(parentDir: String) throws -> String {
    let dir = try findFirstWalletDir(parentDir: parentDir)
    let wallet = try AxiomWallet.openVaulted(dir: dir)
    return wallet.email()
}

/// Heuristic: does the error text look like wallet-file corruption
/// (vs a benign "wrong password" or "no wallets" path)? When true, the
/// LoginView surfaces a "Run wallet diagnostic" link so the user can
/// inspect + recover. Strings come from the FFI's `FfiError` Display
/// impls — match on the variant name prefix so wording changes don't
/// silently break detection.
func isCorruptionError(_ message: String) -> Bool {
    let lower = message.lowercased()
    return lower.contains("walletversionmismatch")
        || lower.contains("walletnotfound")
        || lower.contains("walletlocked")
        || lower.contains("storageerror")
        || lower.contains("couldn't open wallet")
        || lower.contains("cbor decode")
        || lower.contains("bad magic")
}

private func findFirstWalletDir(parentDir: String) throws -> String {
    let fm = FileManager.default
    let entries = try fm.contentsOfDirectory(atPath: parentDir)
    for name in entries.sorted() {
        let walletCbor = "\(parentDir)/\(name)/wallet.axiom"
        if fm.fileExists(atPath: walletCbor) {
            return "\(parentDir)/\(name)"
        }
    }
    throw NSError(
        domain: "AxiomWallet", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "No wallets found at \(parentDir). Run onboarding first."]
    )
}
