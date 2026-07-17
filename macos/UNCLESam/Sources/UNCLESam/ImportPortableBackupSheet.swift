import SwiftUI
import UniformTypeIdentifiers

// =================================================================
// ImportPortableBackupSheet — adopt a wallet from a password-
// encrypted AXPW portable backup (.axpw) as an UNCLE SAM
// institutional account.
//
// Why this exists alongside ImportWalletSheet:
//   ImportWalletSheet copies a plaintext wallet FOLDER and opens it
//   with AxiomWallet.open(). That path is BROKEN for a wallet whose
//   AxiomWallet sealed its on-disk keystore at rest (AXMK, under a
//   Keychain device key) — UNCLE SAM can't read that folder. The
//   sanctioned cross-app path is the password-encrypted `.axpw`
//   portable backup (AXPW): the source app exports its wallet to a
//   transit-safe AXPW, and here UNCLE SAM decrypts it back to the
//   canonical AXWL with the SAME wallet key and stores it PLAINTEXT
//   locally (UNCLE SAM stays plaintext-at-rest by design — no
//   Keychain vault, no Face ID).
//
// Flow:
//   1. Operator clicks "Import .axpw" in Settings → Institution
//      accounts.
//   2. NSOpenPanel restricted to `.axpw` files.
//   3. Operator supplies the wallet key + display name + purpose +
//      sub-BIC + colour (mirrors ImportWalletSheet / AddAccountSheet).
//   4. importPortableBackupAccount decrypts → stages plaintext AXWL
//      → SDK from_file (plaintext import) → registers the account.
// =================================================================

struct ImportPortableBackupSheet: View {
    @EnvironmentObject private var session: InstitutionSession
    let onDone: () -> Void

    @State private var axpwPath: String = ""
    @State private var walletKey: String = ""
    @State private var displayName: String = ""
    @State private var purpose: AccountPurpose = .treasury
    @State private var subBIC: String = ""
    @State private var color: AccountColor = .navy

    @State private var submitting: Bool = false
    @State private var submitError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            filePicker
            purposePicker
            field("Display name",
                  placeholder: "e.g. HK Branch · FX Desk · Customer Pool A",
                  text: $displayName)
            field("Sub-BIC (optional)",
                  placeholder: "e.g. DEMOBKHKBRA",
                  text: $subBIC, mono: true)
            field("Wallet key (the password the .axpw was exported with)",
                  placeholder: "wallet key",
                  text: $walletKey, mono: true, secure: true)
            colorPicker
            Text("UNCLE SAM decrypts the .axpw with this wallet key, then stores the wallet PLAINTEXT in its own data directory (UNCLE SAM is plaintext-at-rest by design). The .axpw is only the transit format — keep it private. Use the SAME wallet key that exported it.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let err = submitError {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.shield.fill")
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.statusRejectedBg)
                .clipShape(RoundedRectangle(cornerRadius: 4))
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
                        else { Image(systemName: "lock.open.doc.fill") }
                        Text(submitting ? "Importing…" : "Import backup")
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
            Image(systemName: "lock.doc")
                .font(.system(size: 18))
                .foregroundStyle(DesignTokens.brandGold)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from portable backup (.axpw)")
                    .font(.system(size: 16, weight: .semibold))
                Text("Bring a wallet across from AxiomWallet / the web wallet via the password-encrypted AXPW transit file")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var filePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Portable backup file")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignTokens.textTertiary)
            HStack(spacing: 6) {
                TextField("/path/to/backup.axpw", text: $axpwPath)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.monoSmallFont)
                Button("Browse…") {
                    pickFile()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if !axpwPath.isEmpty {
                let exists = FileManager.default.fileExists(atPath: axpwPath)
                HStack(spacing: 6) {
                    Image(systemName: exists
                          ? "checkmark.circle.fill"
                          : "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(exists
                                         ? DesignTokens.statusSettledFg
                                         : DesignTokens.statusRejectedFg)
                    Text(exists ? "File selected" : "File not found")
                        .font(.system(size: 10))
                        .foregroundStyle(exists
                                         ? DesignTokens.statusSettledFg
                                         : DesignTokens.statusRejectedFg)
                }
            }
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

    @ViewBuilder
    private func field(_ label: String,
                        placeholder: String,
                        text: Binding<String>,
                        mono: Bool = false,
                        secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignTokens.textTertiary)
            if secure {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(mono ? DesignTokens.monoSmallFont : .system(size: 13))
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(mono ? DesignTokens.monoSmallFont : .system(size: 13))
            }
        }
    }

    private var isReady: Bool {
        !axpwPath.isEmpty
            && !displayName.isEmpty
            && !walletKey.isEmpty
            && FileManager.default.fileExists(atPath: axpwPath)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose portable backup (.axpw)"
        panel.prompt = "Select"
        panel.showsHiddenFiles = true
        if let axpwType = UTType(filenameExtension: "axpw") {
            panel.allowedContentTypes = [axpwType]
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        for url in [home.appendingPathComponent("Downloads"), home] {
            if fm.fileExists(atPath: url.path) {
                panel.directoryURL = url
                break
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        axpwPath = url.path
    }

    private func submit() {
        submitting = true
        submitError = nil
        // Hop off the runloop so the spinner can paint before the
        // (potentially blocking) decrypt + from_file import.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            let err = session.importPortableBackupAccount(
                appDir: uncleAppDir(),
                axpwPath: axpwPath,
                walletKey: walletKey,
                displayName: displayName,
                purpose: purpose,
                subBIC: subBIC,
                color: color)
            submitting = false
            if let err {
                submitError = err
            } else {
                onDone()
            }
        }
    }
}
