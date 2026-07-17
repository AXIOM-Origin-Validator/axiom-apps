import SwiftUI
import AppKit
import AxiomSdk

// =================================================================
// WalletsView — wallet-pair management surface.
//
// Mirrors the rebuilt views/07_wallets.html: one card per pair,
// each card shows the pair's name + actions, and below that the
// Normal + Ark wallets with their addresses, balances, FACT status.
// Partial pairs (Ark companion not generated) show a "missing
// companion" row with an action button.
//
// Actions implemented in this commit:
//   - Rename pair (functional, sheet → renameWalletPair FFI)
//   - Export wallet (functional, NSSavePanel → file copy)
// Actions deferred to follow-ups:
//   - Reset wallet key (needs old-key challenge + new-key prompt)
//   - Generate Ark companion (needs new SDK method to create just
//     an Ark for an existing pair name without colliding)
//   - "+ New pair" (re-runs the onboarding-style ceremony for a
//     second pair)
//   - "Load from file" (NSOpenPanel + Wallet.importFromFile)
//
// Per the integration rule: every cell of data shown here came from
// FFI (session.pairs, wallet.address, wallet.balance,
// wallet.factScarCount). The Export action is a pure file copy of
// wallet.axiom — no network involvement.
// =================================================================

struct WalletsView: View {
    @EnvironmentObject private var session: AppSession
    @State private var renameTarget: LoadedPair? = nil
    @State private var renameDraft: String = ""
    @State private var changeKeyTarget: LoadedPair? = nil
    @State private var actionError: String? = nil
    @State private var actionMessage: String? = nil
    /// Most-recently-copied address — surfaces a "Copied!" pulse on
    /// the matching button. Cleared via DispatchQueue after 1.5s.
    @State private var copiedAddress: String? = nil
    /// Re-render tick — bumped every 2s so balance / scar-count /
    /// FACT depth pick up changes after a successful broadcast in
    /// another view (Send, Receive, Heal). Without this hook the
    /// Wallets view only refreshes on navigation.
    @State private var refreshTick: Int = 0
    @State private var refreshTimer: Timer? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                header

                if let err = actionError {
                    Text(err)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                        .padding(.bottom, DesignTokens.Spacing.xxs)
                }
                if let msg = actionMessage {
                    Text(msg)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.statusCleanFg)
                        .padding(.bottom, DesignTokens.Spacing.xxs)
                }

                if let active = session.activePair {
                    pairCard(active)
                } else {
                    Text("No active wallet set selected. Switch a wallet set from the tab strip above.")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .padding(DesignTokens.Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DesignTokens.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
                }

                footnote
            }
            .padding(EdgeInsets(
                top: DesignTokens.Spacing.lg,
                leading: DesignTokens.Spacing.xl,
                bottom: DesignTokens.Spacing.lg,
                trailing: DesignTokens.Spacing.xl
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bgPrimary)
        .sheet(item: Binding(
            get: { renameTarget.map(RenameTarget.init) },
            set: { _ in renameTarget = nil }
        )) { target in
            renameSheet(for: target.pair)
        }
        .sheet(item: Binding(
            get: { changeKeyTarget.map(ChangeKeyTarget.init) },
            set: { _ in changeKeyTarget = nil }
        )) { target in
            ChangeKeySheet(pair: target.pair) { msg in
                changeKeyTarget = nil
                actionMessage = msg
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if actionMessage == msg { actionMessage = nil }
                }
            }
        }
        .onAppear {
            // Touch refreshTick once so SwiftUI sees the dependency
            // and the 2s tick actually triggers re-renders.
            _ = refreshTick
            startRefreshTimer()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            DispatchQueue.main.async { refreshTick &+= 1 }
        }
    }

    // MARK: - Header

    private var header: some View {
        // "Load from file" and "+ New pair" buttons removed — adding
        // pairs is handled by the "+" at the right edge of the pair
        // tabs strip (MainAppView.pairTabs). One affordance, not two.
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(headerTitle)
                .font(DesignTokens.Typography.heading)
            Text(headerSubtitle)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Pair name on its own line — the active pair *is* the subject
    /// of this view, no need to dress it up with counts.
    private var headerTitle: String {
        _ = refreshTick
        return session.activePair?.name ?? "—"
    }

    /// One-line context under the title — the contact email + the
    /// wallets present in the pair. "Normal + Ark" / "Normal only".
    private var headerSubtitle: String {
        _ = refreshTick
        guard let active = session.activePair else { return "" }
        let mode = active.ark == nil ? "Normal only" : "Normal + Ark"
        return "\(active.normal.email()) · \(mode)"
    }

    // MARK: - Pair card

    @ViewBuilder
    private func pairCard(_ pair: LoadedPair) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(pair.name)
                        .font(DesignTokens.Typography.heading)
                    Text(pairCardSubtitle(pair))
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                Spacer()
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Button("Rename") {
                        renameTarget = pair
                        renameDraft = pair.name
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Export") {
                        exportPair(pair)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Change key") {
                        changeKeyTarget = pair
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Rotate the wallet_key for this wallet set. Requires the current password — for the 'forgot' path use the Recovery sheet from login.")
                }
            }
            .padding(.bottom, DesignTokens.Spacing.sm)
            Divider()
            walletRow(
                label: "Normal",
                tagColor: DesignTokens.brandPrimary,
                tagBg: DesignTokens.brandPrimarySoft,
                wallet: pair.normal
            )
            Divider()
            if let ark = pair.ark {
                walletRow(
                    label: "Ark",
                    tagColor: DesignTokens.textSecondary,
                    tagBg: DesignTokens.bgTertiary,
                    wallet: ark
                )
            } else {
                missingArkRow(pair: pair)
            }
        }
        .padding(EdgeInsets(
            top: DesignTokens.Spacing.md,
            leading: DesignTokens.Spacing.lg,
            bottom: DesignTokens.Spacing.md,
            trailing: DesignTokens.Spacing.lg
        ))
        .background(DesignTokens.bgPrimary)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel)
                .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
    }

    private func pairCardSubtitle(_ pair: LoadedPair) -> String {
        // Without persisted creation timestamps in the wallet schema
        // yet, keep this deliberately spare. When the wallet schema
        // grows a created_at field we surface it here.
        if pair.ark == nil {
            return "Partial pair · Ark companion not generated"
        }
        return "Pair complete · wallet key set"
    }

    @ViewBuilder
    private func walletRow(
        label: String,
        tagColor: Color,
        tagBg: Color,
        wallet: AxiomWallet
    ) -> some View {
        let isArk = (label == "Ark")

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
                Text(label.uppercased())
                    .font(DesignTokens.Typography.chip)
                    .tracking(0.3)
                    .foregroundStyle(tagColor)
                    .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, DesignTokens.Spacing.xxs)
                    .background(tagBg)
                    .clipShape(Capsule())
                    .frame(width: 80, alignment: .leading)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text("\(wallet.email().split(separator: "@").first.map(String.init)?.capitalized ?? wallet.email()) — \(label)")
                        .font(DesignTokens.Typography.labelStrong)
                    Text(walletSubtitle(isArk: isArk))
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                }

                Spacer()
                BalanceText(
                    atoms: wallet.balance(),
                    primaryFont: DesignTokens.Typography.amount,
                    secondaryFont: DesignTokens.Typography.amountCaption,
                    alignment: .trailing,
                    ark: isArk
                )
                .frame(minWidth: 140, alignment: .trailing)

                statusChip(scarCount: wallet.factScarCount())
            }
            .padding(.vertical, DesignTokens.Spacing.xs)

            tierAddressList(wallet: wallet, isArk: isArk)
                .padding(.top, DesignTokens.Spacing.xxs)
                .padding(.bottom, DesignTokens.Spacing.xxs)
                .padding(.leading, 94) // align under the wallet body
        }
    }

    private func walletSubtitle(isArk: Bool) -> String {
        isArk
            ? "Offline mode · k=0 · ARK proof"
            : "Online modes · 6 tier addresses below"
    }

    @ViewBuilder
    private func tierAddressList(wallet: AxiomWallet, isArk: Bool) -> some View {
        let addresses = (try? wallet.allAddresses()) ?? []
        // Normal wallets show every non-Ark tier (Standard, A+, Secure,
        // Secure+, AAA, AAA+). Ark wallets show only the Ark tier —
        // that's the wallet's whole purpose. The FFI returns all 7 for
        // both wallets, so we filter by displayName here.
        let filtered: [TierAddress] = isArk
            ? addresses.filter { $0.displayName == "Ark" }
            : addresses.filter { $0.displayName != "Ark" }

        VStack(spacing: 0) {
            ForEach(Array(filtered.enumerated()), id: \.offset) { idx, tier in
                tierAddressRow(tier: tier)
                if idx < filtered.count - 1 {
                    Divider().opacity(0.3)
                }
            }
        }
        .padding(EdgeInsets(
            top: DesignTokens.Spacing.xxs,
            leading: DesignTokens.Spacing.xs,
            bottom: DesignTokens.Spacing.xxs,
            trailing: DesignTokens.Spacing.xs
        ))
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
        )
    }

    @ViewBuilder
    private func tierAddressRow(tier: TierAddress) -> some View {
        let (tagFg, tagBg) = tierColors(name: tier.displayName)
        let proof = proofTypeLabel(tier.proofType)
        let wasCopied = (copiedAddress == tier.address)

        HStack(alignment: .center, spacing: DesignTokens.Spacing.xs) {
            Text(tier.displayName.uppercased())
                .font(DesignTokens.Typography.chip)
                .tracking(0.3)
                .foregroundStyle(tagFg)
                .padding(.horizontal, DesignTokens.Spacing.xxs).padding(.vertical, DesignTokens.Spacing.xxs)
                .background(tagBg)
                .clipShape(Capsule())
                .frame(width: 70, alignment: .leading)

            Text("k=\(tier.k) · \(proof)")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .frame(width: 80, alignment: .leading)

            Text(tier.address)
                .font(DesignTokens.Typography.monoSmall)
                .foregroundStyle(DesignTokens.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(tier.address)

            Button(action: { copyAddress(tier.address) }) {
                Image(systemName: wasCopied ? "checkmark" : "doc.on.doc")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(wasCopied ? DesignTokens.statusCleanFg : DesignTokens.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Copy address to clipboard")

            ShareLink(item: tier.address) {
                Image(systemName: "square.and.arrow.up")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .help("Share via Mail / Messages / etc.")
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .padding(.horizontal, DesignTokens.Spacing.xxs)
    }

    private func copyAddress(_ address: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        copiedAddress = address
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedAddress == address {
                copiedAddress = nil
            }
        }
    }

    private func tierColors(name: String) -> (Color, Color) {
        let style = TierStyle(tierLabel: name)
        return (style.fg, style.bg)
    }

    private func proofTypeLabel(_ pt: UInt32) -> String {
        switch pt {
        case 0: return "ZKP"
        case 1: return "DMAP"
        case 2: return "ARK"
        default: return "?"
        }
    }

    @ViewBuilder
    private func missingArkRow(pair: LoadedPair) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            Text("MISSING")
                .font(DesignTokens.Typography.chip)
                .tracking(0.3)
                .foregroundStyle(DesignTokens.statusRejectedFg)
                .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, DesignTokens.Spacing.xxs)
                .background(DesignTokens.statusRejectedBg)
                .clipShape(Capsule())
                .frame(width: 80, alignment: .leading)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("\(pair.name) — Ark companion not created")
                    .font(DesignTokens.Typography.labelStrong)
                    .foregroundStyle(DesignTokens.textSecondary)
                Text("An Ark wallet lets you operate offline. Recommended for treasury and reserve funds.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }

            Spacer()

            Button("Generate Ark") {}
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
                .help("Generating an Ark companion for an existing wallet set lands in a follow-up commit (needs an SDK helper that creates just the Ark side).")
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    @ViewBuilder
    private func statusChip(scarCount: UInt32) -> some View {
        let label = scarCount == 0 ? "VERIFIED" : "ATTENTION"
        // Route through the semantic status mapping (VERIFIED → clean,
        // ATTENTION → scarred) and show its symbol so the state is
        // never color-only.
        let style = ChequeStatusStyle(statusString: scarCount == 0 ? "clean" : "scarred")
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Image(systemName: style.symbol)
                .font(DesignTokens.Typography.micro)
            Text(label)
                .font(DesignTokens.Typography.chip)
                .tracking(0.3)
        }
        .foregroundStyle(style.fg)
        .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, DesignTokens.Spacing.xxs)
        .background(style.bg)
        .clipShape(Capsule())
    }

    private var footnote: some View {
        Text("Each pair has its own wallet key. Each mode (Normal, Ark) has its own keypair and wallet_secret. Pairs are independent — losing one pair's secret doesn't affect another.")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.textSecondary)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.sm)
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
            .padding(.top, DesignTokens.Spacing.xs)
    }

    // MARK: - Rename sheet

    @ViewBuilder
    private func renameSheet(for pair: LoadedPair) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Rename wallet set")
                .font(DesignTokens.Typography.heading)
            Text("Renaming changes the label on the tab strip and in the wallet management view. The wallet directories on disk and the keypairs inside them are NOT affected.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("WALLET SET NAME")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                TextField("Pair name", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    renameTarget = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button("Save") {
                    performRename(from: pair.name, to: renameDraft)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandPrimary)
                .controlSize(.large)
                .disabled(
                    renameDraft.trimmingCharacters(in: .whitespaces).isEmpty
                    || renameDraft == pair.name
                )
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 420)
    }

    // MARK: - Actions

    private func performRename(from oldName: String, to newName: String) {
        actionError = nil
        actionMessage = nil
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        do {
            try renameWalletPair(
                parentDir: defaultWalletDir(),
                oldName: oldName,
                newName: trimmed
            )
            // Update the in-memory session.pairs to match the rename.
            // Pure UI state — no extra FFI roundtrip needed.
            if let idx = session.pairs.firstIndex(where: { $0.name == oldName }) {
                let old = session.pairs[idx]
                session.pairs[idx] = LoadedPair(
                    name: trimmed,
                    normal: old.normal,
                    ark: old.ark
                )
            }
            actionMessage = "Renamed “\(oldName)” → “\(trimmed)”."
            renameTarget = nil
        } catch {
            actionError = "Couldn't rename: \(error.localizedDescription)"
        }
    }

    private func exportPair(_ pair: LoadedPair) {
        actionError = nil
        actionMessage = nil
        // Authorize + collect the wallet key: it both gates the export (no silent
        // key dump on an unlocked Mac) and encrypts the backup (so the file isn't
        // plaintext keys in transit). Same key imports it on the web / another device.
        guard let key = promptWalletKey(pairName: pair.name), !key.isEmpty else { return }
        guard pair.normal.verifyWalletKey(walletKey: key) else {
            actionError = "Wrong wallet key — export cancelled."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.title = "Choose a folder to export “\(pair.name)” to"
        panel.prompt = "Export here"
        guard panel.runModal() == .OK, let target = panel.url else { return }

        do {
            try writePortableBackup(pairName: pair.name, mode: "normal", password: key, to: target)
            if pair.ark != nil {
                try writePortableBackup(pairName: pair.name, mode: "ark", password: key, to: target)
            }
            actionMessage = "Exported “\(pair.name)” to \(target.path) as an encrypted backup (AXPW: PBKDF2 + AES-GCM). Import it with the SAME wallet key on the web wallet or another device. The file is safe in transit, but still keep it private."
        } catch {
            actionError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// AppKit password prompt (the export flow is already AppKit-modal via
    /// NSOpenPanel). Returns the entered key, or nil if cancelled.
    private func promptWalletKey(pairName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Export “\(pairName)” — wallet key"
        alert.informativeText = "Your wallet key authorizes the export and encrypts the backup file. The same key imports it on the web wallet or another device."
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Wallet key"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func writePortableBackup(
        pairName: String,
        mode: String,
        password: String,
        to dir: URL
    ) throws {
        let walletName = "\(pairName)-\(mode)"
        let walletDir = "\(defaultWalletDir())/\(walletName)"
        // on-disk AXMK (Keychain) → canonical AXWL → AXPW (password). The keys never
        // leave the Mac in plaintext: the canonical form exists only transiently in
        // memory between the two encryptions.
        let sealed = try Data(contentsOf: URL(fileURLWithPath: "\(walletDir)/wallet.axiom"))
        let axwl = try WalletVault.shared.decryptToCanonical(sealed)
        let axpw = try PortableBackup.seal(axwl, password: password)
        let destDir = dir.appendingPathComponent("\(walletName).backup")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destFile = destDir.appendingPathComponent("wallet.axpw")
        if FileManager.default.fileExists(atPath: destFile.path) {
            try FileManager.default.removeItem(at: destFile)
        }
        try axpw.write(to: destFile, options: .atomic)
    }
}

/// `Identifiable` shim so `LoadedPair` works with `.sheet(item:)`.
private struct RenameTarget: Identifiable {
    let pair: LoadedPair
    var id: String { pair.name }
}

private struct ChangeKeyTarget: Identifiable {
    let pair: LoadedPair
    var id: String { pair.name }
}
