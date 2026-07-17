import SwiftUI
import AppKit
import AxiomSdk

// =================================================================
// AddPairView — modal sheet opened by tapping the "+" tab.
//
// Two paths:
//   - Create new   — full pair generation (Normal + Ark) with a
//                    fresh wallet_key. Trimmed onboarding: pair
//                    name + email + password + generate +
//                    backup-secrets. The trust-verify and
//                    genesis-claim steps are NOT repeated (already
//                    completed during first-run onboarding for the
//                    initial pair).
//   - Load from file — NSOpenPanel → pick wallet.axiom → name on
//                    this Mac → register as a pair (partial — Ark
//                    companion can be created later from Wallets
//                    management once the SDK helper for
//                    "create-just-the-Ark-side" lands).
//
// On completion either path appends to session.pairs and sets the
// new pair as active so the user lands on its Overview.
//
// Per the integration rule: wallet creation is via
// AxiomSdk.createWalletPair / AxiomWallet.fromFile / pairs.json
// registration via addWalletPairRegistration. No URLSession.
// =================================================================

/// Default wallet-set names, in the order they're suggested as the
/// user fills the `MainAppView.MAX_PAIRS` (5) slots. Index 0
/// ("Personal") is what first-run onboarding creates; the Add-a-set
/// flow suggests the first of these NOT already taken, so filling all
/// five slots reads Personal → Treasury → Operations → Savings →
/// Reserve with no retyping (previously every add defaulted to
/// "Treasury"). Same vocabulary the onboarding hint already uses
/// ("Treasury, Operations, etc.").
let kDefaultPairNames = ["Personal", "Treasury", "Operations", "Savings", "Reserve"]

/// First `kDefaultPairNames` entry not already used by an existing
/// pair (case-insensitive). Past the list / when all are taken, falls
/// back to "Wallet N" so the field is never blank and never collides.
func suggestedPairName(existing: [String]) -> String {
    let taken = Set(existing.map { $0.lowercased() })
    for name in kDefaultPairNames where !taken.contains(name.lowercased()) {
        return name
    }
    return "Wallet \(existing.count + 1)"
}

struct AddPairView: View {
    @EnvironmentObject private var session: AppSession
    let onClose: () -> Void

    @State private var mode: AddMode = .createNew

    enum AddMode { case createNew, loadFile }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            header

            if session.pairs.count >= MainAppView.MAX_PAIRS {
                capReachedBlock
                HStack {
                    Spacer()
                    Button("Close", action: onClose)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            } else {
                modeToggle

                switch mode {
                case .createNew: CreateNewPairForm(session: session, onClose: onClose)
                case .loadFile:  LoadFromFileForm(session: session, onClose: onClose)
                }
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 540)
    }

    private var capReachedBlock: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Wallet set limit reached")
                .font(DesignTokens.Typography.bodyStrong)
            Text("This Mac can hold up to \(MainAppView.MAX_PAIRS) wallet sets (each set is Normal + Ark, so \(MainAppView.MAX_PAIRS * 2) wallets total). Remove a wallet set from Wallets management before adding another.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm,
                            leading: DesignTokens.Spacing.sm,
                            bottom: DesignTokens.Spacing.sm,
                            trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusScarredBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ADD WALLET SET")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Create a new wallet set or restore one from a backup file")
                    .font(DesignTokens.Typography.heading)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeOption(.createNew, label: "Create new")
            modeOption(.loadFile, label: "Load from file")
        }
        .padding(2)
        .background(DesignTokens.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    private func modeOption(_ value: AddMode, label: String) -> some View {
        Button(action: { mode = value }) {
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.labelStrong)
                .foregroundStyle(mode == value ? DesignTokens.textPrimary : DesignTokens.textSecondary)
                .padding(.horizontal, DesignTokens.Spacing.sm).padding(.vertical, DesignTokens.Spacing.xxs)
                .background(mode == value ? DesignTokens.bgPrimary : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        }
        .buttonStyle(.plain)
    }
}

// =================================================================
// Create-new sub-form
// =================================================================
private struct CreateNewPairForm: View {
    @ObservedObject var session: AppSession
    let onClose: () -> Void

    /// Seed `pairName` with the next unused default (Personal →
    /// Treasury → Operations → Savings → Reserve) based on what's
    /// already on disk, so the field arrives pre-filled with a
    /// distinct name per slot instead of always "Treasury". A fresh
    /// form is created each time the sheet opens, so this recomputes.
    init(session: AppSession, onClose: @escaping () -> Void) {
        _session = ObservedObject(wrappedValue: session)
        self.onClose = onClose
        _pairName = State(initialValue:
            suggestedPairName(existing: session.pairs.map { $0.name }))
    }

    @State private var pairName: String
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var passwordConfirm: String = ""
    @State private var step: CreateStep = .form
    @State private var generated: CreatedResult? = nil
    @State private var generationError: String? = nil
    @State private var backupConfirmed: Bool = false

    /// Whether the user has entered the correct dev passcode for
    /// the current email. Resets to `false` whenever `email`
    /// changes — re-typing the email requires re-authorising.
    /// Only relevant when the email's domain is `axiom.internal`.
    /// See `docs/AXIOM_DESIGN_FactClassIsolation.md`.
    @State private var devAuthorized: Bool = false
    /// Passcode input for the `.devAuth` step + its wrong-entry error.
    /// The passcode UI is an INLINE STEP of this sheet, NOT a nested
    /// `.sheet`: presenting a sheet-on-sheet while the Settings window
    /// is open gets silently dropped by SwiftUI/AppKit (live-reproduced
    /// 2026-07-07 — the binding then wedges `true` and every later
    /// Generate click no-ops until the AddPair sheet is reopened).
    /// An in-window step has no presentation machinery to drop.
    @State private var devPasscodeEntered: String = ""
    @State private var devPasscodeError: Bool = false

    enum CreateStep { case form, devAuth, generating, backup, done }

    struct CreatedResult {
        let normal: AxiomWallet
        let ark: AxiomWallet
        let normalSecretHex: String
        let arkSecretHex: String
    }

    var body: some View {
        switch step {
        case .form:        formStep
        case .devAuth:     devAuthStep
        case .generating:  generatingStep
        case .backup:      backupStep
        case .done:        doneStep
        }
    }

    private var passwordsMatch: Bool {
        !password.isEmpty && password == passwordConfirm
    }

    /// The email that will actually be passed to createWalletPair.
    /// Class is INFERRED from the domain — anything ending in
    /// `@axiom.internal` becomes a dev-class wallet, anything else
    /// becomes public-class. No separate "wallet class" toggle —
    /// the email field IS the declaration.
    private var effectiveEmail: String {
        email.trimmingCharacters(in: .whitespaces)
    }

    /// If the typed email matches the email of an already-loaded
    /// pair (case-insensitive), returns that pair's name so the UI
    /// can show a caution. AXIOM wallets generate distinct
    /// `wallet_id`s per pair regardless of shared email (salt is
    /// per-pair, hex is per-pair), so a collision is allowed —
    /// just worth flagging so the user knows the two pairs are
    /// independent identities under the same email contact.
    private var collidingPairName: String? {
        let typed = effectiveEmail
        guard !typed.isEmpty else { return nil }
        for pair in session.pairs {
            if pair.normal.email().caseInsensitiveCompare(typed) == .orderedSame {
                return pair.name
            }
        }
        return nil
    }

    /// True when the typed email is `@axiom.internal` — the SDK
    /// auto-detects this at register time per sdk/client/src/nabla.rs
    /// and routes the claim to the dev pool.
    private var isDevEmail: Bool {
        walletClass(ofEmail: effectiveEmail) == .devClass
    }

    /// In formal release builds, `@axiom.internal` emails are
    /// rejected at the UI layer — release DMGs cannot create dev
    /// wallets at all.
    private var devBlockedInReleaseBuild: Bool {
        #if AXIOM_RELEASE_BUILD
        return isDevEmail
        #else
        return false
        #endif
    }

    /// Dev passcode prompt fires on Generate click — not on every
    /// keystroke — so a user mistyping `@axiom.internal` partway
    /// through composing their email doesn't get interrupted.
    private var needsDevAuth: Bool {
        isDevEmail && !devAuthorized
    }

    private var canProceed: Bool {
        !pairName.trimmingCharacters(in: .whitespaces).isEmpty
            && effectiveEmail.contains("@")
            && password.count >= 8
            && passwordsMatch
            && !devBlockedInReleaseBuild
    }

    // MARK: form

    private var formStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Each pair is two independent wallets — Normal mode (everyday) + Ark mode (offline). Both share a wallet key, both have their own keypair and wallet_secret. The new pair gets its own key, distinct from your other pairs.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                fieldLabel("WALLET SET NAME")
                TextField("Treasury", text: $pairName)
                    .textFieldStyle(.roundedBorder)
            }

            emailSection

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                fieldLabel("WALLET KEY")
                SecureField("8 characters minimum", text: $password)
                    .textFieldStyle(.roundedBorder)
                SecureField("Confirm wallet key", text: $passwordConfirm)
                    .textFieldStyle(.roundedBorder)
                if !passwordConfirm.isEmpty && !passwordsMatch {
                    Text("Passwords do not match.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                }
            }

            if let err = generationError {
                Text(err)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }

            HStack {
                Button("Cancel", action: onClose)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button("Generate") { onGenerateTap() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(!canProceed)
            }
        }
        .onChange(of: email) { _, _ in
            // Editing the email invalidates any prior dev passcode
            // authorisation — the user has to re-enter the passcode
            // for the new address.
            devAuthorized = false
        }
    }

    // MARK: dev passcode (inline step — NOT a nested sheet; see the
    // devPasscodeEntered doc comment for the Settings-window bug)

    private var devAuthStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("DEV PASSCODE")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text("Creating a developer (test) wallet requires the dev passcode. Developer wallets use the @axiom.internal class — they can only transact with other developer wallets and claim from the 1M dev-AXC pool (isolated from public production AXC). See AXIOM_DESIGN_FactClassIsolation.md.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Passcode", text: $devPasscodeEntered)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitDevPasscode)
            if devPasscodeError {
                Text("Wrong passcode.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Back") {
                    devPasscodeEntered = ""
                    devPasscodeError = false
                    step = .form
                }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button("OK") { submitDevPasscode() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func submitDevPasscode() {
        if devPasscodeEntered == kAddPairDevPasscode {
            devPasscodeEntered = ""
            devPasscodeError = false
            devAuthorized = true
            startGeneration()
        } else {
            devPasscodeError = true
        }
    }

    private var emailSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            fieldLabel("EMAIL")
            TextField("you@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            // If the typed email matches an existing pair, show a
            // friendly caution. Sharing an email across pairs is
            // permitted by the protocol (per-pair salt + per-pair
            // wallet_id keep the two identities cryptographically
            // independent), but it's worth flagging so the user
            // knows what they're doing.
            if let collision = collidingPairName {
                sameEmailCaution(otherPair: collision)
            }

            // Class is inferred from the email's domain — show an
            // explicit notice when the user has typed an
            // @axiom.internal address (the dev-class indicator),
            // and gate Generate behind the dev passcode.
            if isDevEmail {
                devEmailNotice
            }
        }
    }

    /// Caution shown when the typed email matches another loaded
    /// pair's email. Yellow / informational — not blocking. Explains
    /// that AXIOM wallets get a distinct wallet_id per pair regardless
    /// of shared email contact.
    @ViewBuilder
    private func sameEmailCaution(otherPair: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(DesignTokens.statusScarredFg)
                .font(DesignTokens.Typography.label)
            VStack(alignment: .leading, spacing: 2) {
                Text("This email is already used by wallet set '\(otherPair)'.")
                    .font(DesignTokens.Typography.labelStrong)
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Text("This new wallet set will be completely separate — different keys, different wallet_id (per-set salt and hex), different balance, different transaction history. Sharing the email is just a contact label; the two wallet sets cannot see each other's funds.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs,
                            leading: DesignTokens.Spacing.xs,
                            bottom: DesignTokens.Spacing.xs,
                            trailing: DesignTokens.Spacing.xs))
        .background(DesignTokens.statusScarredBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    /// In-line notice that appears beneath the email field when
    /// the typed domain is `@axiom.internal`. Surfaces (a) the
    /// fact that this will be a dev wallet, (b) the consensus
    /// rule R1 consequences, and — in release builds — (c) that
    /// dev wallets are not creatable from this build.
    @ViewBuilder
    private var devEmailNotice: some View {
        if devBlockedInReleaseBuild {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                    .font(DesignTokens.Typography.label)
                Text("Developer wallets (`@axiom.internal`) cannot be created from this release build. To set up a dev wallet, use a dev / demo build of AxiomWallet.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs,
                                leading: DesignTokens.Spacing.xs,
                                bottom: DesignTokens.Spacing.xs,
                                trailing: DesignTokens.Spacing.xs))
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
                            .font(DesignTokens.Typography.labelStrong)
                            .foregroundStyle(DesignTokens.statusScarredFg)
                        if devAuthorized {
                            Text("✓ dev passcode entered")
                                .font(DesignTokens.Typography.micro)
                                .foregroundStyle(DesignTokens.statusCleanFg)
                        } else {
                            Text("· dev passcode required at Generate")
                                .font(DesignTokens.Typography.micro)
                                .foregroundStyle(DesignTokens.textTertiary)
                        }
                    }
                    Text("@axiom.internal class — dev-AXC sandbox, isolated from public production AXC. The SDK routes the claim to the 1M dev pool automatically (AXIOM_DESIGN_FactClassIsolation.md).")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs,
                                leading: DesignTokens.Spacing.xs,
                                bottom: DesignTokens.Spacing.xs,
                                trailing: DesignTokens.Spacing.xs))
            .background(DesignTokens.statusScarredBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        }
    }

    // MARK: generating

    private var generatingStep: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
                .controlSize(.large)
            Text("Generating Normal + Ark wallets…")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    /// Handler for the Generate button. If the email is an
    /// `@axiom.internal` address and the user hasn't yet entered
    /// the dev passcode for it, switches to the inline `.devAuth`
    /// step and waits — `startGeneration()` runs once the passcode
    /// is correct. For non-dev emails (or already-authorised dev
    /// ones), proceeds straight to generation.
    private func onGenerateTap() {
        if needsDevAuth {
            devPasscodeEntered = ""
            devPasscodeError = false
            step = .devAuth
            return
        }
        startGeneration()
    }

    private func startGeneration() {
        generationError = nil
        step = .generating
        Task { @MainActor in
            do {
                let pair = try createWalletPairVaulted(
                    pairName: pairName,
                    email: effectiveEmail,
                    walletKey: password,
                    parentDir: defaultWalletDir()
                )
                let result = CreatedResult(
                    normal: pair.normal,
                    ark: pair.ark,
                    normalSecretHex: pair.normal.walletSecretHex(),
                    arkSecretHex: pair.ark.walletSecretHex()
                )
                generated = result
                step = .backup

                // Auto-provision Kiddo for the Normal wallet (mirrors
                // OnboardingView.maybeAutoProvision). Without this, a
                // user creating their SECOND, THIRD, … wallet has no
                // Kiddo account for it — the SDK writes UMP to the
                // wallet's outbox, but no worker watches the dir, so
                // sends silently stall in outbox/new. Skipped for
                // non-dev emails (real SMTP/POP3 needs a password
                // Kiddo can't know — manual Settings only). Ark wallets
                // are excluded by design — k=0, offline transfer mode,
                // no carrier traffic. Provision is idempotent on the
                // Kiddo side, so re-firing on a name collision is safe.
                if isDevEmail {
                    let walletDir = defaultWalletDir() + "/" + pairName + "-normal"
                    KiddoPreflight.provisionKiddo(
                        walletEmail: effectiveEmail,
                        walletDir: walletDir,
                        label: pairName
                    )
                }
            } catch {
                generationError = "Couldn't create wallet set: \(error.localizedDescription)"
                step = .form
            }
        }
    }

    // MARK: backup

    private var backupStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Back up your wallet secrets")
                .font(DesignTokens.Typography.heading)

            Text("Two secrets — one per wallet. Lose them and the money locked behind them is unrecoverable. Save them somewhere offline before continuing.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)

            ScrollView {
                VStack(spacing: DesignTokens.Spacing.xs) {
                    if let g = generated {
                        secretBlock(
                            title: "\(pairName) — Normal",
                            tag: "NORMAL",
                            tagColor: DesignTokens.brandPrimary,
                            tagBg: DesignTokens.brandPrimarySoft,
                            hex: g.normalSecretHex,
                            address: try? g.normal.address()
                        )
                        secretBlock(
                            title: "\(pairName) — Ark",
                            tag: "ARK",
                            tagColor: DesignTokens.textSecondary,
                            tagBg: DesignTokens.bgTertiary,
                            hex: g.arkSecretHex,
                            address: try? g.ark.address()
                        )
                    }
                }
            }
            .frame(maxHeight: 320)

            Toggle(isOn: $backupConfirmed) {
                Text("I have written down both secrets and stored them safely.")
                    .font(DesignTokens.Typography.label)
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Continue") { step = .done }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .disabled(!backupConfirmed)
            }
        }
    }

    @ViewBuilder
    private func secretBlock(
        title: String, tag: String, tagColor: Color, tagBg: Color,
        hex: String, address: String?
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
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            secretGrid(hex: hex)
        }
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private func secretGrid(hex: String) -> some View {
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
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text(byte)
                        .font(DesignTokens.Typography.monoSmall)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignTokens.Spacing.xxs)
                .background(DesignTokens.bgPrimary)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.chip))
            }
        }
    }

    // MARK: done

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Wallet set ready")
                .font(DesignTokens.Typography.heading)
            Text("\(pairName) — Normal + Ark — has been added. The tab strip will switch to it once you confirm.")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textSecondary)

            Spacer()

            HStack {
                Spacer()
                Button("Open \(pairName)") { handoff() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
            }
        }
        .frame(minHeight: 160)
    }

    private func handoff() {
        guard let g = generated else { onClose(); return }
        let new = LoadedPair(name: pairName, normal: g.normal, ark: g.ark)
        session.pairs.append(new)
        session.activePairIndex = session.pairs.count - 1
        session.activeMode = .normal
        onClose()
    }
}

// =================================================================
// Load-from-file sub-form
// =================================================================
private struct LoadFromFileForm: View {
    @ObservedObject var session: AppSession
    let onClose: () -> Void

    @State private var sourcePath: String? = nil
    @State private var pairName: String = ""
    @State private var modeIsArk: Bool = false
    @State private var importedWallet: AxiomWallet? = nil
    @State private var importError: String? = nil
    @State private var registerError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Pick a wallet.axiom exported from another device. The file becomes a single-mode wallet set on this Mac (you can generate the companion mode later from Wallets management).")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)

            sourcePicker

            if let imported = importedWallet {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    fieldLabel("FILE SUMMARY")
                    summaryRow("Address", value: (try? imported.address()) ?? "—", mono: true)
                    summaryRow("Email", value: imported.email())
                    summaryRow("Balance at last save", value: "\(formatBalance(imported.balance()))\n\(formatAxcOnly(imported.balance()))")
                    summaryRow("Detected mode", value: modeIsArk ? "Ark" : "Normal")
                }
                .padding(DesignTokens.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    fieldLabel("NAME THIS WALLET SET ON THIS MAC")
                    TextField("Treasury", text: $pairName)
                        .textFieldStyle(.roundedBorder)
                    Text("This appears on the tab strip.")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
            }

            if let err = importError ?? registerError {
                Text(err)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }

            warningBlock

            HStack {
                Button("Cancel", action: onClose)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button(actionLabel) { performAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(!canProceed)
            }
        }
    }

    private var actionLabel: String {
        importedWallet == nil ? "Load file" : "Register wallet set"
    }

    private var canProceed: Bool {
        if importedWallet == nil { return sourcePath != nil }
        return !pairName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var sourcePicker: some View {
        Button(action: pickFile) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                        .fill(DesignTokens.bgTertiary)
                        .frame(width: 36, height: 36)
                    Text("CBOR")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourcePath.map { ($0 as NSString).lastPathComponent } ?? "Choose wallet.axiom…")
                        .font(DesignTokens.Typography.labelStrong)
                    Text(sourcePath ?? "No file selected.")
                        .font(DesignTokens.Typography.monoSmall)
                        .foregroundStyle(DesignTokens.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(sourcePath == nil ? "Pick" : "Replace")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.brandPrimary)
            }
            .padding(DesignTokens.Spacing.sm)
            .background(DesignTokens.bgPrimary)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                    .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        }
        .buttonStyle(.plain)
    }

    private var warningBlock: some View {
        Text("⚠ The wallet key isn't in this file — it's the password set on the source device. Without it you can receive cheques but you can't sign sends from this wallet.")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.statusScarredFg)
            .lineSpacing(2)
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs,
                                leading: DesignTokens.Spacing.sm,
                                bottom: DesignTokens.Spacing.xs,
                                trailing: DesignTokens.Spacing.sm))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.statusScarredBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    private func summaryRow(_ label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
            Spacer()
            Text(value)
                .font(mono ? DesignTokens.Typography.monoSmall : DesignTokens.Typography.labelStrong)
                .multilineTextAlignment(.trailing)
                .lineLimit(mono ? 1 : nil)
                .truncationMode(.middle)
        }
        .padding(.vertical, 3)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a wallet.axiom file"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourcePath = url.path
        importedWallet = nil
        importError = nil
        registerError = nil
        // Reset pair name suggestion based on source filename, e.g.
        // "treasury-normal" → "Treasury".
        let base = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        let candidate = parent.replacingOccurrences(of: "-normal", with: "")
            .replacingOccurrences(of: "-ark", with: "")
            .replacingOccurrences(of: ".backup", with: "")
        pairName = candidate.isEmpty ? base.capitalized : candidate.capitalized
    }

    private func performAction() {
        importError = nil
        registerError = nil
        if importedWallet == nil {
            performImport()
        } else {
            performRegister()
        }
    }

    private func performImport() {
        guard let source = sourcePath else { return }
        let safeName = "\(pairName.lowercased())-import-\(Int(Date().timeIntervalSince1970))"
        do {
            let wallet = try AxiomWallet.fromFileVaulted(
                sourcePath: source,
                parentDir: defaultWalletDir(),
                walletName: safeName
            )
            // Detect mode from the imported wallet's address.
            // Ark uses k=0 (PROOF_TYPE_ARK).
            let addr = (try? wallet.address()) ?? ""
            let decoded = decodeAddress(address: addr)
            modeIsArk = decoded?.k == 0
            importedWallet = wallet
        } catch {
            importError = "Couldn't load the file: \(error.localizedDescription)"
        }
    }

    private func performRegister() {
        guard let wallet = importedWallet else { return }
        // Mac dev currently requires a Normal-mode wallet as the
        // pair's anchor — LoadedPair.normal is non-optional in the
        // session model. Ark-only pairs need either (a) a session
        // model change making normal optional or (b) a way to
        // generate a Normal companion from the imported Ark, neither
        // of which is in scope for this commit.
        if modeIsArk {
            registerError = "Importing an Ark-only wallet isn't supported yet — Mac requires a Normal-mode wallet as the wallet set's anchor. Workaround: export both modes from the source device and import the Normal one first (the Ark-companion-from-existing-set flow lands in a follow-up)."
            return
        }
        let walletName = wallet.name()
        do {
            try addWalletPairRegistration(
                parentDir: defaultWalletDir(),
                pairName: pairName,
                normalWalletName: walletName,
                arkWalletName: nil
            )
            let new = LoadedPair(name: pairName, normal: wallet, ark: nil)
            session.pairs.append(new)
            session.activePairIndex = session.pairs.count - 1
            session.activeMode = .normal
            onClose()
        } catch {
            registerError = "Couldn't register wallet set: \(error.localizedDescription)"
        }
    }
}

// =================================================================
// Shared helpers
// =================================================================
private func fieldLabel(_ text: String) -> some View {
    Text(LocalizedStringKey(text))
        .font(DesignTokens.Typography.sectionLabel)
        .tracking(0.4)
        .foregroundStyle(DesignTokens.textTertiary)
}

/// Shared dev passcode — same literal AxiomKiddo's SettingsView
/// and the CarrierPreferences picker use for their dev gates.
/// Single passcode across all dev-toggle UX in the wallet.
/// (The passcode UI itself is the inline `.devAuth` step of
/// CreateNewPairForm — a nested `.sheet` presentation gets silently
/// dropped while the Settings window is open; see `devPasscodeEntered`.)
private let kAddPairDevPasscode = "fatmama approve axiom"
