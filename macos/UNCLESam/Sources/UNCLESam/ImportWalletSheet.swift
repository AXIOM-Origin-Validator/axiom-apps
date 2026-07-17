import SwiftUI

// =================================================================
// ImportWalletSheet — adopt an existing AxiomWallet as an
// UNCLE SAM institutional account.
//
// AXIOM Origin's 2026-05-31 architectural simplification: rather than
// engineering a bridge between UNCLE SAM's bilateral peer wire
// and the standard ANTIE/skip-list flow used by retail wallets,
// just let UNCLE SAM IMPORT an existing AxiomWallet. The wallet
// keeps receiving cheques via its standard ANTIE/email path;
// UNCLE SAM is the banker-friendly UI on top.
//
// Flow:
//   1. Operator clicks "Import existing wallet" in
//      Settings → Institution accounts.
//   2. NSOpenPanel — pick the wallet's directory (the one
//      containing wallet.axiom).
//   3. Operator fills display name + purpose + sub-BIC + color
//      same as creating a fresh account.
//   4. Checkbox: "Rename original to prevent double-use" (default
//      ON). Renames the source directory to
//      `<source>.imported-to-UNCLESam-YYYY-MM-DD` after a
//      successful copy + adopt — AxiomWallet won't find it on
//      next launch, the operator can't accidentally have two
//      processes flocking the same wallet.
//   5. importAccount copies the wallet, opens it via the SDK,
//      registers as InstitutionAccount.
// =================================================================

struct ImportWalletSheet: View {
    @EnvironmentObject private var session: InstitutionSession
    let onDone: () -> Void

    @State private var sourceDir: String = ""
    @State private var displayName: String = ""
    @State private var purpose: AccountPurpose = .treasury
    @State private var subBIC: String = ""
    @State private var color: AccountColor = .navy
    @State private var renameOriginal: Bool = true

    @State private var submitting: Bool = false
    @State private var submitError: String? = nil
    @State private var submitWarning: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            sourcePicker
            purposePicker
            field("Display name",
                  placeholder: "e.g. HK Branch · FX Desk · Customer Pool A",
                  text: $displayName)
            field("Sub-BIC (optional)",
                  placeholder: "e.g. DEMOBKHKBRA",
                  text: $subBIC, mono: true)
            colorPicker
            Toggle(isOn: $renameOriginal) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename original directory after import")
                        .font(.system(size: 11, weight: .medium))
                    Text("Adds `.imported-to-UNCLESam-YYYY-MM-DD` to the source folder name so AxiomWallet won't accidentally open the same wallet at the same time as UNCLE SAM. Recommended.")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            Text("UNCLE SAM copies the wallet's files into its own data directory. The wallet keeps receiving cheques via its standard email/ANTIE path; UNCLE SAM is the banker-friendly UI on top.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let err = submitError {
                errorBanner(err, color: DesignTokens.statusRejectedFg,
                            bg: DesignTokens.statusRejectedBg,
                            icon: "xmark.shield.fill")
            }
            if let warning = submitWarning {
                errorBanner(warning,
                            color: DesignTokens.statusPendingFg,
                            bg: DesignTokens.statusPendingBg,
                            icon: "exclamationmark.triangle.fill")
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onDone)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button {
                    submit()
                } label: {
                    HStack(spacing: 6) {
                        if submitting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "square.and.arrow.down.fill") }
                        Text(submitting ? "Importing…" : "Import wallet")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandNavy)
                .disabled(!isReady || submitting)
            }
        }
        .padding(22)
        .frame(width: 580)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 18))
                .foregroundStyle(DesignTokens.brandGold)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import existing wallet")
                    .font(.system(size: 16, weight: .semibold))
                Text("Adopt an AxiomWallet as an UNCLE SAM institutional account")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Wallet folder")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignTokens.textTertiary)
            HStack(spacing: 6) {
                TextField("/path/to/wallet (the folder containing wallet.axiom)",
                          text: $sourceDir)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.monoSmallFont)
                Button("Browse…") {
                    pickSource()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if !sourceDir.isEmpty {
                sourceValidityRow
            } else {
                Text("The wallet is the FOLDER under `~/Library/Application Support/Axiom/wallets/` — its name is the wallet identifier (e.g. `HQ-treasury`). wallet.axiom is just one file inside it; UNCLE SAM copies the whole folder.")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var sourceValidityRow: some View {
        let containsWalletCbor = FileManager.default.fileExists(
            atPath: "\(sourceDir)/wallet.axiom")
        HStack(spacing: 6) {
            Image(systemName: containsWalletCbor
                  ? "checkmark.circle.fill"
                  : "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(containsWalletCbor
                                 ? DesignTokens.statusSettledFg
                                 : DesignTokens.statusRejectedFg)
            Text(containsWalletCbor
                 ? "Valid: wallet.axiom found"
                 : "No wallet.axiom in this directory")
                .font(.system(size: 10))
                .foregroundStyle(containsWalletCbor
                                 ? DesignTokens.statusSettledFg
                                 : DesignTokens.statusRejectedFg)
        }
    }

    private var purposePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Account purpose")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignTokens.textTertiary)
            Picker("", selection: $purpose) {
                ForEach(AccountPurpose.allCases) { p in
                    HStack(spacing: 6) {
                        Image(systemName: p.icon)
                        Text(p.label)
                    }
                    .tag(p)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Chrome accent colour")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignTokens.textTertiary)
            HStack(spacing: 6) {
                ForEach(AccountColor.allCases) { c in
                    Button { color = c } label: {
                        Circle()
                            .fill(c.color)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle().strokeBorder(
                                    color == c
                                        ? DesignTokens.brandGold
                                        : DesignTokens.borderPrimary,
                                    lineWidth: color == c ? 2 : 1)
                            )
                            .help(c.label)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func field(_ label: String,
                        placeholder: String,
                        text: Binding<String>,
                        mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignTokens.textTertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? DesignTokens.monoSmallFont : .system(size: 13))
        }
    }

    private func errorBanner(_ msg: String,
                              color: Color, bg: Color,
                              icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(msg)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var isReady: Bool {
        !sourceDir.isEmpty &&
            !displayName.isEmpty &&
            FileManager.default.fileExists(
                atPath: "\(sourceDir)/wallet.axiom")
    }

    private func pickSource() {
        let panel = NSOpenPanel()
        // Folder-only. A wallet IS a directory (wallet.axiom +
        // wallet.axiom.lock + siblings), so picking the folder is
        // the honest model. wallet.axiom stays grey in the picker
        // as a signal that "the wallet is the bundle, not the
        // single file".
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose wallet to import"
        panel.message = "Pick the wallet's FOLDER — the directory under `~/Library/Application Support/Axiom/wallets/`. Single-click the folder, then choose Import."
        panel.prompt = "Import this wallet"
        // macOS hides ~/Library by default. AxiomWallet's wallets
        // live under ~/Library/Application Support/Axiom/wallets, so
        // we MUST show hidden + pre-navigate operators close to it.
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        // Pre-navigate to the canonical AxiomWallet wallets dir if
        // it exists; otherwise to ~/Library/Application Support; else
        // home. Saves the operator three clicks down a hidden path.
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/Axiom/wallets"),
            home.appendingPathComponent("Library/Application Support/Axiom"),
            home.appendingPathComponent("Library/Application Support"),
            home,
        ]
        for url in candidates {
            if fm.fileExists(atPath: url.path) {
                panel.directoryURL = url
                break
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var picked = url.path
        // If they picked the parent wallets/ dir by mistake but
        // there's exactly one child with a wallet.axiom, descend.
        if !fm.fileExists(atPath: "\(picked)/wallet.axiom"),
           let children = try? fm.contentsOfDirectory(atPath: picked) {
            let walletChildren = children.filter {
                fm.fileExists(atPath: "\(picked)/\($0)/wallet.axiom")
            }
            if walletChildren.count == 1 {
                picked = "\(picked)/\(walletChildren[0])"
            }
        }
        sourceDir = picked
    }

    private func submit() {
        submitting = true
        submitError = nil
        submitWarning = nil
        let result = session.importAccount(
            appDir: uncleAppDir(),
            sourceDir: sourceDir,
            displayName: displayName,
            purpose: purpose,
            subBIC: subBIC,
            color: color,
            renameOriginal: renameOriginal)
        submitting = false
        if let result = result {
            // A non-nil return is either a hard error (no
            // account added) or a soft warning (account added,
            // rename failed). Detect by checking whether the
            // account count grew.
            if session.accounts.contains(where: {
                $0.config.displayName == displayName
            }) {
                submitWarning = result
                // Auto-close after a moment so the operator sees
                // the warning but isn't blocked.
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + 3.0) { onDone() }
            } else {
                submitError = result
            }
            return
        }
        onDone()
    }
}
