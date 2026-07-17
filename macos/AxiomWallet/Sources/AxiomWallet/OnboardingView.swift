import SwiftUI
import AxiomSdk

// =================================================================
// Onboarding flow — 8 steps from a fresh install to a usable wallet.
//
// Step 0 · Trust verification — display the network fingerprint, user
//          confirms it matches an out-of-band published value.
// Step 1 · Identity            — email + first pair name.
// Step 2 · Passwords           — set two credentials. The FIRST
//          pair's wallet key (gates signing + encrypts wallet.axiom
//          at rest; each additional pair the user creates later
//          gets its own wallet key) and the app password (one
//          per Mac install, gates the app's login screen for
//          every pair). Default is separate values (shoulder-surf
//          defense); user can opt into "use the first wallet key
//          as the app password too" via a tickbox.
// Step 3 · Generate            — create_wallet_pair via FFI — produces
//          Personal-Normal + Personal-Ark wallets sharing wallet_key.
// Step 4 · Backup wallet_secrets — display BOTH 32-byte secrets in
//          the 8×4 grid layout from the design package. User saves
//          (paper / PDF). Confirmation gate before proceeding.
// Step 5 · Kiddo setup         — detect that AxiomKiddo.app is running
//          AND has an account for this wallet's email. Without it, the
//          Genesis claim below has no transport and the user gets a
//          confusing 60s timeout rather than a clear setup problem.
//          Inserted in 2026-05-21 — see commit message + the helper
//          in `KiddoPreflight.swift` for the failure mode it closes.
// Step 6 · Genesis claim       — fund_genesis. Stubbed in this commit
//          (the FFI surface for fund_genesis isn't wired through
//          uniffi yet); the screen presents the offer and advances.
//          Real wallet.fund() lands once the validator-mesh path is
//          reachable from this Mac.
// Step 7 · Done                — brief confirmation, hand off to the
//          unlocked placeholder.
// =================================================================

/// Holds intermediate values across the 8-step flow.
final class OnboardingState: ObservableObject {
    @Published var step: Int = 0

    // Step 1 — identity.
    @Published var email: String = ""
    @Published var pairName: String = "Personal"

    // Step 1 — FACT class is INFERRED from `email`'s domain.
    // Typing an `@axiom.internal` address makes this a dev-class
    // wallet (`docs/AXIOM_DESIGN_FactClassIsolation.md`); anything
    // else is public-class. `devAuthorized` becomes true after the
    // user enters the correct dev passcode for the current email
    // and resets whenever `email` changes.
    @Published var devAuthorized: Bool = false
    @Published var showDevPasscode: Bool = false

    // Step 2 — wallet key (gates signing, also encrypts wallet.axiom).
    @Published var password: String = ""
    @Published var passwordConfirm: String = ""

    // Step 2 — app password (gates the login screen / app session).
    //
    // Default is separate from the wallet key: the threat the app
    // password defends against is "someone shoulder-surfed my wallet
    // key during a send and now wants to open the app to browse my
    // balance + history." If both are the same string, that defense
    // collapses. User can opt into sharing by ticking
    // `shareAppPassword` — onboarding then sets the app password equal
    // to the wallet key (the old behavior).
    @Published var shareAppPassword: Bool = false
    @Published var appPassword: String = ""
    @Published var appPasswordConfirm: String = ""

    /// Step 2 — opt-in to biometric unlock, offered when the Mac has
    /// Touch ID / Face ID hardware. Applied at wallet generation.
    @Published var enableBiometric: Bool = false

    // Step 3 — generation results.
    @Published var normalWallet: AxiomWallet? = nil
    @Published var arkWallet: AxiomWallet? = nil

    // Generation status for the spinner / error UI.
    @Published var isGenerating: Bool = false
    @Published var generationError: String? = nil

    // Step 4 — backup confirmation.
    @Published var backupConfirmed: Bool = false

    func advance() { step += 1 }
    func retreat() { if step > 0 { step -= 1 } }

    var passwordsMatch: Bool {
        !password.isEmpty && password == passwordConfirm
    }

    /// True when the app password fields are well-formed (when
    /// `shareAppPassword` is on, the app password is derived from
    /// the wallet key and this returns true vacuously).
    var appPasswordReady: Bool {
        if shareAppPassword { return true }
        return !appPassword.isEmpty
            && appPassword == appPasswordConfirm
            && appPassword.count >= 8
    }

    /// True when Step 2 is ready to advance.
    var passwordStepReady: Bool {
        passwordsMatch && password.count >= 8 && appPasswordReady
    }

    /// The string Onboarding should write to `AppPassword.set(...)`.
    /// `shareAppPassword` mode preserves the historical "one
    /// password to remember" behavior; the default (separate) writes
    /// whatever the user typed into `appPassword`.
    var effectiveAppPassword: String {
        shareAppPassword ? password : appPassword
    }

    /// Email that will actually be passed to createWalletPair.
    /// Class is inferred from the domain — anything ending in
    /// `@axiom.internal` is dev-class (the SDK auto-detects this
    /// at register time per sdk/client/src/nabla.rs), anything else is
    /// public-class.
    var effectiveEmail: String {
        email.trimmingCharacters(in: .whitespaces)
    }

    /// True iff the typed email is @axiom.internal — the dev-class
    /// indicator. Drives the inline notice + Continue gating.
    var isDevEmail: Bool {
        walletClass(ofEmail: effectiveEmail) == .devClass
    }

    /// In formal release builds, `@axiom.internal` emails are
    /// rejected at the UI layer.
    var devBlockedInReleaseBuild: Bool {
        #if AXIOM_RELEASE_BUILD
        return isDevEmail
        #else
        return false
        #endif
    }

    /// True when the email has an `@` but nothing before it — the
    /// user typed only a domain, or macOS autofill mangled the field
    /// into a bare `@axiom.internal`. Drives both the Continue gate
    /// and the inline "enter a username" notice.
    var emailMissingLocalPart: Bool {
        let e = effectiveEmail
        guard let at = e.firstIndex(of: "@") else { return false }
        return e[..<at].isEmpty
    }

    var canProceedFromIdentity: Bool {
        // Require a real shape — non-empty local-part AND domain.
        // `.contains("@")` alone let "@axiom.internal" through.
        let parts = effectiveEmail.split(separator: "@",
                                         maxSplits: 1,
                                         omittingEmptySubsequences: false)
        let validShape = parts.count == 2
            && !parts[0].isEmpty
            && !parts[1].isEmpty
        return validShape
            && !pairName.trimmingCharacters(in: .whitespaces).isEmpty
            && !devBlockedInReleaseBuild
    }
}

/// Shared dev passcode — same literal AxiomKiddo's SettingsView,
/// the CarrierPreferences picker, and AddPairView use.
private let kOnboardingDevPasscode = "fatmama approve axiom"

/// Top-level onboarding container — owns the state, dispatches to
/// the step view for the current `step` index.
struct OnboardingView: View {
    @StateObject private var state = OnboardingState()
    @EnvironmentObject private var session: AppSession

    var body: some View {
        ZStack {
            DesignTokens.bgSecondary.ignoresSafeArea()
            VStack(spacing: 0) {
                stepRail
                Group {
                    switch state.step {
                    case 0: TrustVerifyStep(state: state)
                    case 1: IdentityStep(state: state)
                    case 2: PasswordStep(state: state)
                    case 3: GenerateStep(state: state)
                    case 4: BackupStep(state: state)
                    case 5: KiddoSetupStep(state: state)
                    case 6: GenesisStep(state: state)
                    default: DoneStep(state: state) {
                        // Hand off the freshly-created pair as the
                        // single unlocked entry in the session. Login
                        // state is implicit (the user just set the
                        // password moments ago).
                        if let normal = state.normalWallet {
                            let pair = LoadedPair(
                                name: state.pairName,
                                normal: normal,
                                ark: state.arkWallet
                            )
                            session.pairs = [pair]
                            session.activePairIndex = 0
                            session.activeMode = .normal
                        }
                    }
                    }
                }
                .frame(maxWidth: 700)
                .padding(.horizontal, DesignTokens.Spacing.xxl)
                .padding(.vertical, DesignTokens.Spacing.xl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var stepRail: some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            ForEach(0..<8, id: \.self) { i in
                Rectangle()
                    .fill(railColor(for: i))
                    .frame(height: 3)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xxl)
        .padding(.top, DesignTokens.Spacing.lg)
    }

    private func railColor(for i: Int) -> Color {
        if i < state.step { return DesignTokens.statusCleanAccent }
        if i == state.step { return DesignTokens.brandPrimary }
        return DesignTokens.bgTertiary
    }
}

// =================================================================
// Step 0 — Trust verification
// =================================================================
struct TrustVerifyStep: View {
    @ObservedObject var state: OnboardingState
    @State private var verified = false

    private var fingerprint: String { networkFingerprint() }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepHeader(
                step: 0,
                title: "Verify the AXIOM network",
                subtitle: "Compare this fingerprint to the value published in the Yellow Paper, on axiom.dev, or in a signed press release. They must match exactly. If they don't, stop and check that you downloaded the wallet from the official source."
            )

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("NETWORK FINGERPRINT")
                    .font(DesignTokens.Typography.sectionLabel)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .tracking(0.4)
                Text(fingerprint)
                    .font(DesignTokens.Typography.mono)
                    .padding(DesignTokens.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.bgPrimary)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                            .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
                    .textSelection(.enabled)
            }

            Toggle(isOn: $verified) {
                Text("I have verified this fingerprint matches the published value.")
                    .font(DesignTokens.Typography.label)
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Continue") { state.advance() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .disabled(!verified)
            }
            .padding(.top, DesignTokens.Spacing.xxs)
        }
    }
}

// =================================================================
// Step 1 — Identity
// =================================================================
struct IdentityStep: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepHeader(
                step: 1,
                title: "Your identity",
                subtitle: "Your email is your principal identity. Multiple wallets can share the same email — they're distinguished by salt. The wallet set name is the label on the tab strip."
            )

            emailSection

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                fieldLabel("WALLET SET NAME")
                TextField("Personal", text: $state.pairName)
                    .textFieldStyle(.roundedBorder)
                Text("Generates Personal-Normal + Personal-Ark wallets. You can add more wallet sets later (Treasury, Operations, etc.).")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }

            HStack {
                Button("Back") { state.retreat() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Spacer()
                Button("Continue") { onContinueTap() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .disabled(!state.canProceedFromIdentity)
            }
        }
        .onChange(of: state.email) { _, _ in
            // Editing the email invalidates any prior dev passcode
            // authorisation.
            state.devAuthorized = false
        }
        .sheet(isPresented: $state.showDevPasscode) {
            OnboardingDevPasscodeSheet { entered in
                state.showDevPasscode = false
                if entered == kOnboardingDevPasscode {
                    state.devAuthorized = true
                    state.advance()
                }
            }
        }
    }

    /// Single email field — class is INFERRED from the typed
    /// domain. When the user has typed `@axiom.internal`, an
    /// inline notice surfaces (a) that this will be a dev wallet
    /// and (b) the dev-passcode gate at Continue time.
    private var emailSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            fieldLabel("EMAIL")
            // No `.textContentType(.emailAddress)`: that annotation
            // hooks the field into macOS Hide-My-Email / iCloud
            // Private Relay autofill, which can replace the typed
            // value with a system-managed alias. The wallet email is
            // a persistent identity, decided once — never a value to
            // pick off a system list.
            TextField("you@example.com", text: $state.email)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            if state.emailMissingLocalPart {
                Text("Enter a username before the @ — e.g. you@axiom.internal.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }
            if state.isDevEmail {
                devEmailNotice
            }
        }
    }

    @ViewBuilder
    private var devEmailNotice: some View {
        if state.devBlockedInReleaseBuild {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                    .font(DesignTokens.Typography.label)
                Text("Developer wallets (`@axiom.internal`) cannot be created from this release build. Use a dev / demo build of AxiomWallet to set one up.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.xs, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.xs))
            .background(DesignTokens.statusRejectedBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        } else {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(DesignTokens.statusScarredFg)
                    .font(DesignTokens.Typography.label)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DesignTokens.Spacing.xxs) {
                        Text("Developer wallet")
                            .font(DesignTokens.Typography.sectionLabel)
                            .foregroundStyle(DesignTokens.statusScarredFg)
                        if state.devAuthorized {
                            Text("✓ dev passcode entered")
                                .font(DesignTokens.Typography.micro)
                                .foregroundStyle(DesignTokens.statusCleanFg)
                        } else {
                            Text("· dev passcode required at Continue")
                                .font(DesignTokens.Typography.micro)
                                .foregroundStyle(DesignTokens.textTertiary)
                        }
                    }
                    Text("@axiom.internal class — dev-AXC sandbox, isolated from public production AXC. Claim routes to the 1M dev pool (AXIOM_DESIGN_FactClassIsolation.md).")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.xs, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.xs))
            .background(DesignTokens.statusScarredBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        }
    }

    /// Continue handler — if the email is `@axiom.internal` and
    /// the user hasn't yet entered the dev passcode for it, open
    /// the passcode sheet. The sheet's correct-passcode callback
    /// sets `devAuthorized` and advances the step.
    private func onContinueTap() {
        if state.isDevEmail && !state.devAuthorized {
            state.showDevPasscode = true
            return
        }
        state.advance()
    }
}

/// Dev-passcode sheet for onboarding (third instance, same
/// shape as CarrierPreferences and AddPairView — Swift doesn't
/// share private views across files).
private struct OnboardingDevPasscodeSheet: View {
    let onSubmit: (String) -> Void
    @State private var entered: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("DEV PASSCODE")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text("Creating a developer (test) wallet requires the dev passcode. Developer wallets use the @axiom.internal class — they can only transact with other developer wallets and claim from the 1M dev-AXC pool (isolated from public production AXC). See AXIOM_DESIGN_FactClassIsolation.md.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Passcode", text: $entered)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Cancel") { onSubmit("") }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button("OK") { onSubmit(entered) }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: 380)
    }
}

// =================================================================
// Step 2 — Password
// =================================================================
struct PasswordStep: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepHeader(
                step: 2,
                title: "Set your passwords",
                subtitle: "Two distinct credentials. This first wallet key signs every payment from this wallet set — each additional wallet set you create later gets its own wallet key. The app password unlocks the app's login screen for ALL wallets on this Mac — one app password covers every wallet set you'll ever add. They default to different passwords so that someone watching you type a wallet key during a send can't immediately open the app afterwards to browse balance or history. You can opt to use this first wallet key as the app password too if you prefer one password to remember."
            )

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                fieldLabel("WALLET KEY")
                SecureField("8 characters minimum", text: $state.password)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                fieldLabel("CONFIRM WALLET KEY")
                SecureField("re-enter to confirm", text: $state.passwordConfirm)
                    .textFieldStyle(.roundedBorder)
            }

            if !state.passwordConfirm.isEmpty && !state.passwordsMatch {
                Text("Wallet keys do not match.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }

            Divider().padding(.vertical, 2)

            switchRow(
                isOn: $state.shareAppPassword,
                title: "Use this first wallet key as the app password too",
                detail: "Convenient but weaker: anyone who learns this first wallet key (e.g., by watching you type it during a send) can also open the app and browse balance + history. Leave this off to set a separate app password."
            )

            if !state.shareAppPassword {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    fieldLabel("APP PASSWORD")
                    SecureField("8 characters minimum, different from this wallet key recommended",
                                text: $state.appPassword)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    fieldLabel("CONFIRM APP PASSWORD")
                    SecureField("re-enter to confirm", text: $state.appPasswordConfirm)
                        .textFieldStyle(.roundedBorder)
                }

                if !state.appPasswordConfirm.isEmpty
                    && state.appPassword != state.appPasswordConfirm
                {
                    Text("App passwords do not match.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                }
            }

            if Biometric.isAvailable {
                switchRow(
                    isOn: $state.enableBiometric,
                    title: "Enable \(Biometric.typeName) unlock",
                    detail: "Unlock the app with \(Biometric.typeName) instead of typing your app password. The wallet key is still required to sign payments. Change this any time in Settings → Security."
                )
            }

            HStack {
                Button("Back") { state.retreat() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Spacer()
                Button("Generate wallets") { state.advance() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .disabled(!state.passwordStepReady)
            }
        }
    }

    /// A title + description row with a switch pinned to the top-trailing.
    ///
    /// The default `Toggle { multi-line VStack }.toggleStyle(.switch)`
    /// vertically-centers the switch against the whole label block, so
    /// rows with different-height descriptions render their switches at
    /// different heights and read as misaligned. Pinning the switch to
    /// `.top` (and hiding its own label) lines every switch up with its
    /// title regardless of how far the description wraps.
    @ViewBuilder
    private func switchRow(isOn: Binding<Bool>, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignTokens.Typography.label)
                Text(detail)
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

// =================================================================
// Step 3 — Generate (calls create_wallet_pair via FFI)
// =================================================================
struct GenerateStep: View {
    @ObservedObject var state: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepHeader(
                step: 3,
                title: "Generating your wallets",
                subtitle: "Two independent wallets — Normal mode (everyday, online) and Ark mode (offline, partition-tolerant). Each gets its own keypair and wallet_secret. Both wallets in this pair share the wallet key you just set; the app password is stored separately on this Mac."
            )

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                if state.isGenerating {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("Generating Personal-Normal and Personal-Ark…")
                            .font(DesignTokens.Typography.label)
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                } else if state.normalWallet != nil && state.arkWallet != nil {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(DesignTokens.statusCleanAccent)
                        Text("Both wallets created.")
                            .font(DesignTokens.Typography.bodyStrong)
                    }
                    if let normal = state.normalWallet {
                        addressLine("Normal", try? normal.address())
                    }
                    if let ark = state.arkWallet {
                        addressLine("Ark", try? ark.address())
                    }
                } else if let err = state.generationError {
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "xmark.octagon")
                            .font(DesignTokens.Typography.label)
                            .foregroundStyle(DesignTokens.statusRejectedFg)
                        Text(err)
                            .font(DesignTokens.Typography.label)
                            .foregroundStyle(DesignTokens.statusRejectedFg)
                    }
                } else {
                    Text("Click Generate to create your wallets.")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))

            HStack {
                Button("Back") { state.retreat() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(state.isGenerating)
                Spacer()
                if state.normalWallet == nil {
                    Button("Generate") { generate() }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignTokens.brandPrimary)
                        .controlSize(.large)
                        .disabled(state.isGenerating)
                } else {
                    Button("Continue") { state.advance() }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignTokens.brandPrimary)
                        .controlSize(.large)
                }
            }
        }
        .onAppear {
            // Auto-fire generation on entry. Wallet creation is fast
            // and there's nothing else for the user to do on this
            // screen — clicking a "Generate" button would be a step
            // for nothing.
            if state.normalWallet == nil && !state.isGenerating {
                generate()
            }
        }
    }

    private func generate() {
        state.isGenerating = true
        state.generationError = nil
        Task { @MainActor in
            defer { state.isGenerating = false }
            do {
                let pair = try createWalletPairVaulted(
                    pairName: state.pairName,
                    email: state.effectiveEmail,
                    walletKey: state.password,
                    parentDir: defaultWalletDir()
                )
                state.normalWallet = pair.normal
                state.arkWallet = pair.ark
                // App password: defaults to a SEPARATE string from the
                // wallet key (`state.appPassword`). Only equal to the
                // wallet key if the user explicitly ticked
                // `shareAppPassword` on Step 2 — see
                // `effectiveAppPassword` for the resolution. The two
                // can be diverged or re-converged later via
                // Settings → Security.
                AppPassword.set(state.effectiveAppPassword)
                // Set biometric unlock to exactly what the user chose
                // on the password step — explicit both ways, so a new
                // wallet never inherits a stale enrolment left in the
                // Keychain / UserDefaults by a previous wallet on this
                // Mac (which is why it could appear "on by default").
                if state.enableBiometric {
                    Biometric.enable()
                } else {
                    Biometric.disable()
                }
            } catch {
                state.generationError = "Couldn't create wallets: \(error.localizedDescription)"
            }
        }
    }

    private func addressLine(_ label: String, _ address: String?) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(label.uppercased())
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
                .frame(width: 60, alignment: .leading)
            Text(address ?? "—")
                .font(DesignTokens.Typography.monoSmall)
                .textSelection(.enabled)
        }
    }
}

// =================================================================
// Step 4 — Backup wallet_secrets
// =================================================================
struct BackupStep: View {
    @ObservedObject var state: OnboardingState

    private var normalSecretHex: String {
        state.normalWallet?.walletSecretHex() ?? ""
    }
    private var arkSecretHex: String {
        state.arkWallet?.walletSecretHex() ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepHeader(
                step: 4,
                title: "Back up your wallet secrets",
                subtitle: "Two secrets — one per wallet. Each is required to redeem incoming cheques to that wallet. Lose them and the money locked behind them is unrecoverable. Write them down on paper, store them somewhere offline. Anyone with these bytes can claim cheques in your name."
            )

            ScrollView {
                VStack(spacing: DesignTokens.Spacing.sm) {
                    secretBlock(
                        title: "Personal — Normal mode",
                        tag: "NORMAL",
                        tagColor: DesignTokens.brandPrimary,
                        tagBg: DesignTokens.brandPrimarySoft,
                        hex: normalSecretHex,
                        address: try? state.normalWallet?.address() ?? nil
                    )
                    secretBlock(
                        title: "Personal — Ark mode",
                        tag: "ARK",
                        tagColor: DesignTokens.textSecondary,
                        tagBg: DesignTokens.bgTertiary,
                        hex: arkSecretHex,
                        address: try? state.arkWallet?.address() ?? nil
                    )
                }
            }
            .frame(maxHeight: 380)

            HStack(spacing: DesignTokens.Spacing.xs) {
                Spacer()
                Button {
                    printBackup(state: state)
                } label: {
                    HStack(spacing: DesignTokens.Spacing.xxs) {
                        Image(systemName: "printer")
                        Text("Print backup")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Open the macOS print dialog with a paper-friendly layout — ideal for storing in a safe deposit box or fireproof envelope.")
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("⚠ AXIOM cannot recover lost secrets.")
                    .font(DesignTokens.Typography.labelStrong)
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Text("There is no support line. The secrets above are the only copy. Save them, then confirm below.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusScarredFg)
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.statusScarredBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))

            Toggle(isOn: $state.backupConfirmed) {
                Text("I have written down both secrets and stored them somewhere safe.")
                    .font(DesignTokens.Typography.label)
            }
            .toggleStyle(.checkbox)

            HStack {
                Button("Back") { state.retreat() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Spacer()
                Button("Continue") { state.advance() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .disabled(!state.backupConfirmed)
            }
        }
    }

    @ViewBuilder
    private func secretBlock(
        title: String,
        tag: String,
        tagColor: Color,
        tagBg: Color,
        hex: String,
        address: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Text(title)
                        .font(DesignTokens.Typography.sectionLabel)
                        .tracking(0.4)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .textCase(.uppercase)
                    Text(tag)
                        .font(DesignTokens.Typography.chip)
                        .tracking(0.3)
                        .foregroundStyle(tagColor)
                        .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, 1)
                        .background(tagBg)
                        .clipShape(Capsule())
                }
                Spacer()
                if let address {
                    Text(address)
                        .font(DesignTokens.Typography.monoSmall)
                        .foregroundStyle(DesignTokens.textTertiary)
                        .textSelection(.enabled)
                }
            }
            secretGrid(hex: hex)
        }
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel)
                .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
        )
    }

    private func secretGrid(hex: String) -> some View {
        // Split the 64 hex chars into 32 pairs (1 byte each), arrange
        // in 4 rows × 8 cols mirroring the design package's grid.
        let bytes: [(Int, String)] = stride(from: 0, to: hex.count, by: 2).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: min(2, hex.count - i))
            return (i / 2, String(hex[start..<end]))
        }
        let columns = Array(repeating: GridItem(.flexible(), spacing: DesignTokens.Spacing.xxs), count: 8)
        return LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.xxs) {
            ForEach(bytes, id: \.0) { idx, byte in
                VStack(spacing: 1) {
                    Text(String(format: "%02d", idx + 1))
                        .font(DesignTokens.Typography.micro)
                        .tracking(0.4)
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text(byte)
                        .font(DesignTokens.Typography.mono)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignTokens.Spacing.xxs)
                .background(DesignTokens.bgPrimary)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.chip)
                        .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
                )
            }
        }
    }
}

// =================================================================
// Step 5 — AxiomKiddo mail-transport setup
//
// The wallet's SDK doesn't speak SMTP/POP3 — it writes UMP envelopes
// into `<walletDir>/outbox/` and waits for cheques to land in
// `<walletDir>/maildir/inbox/`. Something else has to ship the
// outbox via SMTP and drop responses into the maildir. On Mac that
// something is AxiomKiddo.app.
//
// Without Kiddo configured for THIS wallet's email, the genesis
// claim in step 6 hangs for its full 60s timeout and surfaces a
// confusing "didn't receive validator cheques" error.
//
// For DEV-CLASS wallets (@axiom.internal — they run against a local
// FATMAMA env) this step auto-provisions Kiddo: it fires the
// `axiomkiddo://provision` URL, Kiddo creates a `.axiomDev` account
// bound to this wallet, and the gate flips to ready hands-free. The
// user sees a brief "Setting up AxiomKiddo…" then a green check.
//
// For non-dev (real-email) wallets, auto-provision is skipped — their
// SMTP/POP3 needs a password Kiddo can't know — so they get the
// manual path: launch Kiddo, add an account in Settings, return.
//
// Hard gate by default. The "Continue without Kiddo" escape hatch
// is for users running a different transport (sendmail/postfix etc.);
// they accept the claim may fail and re-attempt from the
// post-onboarding GenesisClaimSheet.
// =================================================================
struct KiddoSetupStep: View {
    @ObservedObject var state: OnboardingState

    /// Polled at 1Hz while this view is on-screen. Flips to `.ready`
    /// the moment Kiddo is launched + configured (manually, or by the
    /// auto-provision below), so Continue enables without a refresh.
    @StateObject private var watcher: KiddoPreflightWatcher

    /// True once the user explicitly waived the Kiddo requirement.
    /// Persists for the lifetime of the onboarding flow only — a
    /// fresh launch starts in the gated state.
    @State private var bypassConfirmed: Bool = false

    /// Dev-class wallets auto-provision Kiddo. `autoProvisionFired`
    /// guards against re-firing within one view lifetime;
    /// `autoProvisionGaveUp` drops the "Setting up…" spinner back to
    /// the manual UI if the provision hasn't taken effect after a
    /// grace window (Kiddo crashed, URL scheme not registered, etc.).
    @State private var autoProvisionFired = false
    @State private var autoProvisionGaveUp = false

    init(state: OnboardingState) {
        self.state = state
        // Match key is the email the user typed in step 1. That's
        // the address Kiddo's POP3 will poll and that the validators
        // address responses to.
        _watcher = StateObject(wrappedValue: KiddoPreflightWatcher(
            walletEmail: state.effectiveEmail
        ))
    }

    /// True while an auto-provision is in flight: provisioning was
    /// triggered (dev email OR dev-safe SMTP host), the watcher hasn't
    /// reached `.ready` yet, and we haven't hit the give-up grace
    /// window. Mirrors `maybeAutoProvision`'s gate so the "Setting up
    /// AxiomKiddo…" spinner shows for any wallet that actually fired
    /// the provision URL, not only `@axiom.internal`.
    private var isAutoProvisioning: Bool {
        let provisionAllowed = state.isDevEmail
            || KiddoPreflight.smtpHostIsDevSafe(appDir: defaultAppDir())
        guard provisionAllowed, autoProvisionFired, !autoProvisionGaveUp else {
            return false
        }
        if case .ready = watcher.state { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepHeader(
                step: 5,
                title: "Set up AxiomKiddo",
                subtitle: "AxiomKiddo is a small companion app that ships your wallet's outbound emails and delivers incoming cheques. Without it, the genesis claim in the next step has nowhere to send the broadcast and will time out."
            )

            statusPanel

            HStack {
                Button("Back") { state.retreat() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Spacer()
                if case .ready = watcher.state {
                    Button("Continue") { state.advance() }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignTokens.brandPrimary)
                        .controlSize(.large)
                } else if isAutoProvisioning {
                    // Provision in flight — no action, just a spinner.
                    // The watcher will flip to .ready and swap in the
                    // Continue button on its own.
                    ProgressView().controlSize(.small)
                } else if bypassConfirmed {
                    Button("Continue anyway") { state.advance() }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignTokens.brandPrimary)
                        .controlSize(.large)
                } else {
                    primaryActionButton
                }
            }
        }
        .onAppear {
            watcher.start()
            maybeAutoProvision()
        }
        .onDisappear { watcher.stop() }
    }

    /// Auto-provision Kiddo for dev-class wallets. Fires once per view
    /// lifetime. Skipped when:
    ///   - the wallet is non-dev (real email — Kiddo can't know the
    ///     SMTP/POP3 password, so configuration stays manual);
    ///   - Kiddo isn't installed (nothing to provision into — the
    ///     manual `.notInstalled` card tells the user to install it);
    ///   - Kiddo is already `.ready` (nothing to do).
    ///
    /// When it does fire, it sends `axiomkiddo://provision` with this
    /// wallet's email + Normal-wallet directory. Kiddo creates the
    /// account and starts its worker; the 1Hz watcher then flips the
    /// gate to `.ready` within a second or two — no user action.
    ///
    /// Re-firing is harmless: the Kiddo side is idempotent (it no-ops
    /// if an account for this email already exists), so navigating
    /// Back/Forward through onboarding can't create duplicates.
    private func maybeAutoProvision() {
        // Bug B fix — broaden the auto-provision gate. Pre-fix this
        // checked only `state.isDevEmail` (i.e. `@axiom.internal`),
        // which left `@example.com` onboarding flows against a dev
        // FATMAMA env stranded: no Kiddo account → no XAXIOM-REGISTER
        // → FATMAMA drops every inbound cheque silently. axiom.conf's
        // smtp_host points at the same FATMAMA box for both email
        // classes in the dev env, so it's the better signal: if the
        // SMTP relay is a FATMAMA-style host (loopback, mooo.com,
        // *.internal, …), auto-provision is safe regardless of email
        // domain. Real-ISP hosts still fall through to manual
        // configuration — Kiddo can't synthesise their passwords.
        let provisionAllowed = state.isDevEmail
            || KiddoPreflight.smtpHostIsDevSafe(appDir: defaultAppDir())
        guard provisionAllowed, !autoProvisionFired else { return }
        switch watcher.state {
        case .ready, .notInstalled:
            return
        case .notRunning, .noAccountForEmail:
            break
        }
        autoProvisionFired = true
        // Normal-wallet directory — AxiomWallet's create_pair lays
        // wallets out at `<walletsParent>/<pairName>-normal` (mirrors
        // KiddoAccount.defaultWalletDir + AddPairView's suffix strip).
        let walletDir = defaultWalletDir() + "/" + state.pairName + "-normal"
        KiddoPreflight.provisionKiddo(
            walletEmail: state.effectiveEmail,
            walletDir: walletDir,
            label: state.pairName
        )
        // Grace window: if the gate still isn't `.ready` after this,
        // the provision didn't take (Kiddo crash, scheme unregistered,
        // …) — drop the spinner and reveal the manual fallback UI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if case .ready = watcher.state {
                // provisioned fine — nothing to do
            } else {
                autoProvisionGaveUp = true
            }
        }
    }

    @ViewBuilder
    private var statusPanel: some View {
        // Auto-provision in flight takes precedence over the raw
        // watcher state — while it's running the not-ready states
        // (.notRunning / .noAccountForEmail) are expected and
        // transient, so we show progress instead of an error card.
        if isAutoProvisioning {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Setting up AxiomKiddo…")
                        .font(DesignTokens.Typography.bodyStrong)
                }
                Text("Configuring a mail-transport account for \(state.effectiveEmail) against your local FATMAMA env. This is automatic — no setup needed.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.brandPrimarySoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        } else {
            watcherStatePanel
        }
    }

    @ViewBuilder
    private var watcherStatePanel: some View {
        switch watcher.state {
        case .ready:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("✓ AxiomKiddo is running")
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusCleanFg)
                Text("An account is configured for \(state.effectiveEmail). The genesis claim in the next step will route through it.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.statusCleanBg)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))

        case .notInstalled:
            statusCard(
                title: "AxiomKiddo isn't installed",
                detail: "The wallet looked for \(KiddoPreflight.installPath) and didn't find it. Install AxiomKiddo from the same DMG as the wallet, or via the dev-build script if you're working in-tree.",
                hint: "If you're using a different mail transport (a dev FATMAMA env, sendmail / postfix, etc.) you can continue anyway — the claim will route through your transport."
            )

        case .notRunning:
            statusCard(
                title: "AxiomKiddo isn't running",
                detail: "It's installed at \(KiddoPreflight.installPath) but no process is currently active. Launch it, then return here — this gate refreshes automatically every second.",
                hint: nil
            )

        case .noAccountForEmail(let email):
            statusCard(
                title: "Kiddo has no account for \(email)",
                detail: "AxiomKiddo is running but hasn't been told to relay mail for this wallet's email. Open Kiddo Settings, add an account with `walletEmail = \(email)` pointing at this wallet's directory, then return here.",
                hint: nil
            )
        }
    }

    @ViewBuilder
    private func statusCard(title: String, detail: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: "xmark.octagon")
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                Text(LocalizedStringKey(title))
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }
            Text(detail)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
            if let hint {
                Text(hint)
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .padding(.top, DesignTokens.Spacing.xxs)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusRejectedBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    /// Primary action varies with current state: install missing →
    /// no button (user has to install themselves), not running →
    /// Launch Kiddo, no account → Open Kiddo Settings.
    @ViewBuilder
    private var primaryActionButton: some View {
        switch watcher.state {
        case .ready:
            EmptyView()

        case .notInstalled:
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Continue without Kiddo") { bypassConfirmed = true }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Use this if you're relying on a different mail transport (dev FATMAMA env, sendmail, etc.).")
                Button("Refresh") { watcher.recheck() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
            }

        case .notRunning:
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Continue without Kiddo") { bypassConfirmed = true }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Use this if you're relying on a different mail transport (dev FATMAMA env, sendmail, etc.).")
                Button("Launch Kiddo") { KiddoPreflight.launchKiddo() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
            }

        case .noAccountForEmail:
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Continue without Kiddo") { bypassConfirmed = true }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Use this if you're relying on a different mail transport (dev FATMAMA env, sendmail, etc.).")
                Button("Open Kiddo Settings") { KiddoPreflight.openKiddoForSettings() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
            }
        }
    }
}

// =================================================================
// Step 6 — Genesis claim (stubbed)
// =================================================================
struct GenesisStep: View {
    @ObservedObject var state: OnboardingState

    @State private var phase: Phase = .idle
    @State private var errorMessage: String? = nil
    @State private var resultBalance: UInt64 = 0
    @State private var resultRegistration: String = ""
    /// Wall-clock start of the broadcast — drives ClaimProgressView's
    /// elapsed ticker. Set when `phase` flips to `.broadcasting`.
    @State private var broadcastStartedAt: Date? = nil
    /// Drives the cancel-confirmation alert during a broadcast.
    @State private var showCancelAlert: Bool = false

    enum Phase {
        case idle           // not started yet
        case broadcasting   // fund_genesis call in flight
        case success        // received result
        case failed         // error or timeout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepHeader(
                step: 6,
                title: "Claim your starter balance",
                subtitle: "AXIOM gives every new wallet 1 AXC from the genesis pool. This is a one-time claim — the network witnesses it, Nabla registers it, and the AXC lands in your Normal wallet."
            )

            statusPanel

            HStack {
                Button("Back") { state.retreat() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(phase == .broadcasting)
                Spacer()
                if phase == .success {
                    Button("Continue") { state.advance() }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignTokens.brandPrimary)
                        .controlSize(.large)
                } else if phase == .failed || phase == .idle {
                    Button("Skip — claim later") { state.advance() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Button(phase == .failed ? "Try again" : "Claim 1 AXC") {
                        startClaim()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .disabled(state.normalWallet == nil)
                } else {
                    // broadcasting — Cancel is the only way out while a
                    // claim runs (the claim has no timeout, so a stuck
                    // carrier would otherwise trap the user here). Back
                    // stays disabled; Cancel is gated behind a warning
                    // because cancelling mid-witness-round can be
                    // terminal for the keypair (YP §17.11.7).
                    Button("Cancel claim") { showCancelAlert = true }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .alert("Cancel genesis claim?", isPresented: $showCancelAlert) {
                            Button("Keep claiming", role: .cancel) {}
                            Button("Cancel claim", role: .destructive) {
                                state.normalWallet?.requestSendCancel()
                            }
                        } message: {
                            Text("If the claim is still collecting validator signatures, cancelling can leave this wallet's keypair permanently unusable (YP §17.11.7) — you'd have to create a new wallet. No funds are lost (none exist yet). If your carrier is just slow, the claim has no timeout and will finish on its own — prefer waiting.")
                        }
                }
            }
        }
    }

    // MARK: - Subviews
    //
    // The Kiddo-running reminder lived here before the onboarding
    // gained a dedicated KiddoSetupStep (step 5). Step 5 verifies
    // Kiddo is running and configured for this wallet before the
    // user can advance to claim, so the reminder is now redundant
    // by construction. If the user kills Kiddo between steps 5 and
    // 6 the claim has no timeout and will keep waiting for cheques —
    // the Cancel button below is the escape, and the GenesisClaimSheet's
    // post-onboarding hard gate covers any later retry.

    @ViewBuilder
    private var statusPanel: some View {
        switch phase {
        case .idle:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("Click \"Claim 1 AXC\" to broadcast a genesis-claim TX. The wallet will:")
                    .font(DesignTokens.Typography.label)
                Text("  1. Sign the TX and write it to outbox/ (your carrier ships it)")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                Text("  2. Block on inbox/ for k=3 validator cheques (no timeout — waits until they arrive)")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                Text("  3. Register the txid with Nabla so subsequent self-redeem succeeds")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                Text("If the env isn't reachable the claim keeps waiting — use Cancel to stop it. You can retry any time before the wallet's first TX advances seq past 1.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .padding(.top, DesignTokens.Spacing.xxs)
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))

        case .broadcasting:
            ClaimProgressView(
                wallet: state.normalWallet,
                startedAt: broadcastStartedAt ?? Date()
            )

        case .success:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("✓ Genesis claim succeeded")
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusCleanFg)
                Text("New balance: \(formatBalance(resultBalance)) · \(formatAxcOnly(resultBalance))")
                    .font(DesignTokens.Typography.amount)
                Text("Nabla registration: \(resultRegistration)")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                if resultRegistration != "confirmed" {
                    Text("Registration didn't fully confirm. The TX is committed locally and will heal on next operation; you can proceed.")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                        .lineSpacing(2)
                }
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.statusCleanBg)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))

        case .failed:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Image(systemName: "xmark.octagon")
                        .font(DesignTokens.Typography.bodyStrong)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                    Text("Couldn't claim genesis funds")
                        .font(DesignTokens.Typography.bodyStrong)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                }
                Text(errorMessage ?? "Unknown error")
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                Text("Common cause: AxiomKiddo isn't running, or it's not pointed at this wallet's outbox / inbox. You can retry from the Overview banner any time before this wallet's first TX.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .padding(.top, DesignTokens.Spacing.xxs)
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.statusRejectedBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        }
    }

    // MARK: - Action

    /// Drives `wallet.fund_genesis()`. The wallet writes UMP to outbox/
    /// and blocks on inbox/ — the user's carrier (AxiomKiddo or the
    /// dev env's KIDDO daemon) is responsible for shipping SMTP and
    /// dropping inbound cheques. No Timer-driven inbound pull here.
    private func startClaim() {
        guard let wallet = state.normalWallet else {
            errorMessage = "No wallet loaded — onboarding state lost?"
            phase = .failed
            return
        }

        errorMessage = nil
        broadcastStartedAt = Date()
        phase = .broadcasting

        // GCD, not Task.detached: a `Task.detached` closure re-pins to
        // the main actor when the enclosing type is `@MainActor`-ish,
        // which beachballs the onboarding window for the whole claim
        // (same bug the SendCoordinator fix solved). The claim has no
        // timeout — it waits for the validator cheques indefinitely and
        // is cancellable via the Cancel button above (requestSendCancel).
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // CLAIM is 2-step (genesis de-orchestration, master 45dc832b): the
                // request leg (claim_genesis_full) runs the witness round + Nabla
                // register and waits for the genesis cheque to land PENDING, then
                // returns its id WITHOUT redeeming — the wallet is NOT funded yet.
                // The SDK no longer auto-redeems; we compose the completion redeem
                // here so onboarding "Claim" stays one tap. (redeem(empty) on the
                // rare missing-cheque race throws ChequeNotFound → handled below.)
                let result = try wallet.claimGenesisFull(
                    amountAtoms: 10_000_000_000,  // 1 AXC
                    reference: "genesis-claim"
                )
                let funded = try wallet.redeem(chequeId: result.pendingChequeId)
                DispatchQueue.main.async {
                    resultBalance = funded.newBalance
                    resultRegistration = result.registration
                    phase = .success
                }
            } catch {
                let parts = extractFfiErrorParts(error)
                DispatchQueue.main.async {
                    if parts.code == "SendCancelled" {
                        // User cancelled — return to the start so Back /
                        // Skip / Claim re-enable. The witness round (if
                        // it registered) is preserved; retrying resumes.
                        errorMessage = nil
                        phase = .idle
                    } else {
                        errorMessage = parts.message
                        phase = .failed
                    }
                }
            }
        }
    }
}

// =================================================================
// Step 7 — Done
// =================================================================
struct DoneStep: View {
    @ObservedObject var state: OnboardingState
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            stepHeader(
                step: 7,
                title: "Your wallet is ready",
                subtitle: "Personal wallet set created — Normal mode for everyday, Ark mode for offline. Both secrets backed up. Welcome to AXIØM."
            )

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("WHAT'S NEXT")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Send and Receive views aren't built yet. The next development commits add them. For now you'll see the wallet metadata view.")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .padding(.top, DesignTokens.Spacing.xxs)

            Spacer()

            HStack {
                Spacer()
                Button("Open my wallet") { onFinish() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
            }
        }
    }
}

// =================================================================
// Shared helpers (tight visual treatment match to the HTML mockups)
// =================================================================
@ViewBuilder
private func stepHeader(step: Int, title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
        Text("STEP \(step + 1) OF 8")
            .font(DesignTokens.Typography.sectionLabel)
            .tracking(0.4)
            .foregroundStyle(DesignTokens.textTertiary)
        Text(LocalizedStringKey(title))
            .font(DesignTokens.Typography.title)
        Text(subtitle)
            .font(DesignTokens.Typography.body)
            .foregroundStyle(DesignTokens.textSecondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func fieldLabel(_ text: String) -> some View {
    Text(LocalizedStringKey(text))
        .font(DesignTokens.Typography.sectionLabel)
        .tracking(0.4)
        .foregroundStyle(DesignTokens.textTertiary)
}
