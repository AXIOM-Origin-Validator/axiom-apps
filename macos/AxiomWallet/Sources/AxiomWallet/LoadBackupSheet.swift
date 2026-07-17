import SwiftUI
import AppKit
import AxiomSdk

// =================================================================
// LoadBackupSheet — pre-unlock wallet import from a backup .axw/.cbor.
//
// Reached from LoginView's "Load wallet from backup file" link. Lets
// the user bootstrap a wallet on a fresh Mac from a backup paper-
// less than the Recovery flow (which needs the wallet_secret backup
// itself) — this just needs the file the user exported from another
// device or restored from a paper QR.
//
// Once import succeeds, the sheet dismisses and LoginView routes
// through normal unlock — the user types the wallet_key they used
// on the source device.
//
// Per the integration rule: no network. Pure file copy through the
// SDK's `AxiomWallet.fromFile` FFI plus a `pairs.json` registration
// so the pair appears in the unlocked app.
// =================================================================

struct LoadBackupSheet: View {
    let onClose: () -> Void
    let onImported: () -> Void

    @State private var sourcePath: String? = nil
    @State private var pairName: String = ""
    @State private var importedWallet: AxiomWallet? = nil
    @State private var detectedEmail: String = ""
    @State private var detectedAddress: String = ""
    @State private var errorMessage: String? = nil
    @State private var isWorking: Bool = false

    private var canImport: Bool {
        sourcePath != nil
            && !pairName.trimmingCharacters(in: .whitespaces).isEmpty
            && !isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LOAD BACKUP")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Restore a wallet from a backup file")
                    .font(DesignTokens.Typography.heading)
            }

            descBox

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                fieldLabel("BACKUP FILE")
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Text(sourcePath.map { ($0 as NSString).lastPathComponent } ?? "Choose wallet.axw…")
                        .font(DesignTokens.Typography.mono)
                        .foregroundStyle(sourcePath == nil ? DesignTokens.textTertiary : DesignTokens.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { pickFile() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(EdgeInsets(top: DesignTokens.Spacing.xs,
                                    leading: DesignTokens.Spacing.sm,
                                    bottom: DesignTokens.Spacing.xs,
                                    trailing: DesignTokens.Spacing.sm))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.bgPrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                        .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                fieldLabel("WALLET SET NAME ON THIS MAC")
                TextField("e.g. Personal", text: $pairName)
                    .textFieldStyle(.roundedBorder)
                Text("Becomes the tab label and identifies this wallet on disk. Doesn't have to match the source device.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }

            if importedWallet != nil {
                importedSummary
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Cancel", action: onClose)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isWorking)
                    .frame(maxWidth: .infinity)
                Button(importedWallet == nil ? "Import" : "Confirm") {
                    perform()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandPrimary)
                .controlSize(.large)
                .disabled(!canImport)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 460)
    }

    // MARK: - Subviews

    private var descBox: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("If you exported a wallet.axw / wallet.axiom file from another device (or restored one from a paper backup) you can import it here. After import, you'll unlock with the wallet_key you set on the source device.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
            Text("If you've forgotten the password, cancel and use 'Forgot app password?' on the login screen with your wallet_secret backup paper instead.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .lineSpacing(2)
                .padding(.top, 2)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs,
                            leading: DesignTokens.Spacing.sm,
                            bottom: DesignTokens.Spacing.xs,
                            trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private var importedSummary: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("✓ File loaded")
                .font(DesignTokens.Typography.labelStrong)
                .foregroundStyle(DesignTokens.statusCleanFg)
            Text("Email: \(detectedEmail)")
                .font(DesignTokens.Typography.monoSmall)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Address: \(detectedAddress)")
                .font(DesignTokens.Typography.monoSmall)
                .foregroundStyle(DesignTokens.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Click Confirm to register this wallet set on this Mac. You'll then unlock with the original wallet_key.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .padding(.top, 2)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs,
                            leading: DesignTokens.Spacing.sm,
                            bottom: DesignTokens.Spacing.xs,
                            trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusCleanBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    // MARK: - Action

    private func perform() {
        errorMessage = nil
        if importedWallet == nil {
            performImport()
        } else {
            performRegister()
        }
    }

    private func performImport() {
        guard let source = sourcePath else { return }
        isWorking = true
        defer { isWorking = false }
        let trimmedName = pairName.trimmingCharacters(in: .whitespaces)
        // Disk name is namespaced so re-imports of the same backup
        // (e.g. after fixing a typo'd password and re-running this
        // flow) don't collide with the previous attempt's wallet dir.
        let safeName = "\(trimmedName.lowercased())-import-\(Int(Date().timeIntervalSince1970))"
        do {
            let wallet = try AxiomWallet.fromFileVaulted(
                sourcePath: source,
                parentDir: defaultWalletDir(),
                walletName: safeName
            )
            detectedEmail = wallet.email()
            detectedAddress = (try? wallet.address()) ?? "—"
            importedWallet = wallet
        } catch {
            errorMessage = "Couldn't import the file: \(error.localizedDescription)"
        }
    }

    private func performRegister() {
        guard let wallet = importedWallet else { return }
        // Determine if the imported wallet is Ark mode by inspecting
        // its address tier; importing an Ark-only wallet pre-unlock
        // doesn't fit the LoadedPair shape (which requires a Normal
        // wallet), so refuse with a clear hint.
        let isArk = decodeAddress(address: detectedAddress)?.k == 0
        if isArk {
            errorMessage = "Importing an Ark-only wallet from the login screen isn't supported — Mac requires a Normal-mode wallet as the wallet set's anchor. Workaround: import the Normal wallet first, then add the Ark companion from Wallets management."
            return
        }
        isWorking = true
        defer { isWorking = false }
        let trimmedName = pairName.trimmingCharacters(in: .whitespaces)
        do {
            try addWalletPairRegistration(
                parentDir: defaultWalletDir(),
                pairName: trimmedName,
                normalWalletName: wallet.name(),
                arkWalletName: nil
            )
            onImported()
        } catch {
            errorMessage = "Couldn't register the wallet set: \(error.localizedDescription)"
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a wallet backup file"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
            if pairName.isEmpty {
                // Seed the pair name from the source path's parent dir
                // (typical: ".../personal-normal/wallet.axiom" → "Personal").
                let parent = url.deletingLastPathComponent().lastPathComponent
                let stripped = parent
                    .replacingOccurrences(of: "-normal", with: "")
                    .replacingOccurrences(of: "-ark", with: "")
                pairName = stripped.capitalized
            }
            // Reset prior import state so the user can re-pick after a failure.
            importedWallet = nil
            errorMessage = nil
        }
    }
}

private func fieldLabel(_ text: String) -> some View {
    Text(LocalizedStringKey(text))
        .font(DesignTokens.Typography.sectionLabel)
        .tracking(0.4)
        .foregroundStyle(DesignTokens.textTertiary)
}
