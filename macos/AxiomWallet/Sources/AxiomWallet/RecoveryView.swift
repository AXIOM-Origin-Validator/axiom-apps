import SwiftUI
import AppKit
import AxiomSdk

// =================================================================
// RecoveryView — "Forgot app password?" sheet.
//
// Three recovery paths, picked from a single sheet:
//
//   (1) Reset password with wallet_secret backup
//       Functional. Requires the user has the 32-byte wallet_secret
//       they wrote down during onboarding Step 4. Pastes the secret
//       hex, sets a new password, the SDK rotates auth_hash on the
//       matching wallet (each pair member has its own secret, so the
//       user does this once per member they want to recover).
//
//   (2) Restore from another device's backup file
//       Pending — opens AddPair-style NSOpenPanel + import flow.
//       The imported wallet's auth_hash already matches its source's
//       wallet_key, so this is "swap the local wallet for one whose
//       password you know" rather than a key rotation.
//
//   (3) Start fresh
//       Destructive. Wipes all wallets + pairs.json + contacts and
//       returns to onboarding. Confirmation gate.
//
// Per the integration rule: every action goes through the FFI
// (verify_wallet_secret_hex, reset_wallet_key_with_secret). No
// network involvement — recovery is local-only.
// =================================================================

struct RecoveryView: View {
    let onClose: () -> Void
    let onRecovered: () -> Void  // login screen reloads after success

    @State private var phase: Phase = .menu

    enum Phase {
        case menu
        case resetWithSecret
        case startFresh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch phase {
                    case .menu:             menuContent
                    case .resetWithSecret:  ResetWithSecretView(onClose: onClose, onRecovered: onRecovered)
                    case .startFresh:       StartFreshView(onClose: onClose, onRecovered: onRecovered)
                    }
                }
                .padding(EdgeInsets(top: DesignTokens.Spacing.md, leading: DesignTokens.Spacing.lg, bottom: DesignTokens.Spacing.lg, trailing: DesignTokens.Spacing.lg))
            }
        }
        // Height grew with the StartFreshView tickbox list (2026-05-26).
        // Content is in a ScrollView so the user can still scroll if
        // something else gets added; the larger default just means
        // the common case fits without scrolling.
        .frame(width: 540, height: 700)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("RECOVER ACCESS")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(headerTitle)
                    .font(DesignTokens.Typography.heading)
            }
            Spacer()
            if phase != .menu {
                Button("Back") { phase = .menu }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, DesignTokens.Spacing.xxs)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.md, leading: DesignTokens.Spacing.lg, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.lg))
    }

    private var headerTitle: String {
        switch phase {
        case .menu:            return "Forgot app password?"
        case .resetWithSecret: return "Reset password with backup"
        case .startFresh:      return "Erase all wallets and start fresh"
        }
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Three options. The first preserves your wallets and history if you have your Wallet Secret backup from onboarding; the other two are last resorts.")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .padding(.bottom, DesignTokens.Spacing.xxs)

            OptionCard(
                title: "Reset password using Wallet Secret backup",
                subtitle: "You wrote down two Wallet Secret backups during onboarding — one per mode. Pick the wallet set, paste both backups, set a new password. The wallet set's wallets, balances, and history are preserved.",
                kind: .available,
                action: { phase = .resetWithSecret }
            )

            OptionCard(
                title: "Restore from another device's backup file",
                subtitle: "If you exported a wallet.axiom file from another Mac (Wallets view → Export) you can import it here. The file already carries an auth_hash for whatever password it was encrypted under — you just need that password.",
                kind: .pending(reason: "NSOpenPanel + Wallet.fromFile flow lands in a follow-up. For now, use the '+' tab on the main app's pair strip after logging in to import a wallet."),
                action: {}
            )

            OptionCard(
                title: "Start fresh — erase all local wallets",
                subtitle: "Removes ALL wallet sets, contacts, and wallet-set registrations from this Mac. You'll need to re-onboard. Wallets cannot be recovered without their wallet_secret backups.",
                kind: .destructive,
                action: { phase = .startFresh }
            )
        }
    }

    private enum OptionKind {
        case available
        case pending(reason: String)
        case destructive

        var isInteractable: Bool {
            switch self {
            case .available, .destructive: return true
            case .pending:                  return false
            }
        }
    }

    /// Clickable option row. Hover feedback is visual-only — a
    /// subtle bgTertiary fill animated via Motion.quick() (collapses
    /// to no animation under Reduce Motion).
    private struct OptionCard: View {
        let title: String
        let subtitle: String
        let kind: OptionKind
        let action: () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: kind.isInteractable ? action : {}) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        HStack(spacing: DesignTokens.Spacing.xxs) {
                            Text(title)
                                .font(DesignTokens.Typography.bodyStrong)
                                .foregroundStyle(DesignTokens.textPrimary)
                            kindPill
                        }
                        Text(subtitle)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.textSecondary)
                            .lineSpacing(2)
                            .multilineTextAlignment(.leading)
                        if case .pending(let reason) = kind {
                            Text(reason)
                                .font(DesignTokens.Typography.micro)
                                .foregroundStyle(DesignTokens.textTertiary)
                                .lineSpacing(2)
                                .multilineTextAlignment(.leading)
                                .padding(.top, 2)
                        }
                    }
                    Spacer()
                    if kind.isInteractable {
                        Image(systemName: "chevron.right")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                }
                .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.md, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.md))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isHovering ? DesignTokens.bgTertiary : DesignTokens.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
                .opacity(kind.isInteractable ? 1.0 : 0.65)
            }
            .buttonStyle(.plain)
            .disabled(!kind.isInteractable)
            .onHover { hovering in
                withAnimation(DesignTokens.Motion.quick()) {
                    isHovering = hovering && kind.isInteractable
                }
            }
        }

        @ViewBuilder
        private var kindPill: some View {
            switch kind {
            case .available:
                EmptyView()
            case .pending:
                Text("PENDING")
                    .font(DesignTokens.Typography.chip)
                    .tracking(0.3)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .padding(.horizontal, DesignTokens.Spacing.xxs).padding(.vertical, 1)
                    .background(DesignTokens.bgTertiary)
                    .clipShape(Capsule())
            case .destructive:
                Text("DESTRUCTIVE")
                    .font(DesignTokens.Typography.chip)
                    .tracking(0.3)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                    .padding(.horizontal, DesignTokens.Spacing.xxs).padding(.vertical, 1)
                    .background(DesignTokens.statusRejectedBg)
                    .clipShape(Capsule())
            }
        }
    }
}


// =================================================================
// Phase 1 — Reset password using Wallet Secret backup (pair-level)
//
// One option per pair. Each pair has Normal + Ark mode wallets,
// each with its own 32-byte Wallet Secret backup written down at
// onboarding. Both backups are required — proving ownership of
// both members is what authorises rotating the shared password
// and recomputing both wallets' auth_hashes.
// =================================================================
private struct ResetWithSecretView: View {
    let onClose: () -> Void
    let onRecovered: () -> Void

    @State private var walletDir: String = defaultWalletDir()
    @State private var pairs: [PairChoice] = []
    @State private var selectedPairName: String = ""
    @State private var normalSecretHex: String = ""
    @State private var arkSecretHex: String = ""
    @State private var newPassword: String = ""
    @State private var newPasswordConfirm: String = ""
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil
    @State private var isWorking: Bool = false

    private struct PairChoice {
        let name: String
        let normalDir: String
        let arkDir: String?  // nil = partial pair (Ark companion missing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Pick the wallet set you want to recover and paste both Wallet Secret backups (one per mode). The same new password will protect both wallets in the set.")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)

            pairPicker

            backupField(
                label: "NORMAL MODE — WALLET SECRET BACKUP",
                hint: "32-byte hex from your onboarding paper backup. Spaces and line breaks are tolerated — paste it as it appears.",
                text: $normalSecretHex
            )

            if currentPairHasArk {
                backupField(
                    label: "ARK MODE — WALLET SECRET BACKUP",
                    hint: "Second 32-byte hex from the same onboarding backup paper.",
                    text: $arkSecretHex
                )
            } else if !selectedPairName.isEmpty {
                Text("This wallet set has no Ark companion on disk — only the Normal mode backup is required.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                fieldLabel("NEW PASSWORD")
                SecureField("8 characters minimum", text: $newPassword)
                    .textFieldStyle(.roundedBorder)
                SecureField("Re-enter to confirm", text: $newPasswordConfirm)
                    .textFieldStyle(.roundedBorder)
                if !newPasswordConfirm.isEmpty && newPassword != newPasswordConfirm {
                    Text("Passwords don't match.")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                }
            }

            if let err = errorMessage {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.xxs) {
                    Image(systemName: "xmark.octagon")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                    Text(err)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                }
            }
            if let msg = successMessage {
                Text(msg)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusCleanFg)
            }

            HStack {
                Spacer()
                Button("Reset password") { performReset() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .disabled(!canSubmit || isWorking)
            }
        }
        .onAppear { discoverPairs() }
    }

    @ViewBuilder
    private func backupField(label: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            fieldLabel(label)
            TextEditor(text: text)
                .font(DesignTokens.Typography.monoSmall)
                .frame(minHeight: 60, maxHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(DesignTokens.Spacing.xs)
                .background(DesignTokens.bgPrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                        .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
                .autocorrectionDisabled()
            Text(LocalizedStringKey(hint))
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
        }
    }

    private var pairPicker: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            fieldLabel("WALLET SET TO RESET")
            if pairs.isEmpty {
                Text("No wallet sets found in \(walletDir).")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            } else {
                Picker("", selection: $selectedPairName) {
                    ForEach(pairs, id: \.name) { pair in
                        Text(pair.name).tag(pair.name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var currentPair: PairChoice? {
        pairs.first { $0.name == selectedPairName }
    }

    private var currentPairHasArk: Bool {
        currentPair?.arkDir != nil
    }

    private var canSubmit: Bool {
        guard let pair = currentPair else { return false }
        let normalReady = !normalSecretHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let arkReady = pair.arkDir == nil
            ? true
            : !arkSecretHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return normalReady
            && arkReady
            && newPassword.count >= 8
            && newPassword == newPasswordConfirm
    }

    private func discoverPairs() {
        // Prefer pairs.json (the canonical pair registry). Fall back
        // to "any wallet directory ending in -normal pairs with a
        // sibling -ark" inference when the registry is missing.
        let registered = (try? listWalletPairs(parentDir: walletDir)) ?? []
        if !registered.isEmpty {
            pairs = registered.compactMap { view in
                guard let normalName = view.normalWalletName else { return nil }
                let normalDir = "\(walletDir)/\(normalName)"
                let arkDir = view.arkWalletName.map { "\(walletDir)/\($0)" }
                return PairChoice(name: view.name, normalDir: normalDir, arkDir: arkDir)
            }
        } else {
            pairs = inferPairsFromDirs()
        }
        if selectedPairName.isEmpty, let first = pairs.first {
            selectedPairName = first.name
        }
    }

    private func inferPairsFromDirs() -> [PairChoice] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: walletDir) else { return [] }
        var result: [PairChoice] = []
        for name in entries.sorted() where name.hasSuffix("-normal") {
            let pairName = String(name.dropLast("-normal".count))
            let normalDir = "\(walletDir)/\(name)"
            let arkCandidate = "\(walletDir)/\(pairName)-ark"
            let arkDir = fm.fileExists(atPath: "\(arkCandidate)/wallet.axiom") ? arkCandidate : nil
            result.append(PairChoice(name: pairName, normalDir: normalDir, arkDir: arkDir))
        }
        return result
    }

    private func performReset() {
        errorMessage = nil
        successMessage = nil
        guard let pair = currentPair else {
            errorMessage = "No wallet set selected."
            return
        }
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do {
                // Reset Normal first. If that succeeds and Ark exists,
                // reset Ark with its own backup. Both share the new
                // password the user just typed.
                let normal = try AxiomWallet.openVaulted(dir: pair.normalDir)
                try normal.resetWalletKeyWithSecret(
                    walletSecretHex: normalSecretHex,
                    newWalletKey: newPassword
                )

                if let arkDir = pair.arkDir {
                    let ark = try AxiomWallet.openVaulted(dir: arkDir)
                    try ark.resetWalletKeyWithSecret(
                        walletSecretHex: arkSecretHex,
                        newWalletKey: newPassword
                    )
                }

                // Proving the wallet_secret is the strongest possible
                // authorisation — reset the app password to the new
                // wallet key so login works again. Recovery is the
                // "I forgot my password" path, and we can't know
                // whether the user previously set a SEPARATE app
                // password or shared one (the verifier is one-way
                // hashed). Either way, after recovery they start fresh
                // with a single string and can re-diverge in
                // Settings → Security if they want the shoulder-surf
                // defense back. (Default onboarding since 2026-05-27
                // sets these to DIFFERENT values; see
                // AppSecurity.swift.)
                AppPassword.set(newPassword)

                let what = pair.arkDir == nil ? "Normal mode wallet" : "Normal + Ark wallets"
                successMessage = "Password reset for \(pair.name). \(what) + app password updated. Type your new password to log in. (If you'd like a different app password, change it in Settings → Security after logging in.)"
                normalSecretHex = ""
                arkSecretHex = ""
                newPassword = ""
                newPasswordConfirm = ""
                onRecovered()
            } catch {
                errorMessage = "Couldn't reset: \(error.localizedDescription)"
            }
        }
    }
}

// =================================================================
// Phase 2 — Start fresh (destructive, à la carte)
// =================================================================
//
// The previous "ERASE EVERYTHING" page wiped the entire Application
// Support/Axiom folder + the Preferences plist as a single hammer.
// Per user feedback the right shape is a tickbox list: default
// everything ticked (preserves the old all-in-one behavior), let
// the user untick categories they want to preserve (most commonly
// contacts; sometimes app preferences so the user keeps their
// login + biometric setup).
//
// Categories below are coarse on purpose — finer granularity ("keep
// my Personal pair but erase the Treasury pair") is a different
// surface (Wallets → delete pair). This sheet is for the all-or-
// almost-all reset.
// =================================================================
private struct StartFreshView: View {
    let onClose: () -> Void
    let onRecovered: () -> Void

    @State private var typedConfirm: String = ""
    @State private var errorMessage: String? = nil
    @State private var isWorking: Bool = false

    // Each category defaults to TRUE (= the old "erase everything"
    // behavior). Untick to preserve.
    @State private var eraseWallets: Bool = true
    @State private var eraseContacts: Bool = true
    @State private var erasePreferences: Bool = true
    @State private var eraseNetworkState: Bool = true

    private let confirmPhrase = "ERASE EVERYTHING"

    /// True iff at least one category is ticked. Disables the
    /// destructive button when nothing's selected — there's nothing
    /// to erase, so the user should just Cancel instead.
    private var hasSomethingToErase: Bool {
        eraseWallets || eraseContacts || erasePreferences || eraseNetworkState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            warningCard
            categoryList
            relaunchNote

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                fieldLabel("TYPE \(confirmPhrase) TO CONFIRM")
                TextField(confirmPhrase, text: $typedConfirm)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            if let err = errorMessage {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.xxs) {
                    Image(systemName: "xmark.octagon")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                    Text(err)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                }
            }

            HStack {
                Spacer()
                Button(eraseButtonLabel, role: .destructive) { performWipe() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.statusRejectedFg)
                    .controlSize(.large)
                    .disabled(typedConfirm != confirmPhrase
                              || isWorking
                              || !hasSomethingToErase)
            }
        }
    }

    private var eraseButtonLabel: String {
        if !hasSomethingToErase { return "Nothing to erase" }
        if eraseWallets && eraseContacts && erasePreferences && eraseNetworkState {
            return "Erase everything"
        }
        return "Erase selected"
    }

    /// Red warning card at the top — same visual weight as before.
    /// Copy updated to reflect the à-la-carte model.
    @ViewBuilder
    private var warningCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("⚠ This is irreversible.")
                .font(DesignTokens.Typography.bodyStrong)
                .foregroundStyle(DesignTokens.statusRejectedFg)
            Text("Choose what to erase below. Anything ticked is wiped from this Mac when you confirm. Wallets are NOT recoverable without the wallet_secret backups you wrote down during onboarding — if you erase them and don't have those backups, balances locked behind the auth_hash become unspendable forever.")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusRejectedBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    @ViewBuilder
    private var categoryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            categoryRow(
                title: "Wallets, balances, cheques",
                detail: "wallets/ folder under Application Support — every wallet pair's signing material, FACT chains, scarred-link state, and pending cheque bundles. The unrecoverable-without-backup tier.",
                isOn: $eraseWallets,
                accent: DesignTokens.statusRejectedFg
            )
            Divider().opacity(0.3)
            categoryRow(
                title: "Contacts",
                detail: "contacts.json — local address book. Pure convenience metadata; no protocol material, no keys. Safe to keep.",
                isOn: $eraseContacts,
                accent: DesignTokens.textSecondary
            )
            Divider().opacity(0.3)
            categoryRow(
                title: "App preferences",
                detail: "App password + biometric flag + idle-lock timeout + first-launch developer notice + validator pick counts + carrier preferences + version-skew state. Living in ~/Library/Preferences/<bundle>.plist.",
                isOn: $erasePreferences,
                accent: DesignTokens.textSecondary
            )
            Divider().opacity(0.3)
            categoryRow(
                title: "Network discovery cache",
                detail: "validators.list, nabla-nodes.list, axiom.conf, .seeds_version, maildir/. Refetched from axiom-dist on next launch; preserving them just saves the first-launch fetch.",
                isOn: $eraseNetworkState,
                accent: DesignTokens.textSecondary
            )
        }
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    @ViewBuilder
    private func categoryRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>,
        accent: Color
    ) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Toggle("", isOn: isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DesignTokens.Typography.labelStrong)
                    .foregroundStyle(accent)
                Text(detail)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
    }

    @ViewBuilder
    private var relaunchNote: some View {
        Text("After erasure the app relaunches. If you erased wallets, you'll land back on onboarding. If you preserved them, you'll land back on the login screen (or be auto-logged-in via biometric if you preserved app preferences).")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.textTertiary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func performWipe() {
        errorMessage = nil
        isWorking = true
        // Device-owner gate (Touch ID, falling back to macOS login
        // password). The Recovery sheet's whole reason to exist is
        // "I forgot the app password" — so we can't gate ERASE on
        // the app password. The Mac's device owner is the next-best
        // credential: a casual snoop at the unlocked screen typically
        // doesn't have the user's enrolled biometric, and the Mac
        // login password is at least separate from anything
        // AxiomWallet stores. Not perfect against an attacker who
        // also knows the Mac password, but raises the floor
        // meaningfully and matches the "owner consented" semantic
        // for an irreversible action. See AppSecurity.swift's
        // `authenticateForDestructiveAction` for why this is the
        // `.deviceOwnerAuthentication` policy and not the
        // biometric-only one we use at login.
        Task { @MainActor in
            let authorized = await Biometric.authenticateForDestructiveAction(
                reason: "confirm erasing AXIOM Wallet data"
            )
            guard authorized else {
                isWorking = false
                errorMessage = "Authentication cancelled — nothing was erased."
                return
            }
            performWipeAuthorized()
        }
    }

    private func performWipeAuthorized() {
        let fm = FileManager.default
        let base = "\(NSHomeDirectory())/Library/Application Support/Axiom"

        // Stop AxiomKiddo FIRST. Kiddo is a SEPARATE process that watches
        // every wallets/*/outbox/new and moves/creates files there (UMP
        // dispatch, .lock/tmp). If it's live during the recursive delete it
        // drops a file back into a directory removeItem just emptied, the
        // follow-up rmdir fails, and FileManager surfaces it as the
        // misleading "Axiom couldn't be removed because you don't have
        // permission" — even though the folder is yours and deletable. Quit
        // Kiddo and wait for it to actually exit so nothing touches the tree
        // mid-wipe. (The wallet's own SDK handles go with this process on
        // relaunch below.)
        terminateKiddoAndWait()

        do {
            // "Erase everything" must mean EVERYTHING. The three filesystem
            // categories together cover the entire Application Support/Axiom
            // folder, so when all three are ticked we remove the FOLDER ITSELF
            // — not a hardcoded list of known files.
            //
            // The old à-la-carte list (remove `wallets`, the `.list` files,
            // `axiom.conf`, `.seeds_version`, `maildir`, `cache`) silently
            // LEAKED anything not on it: stale artifacts from older app
            // versions, a leftover key/DEK envelope, `logs/`, any future
            // sidecar file. Those survived an "erase everything", and a
            // surviving key/seed/state file can resurrect a wallet the user
            // believes is gone — which is exactly why a true `rm -rf` of the
            // folder behaved differently from this dialog. A whitelist wipe is
            // always one app-version behind the files on disk; only
            // removeItem(base) actually matches `rm -rf`.
            if eraseWallets && eraseContacts && eraseNetworkState {
                try removeIfExists(base, fm: fm)
            } else {
                // À la carte: untick a category to preserve exactly that piece.
                // (Known files only — this path is a partial wipe by request.)
                if eraseWallets {
                    try removeIfExists("\(base)/wallets", fm: fm)
                }
                if eraseContacts {
                    try removeIfExists("\(base)/contacts.json", fm: fm)
                }
                if eraseNetworkState {
                    // Network discovery + transport state. SdkBootstrap
                    // recreates the lists on next launch via the SeedFetcher
                    // remote pull (axiom-dist).
                    try removeIfExists("\(base)/validators.list", fm: fm)
                    try removeIfExists("\(base)/nabla-nodes.list", fm: fm)
                    try removeIfExists("\(base)/axiom.conf", fm: fm)
                    try removeIfExists("\(base)/.seeds_version", fm: fm)
                    try removeIfExists("\(base)/maildir", fm: fm)
                    try removeIfExists("\(base)/cache", fm: fm)
                }
            }

            // Preferences plist lives outside Application Support, in
            // ~/Library/Preferences/<bundle>.plist. See the original
            // erase-plist-fix commit for why we need both
            // removePersistentDomain AND a physical `rm` here (cfprefsd
            // flushes asynchronously and exit(0) pre-empts the flush).
            if erasePreferences, let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
                let plistPath = "\(NSHomeDirectory())/Library/Preferences/\(bundleID).plist"
                try? fm.removeItem(atPath: plistPath)
                AppPassword.clear()  // defense-in-depth; no-op after removePersistentDomain
            }

            // Relaunch is still the right move whether we wiped
            // everything or just one category. The SDK's process-
            // global Runtime is held behind a OnceLock; selectively
            // wiping files underneath it leaves the in-memory caches
            // dangling. Fresh process is the safe reset.
            relaunchAxiomWallet()
        } catch {
            isWorking = false
            errorMessage = "Couldn't erase: \(error.localizedDescription)"
        }
    }

    /// `removeItem` that's a no-op when the path is missing. We
    /// don't want a "missing wallets/ folder" to abort the rest of
    /// the wipe (e.g., if the user already wiped once partially
    /// and is back to retry).
    private func removeIfExists(_ path: String, fm: FileManager) throws {
        if fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
    }

    /// Quit every running AxiomKiddo instance and block until they're
    /// actually gone, so Kiddo isn't racing the recursive delete (see
    /// the call site). Graceful `terminate()` first (lets Kiddo close
    /// its file handles cleanly), escalating to `forceTerminate()` if a
    /// stubborn instance outlives a short grace. Bounded (~2.5s) so a
    /// wedged Kiddo can never hang the wipe — worst case we proceed and
    /// the old, now-forced instance is gone anyway.
    private func terminateKiddoAndWait() {
        let bundleID = KiddoPreflight.bundleID   // "org.axiom.AxiomKiddo"
        func running() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        }
        guard !running().isEmpty else { return }
        for app in running() { app.terminate() }

        // Phase 1: up to 0.8s for a graceful exit.
        let graceEnd = Date().addingTimeInterval(0.8)
        while !running().isEmpty && Date() < graceEnd {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        // Phase 2: anything still alive gets force-killed; up to 1.7s more.
        if !running().isEmpty {
            for app in running() { app.forceTerminate() }
            let hardEnd = Date().addingTimeInterval(1.7)
            while !running().isEmpty && Date() < hardEnd {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
        }
    }
}

/// Spawn a new AxiomWallet process, then quit this one. The standard
/// macOS dance for in-app relaunch.
///
/// `/usr/bin/open -n <bundle>` is used (not `NSWorkspace.openApplication`)
/// because `-n` forces a NEW instance of the .app — without it macOS
/// sees we're already running and just fronts the dying process. The
/// helper task spawns asynchronously; we sleep briefly to let it cross
/// the launch boundary before terminating ourselves, otherwise the
/// "is there an instance already running?" check can race.
///
/// Falls back to `NSApp.terminate(nil)` (plain quit, user relaunches
/// manually) when:
///   - `Bundle.main.bundleURL` doesn't end in `.app` (e.g. running via
///     `swift run` against the bare binary — dev iteration).
///   - The `open` invocation fails to start (very unlikely on a
///     properly installed .app).
///
/// The user gets a faster recovery than "app closed unexpectedly" in
/// both cases — termination is the floor, relaunch is the win.
@MainActor
func relaunchAxiomWallet() {
    let url = Bundle.main.bundleURL
    guard url.pathExtension == "app" else {
        // swift-run / debug binary — no .app to relaunch into.
        // Quit cleanly; user relaunches via Xcode or swift run.
        NSApp.terminate(nil)
        return
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-n", url.path]
    do {
        try task.run()
    } catch {
        // open failed — fall back to plain terminate. User
        // sees a quit but no relaunch; better than getting
        // stuck in a half-wiped state.
        NSLog("relaunchAxiomWallet: open failed (\(error)) — terminating without relaunch")
        NSApp.terminate(nil)
        return
    }

    // Brief gap so the spawned `open` has time to cross the
    // launch-services boundary and register the new instance.
    // ~250ms is well above the launchd round-trip in observation
    // and well below "user notices a stall". Terminating earlier
    // can race: macOS sees the old PID quit before the new one
    // shows up and treats `open -n` as a fronting request that
    // does nothing.
    //
    // exit(0), not NSApp.terminate(nil): performWipe() is called
    // from inside a `.sheet` (StartFreshView presented by
    // LoginView's `.sheet(isPresented: $showRecovery)`). The
    // NSApp.terminate cascade walks windows asking each to close;
    // with a SwiftUI `.sheet` still attached to its parent — and
    // nothing flipping its `isPresented` binding — the cascade
    // stalls and the old process hangs on the Erase Everything
    // page while the new instance comes up alongside it. We've
    // already wiped Application Support + Keychain, so there's
    // no Cocoa state worth a graceful teardown anyway.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        exit(0)
    }
}

// =================================================================
// Local helpers
// =================================================================
private func fieldLabel(_ text: String) -> some View {
    Text(LocalizedStringKey(text))
        .font(DesignTokens.Typography.sectionLabel)
        .tracking(0.4)
        .foregroundStyle(DesignTokens.textTertiary)
}
