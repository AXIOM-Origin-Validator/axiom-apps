import SwiftUI
import AppKit
import AxiomSdk

// uniffi-generated record types are structs; we extend with
// Identifiable conformance in the Swift module so they work with
// SwiftUI's `.sheet(item:)` and `ForEach`. Identity is the
// cheque_id, which is unique per bundle by construction.
extension ChequeBundleRow: @retroactive Identifiable {
    public var id: String { chequeId }
}

// =================================================================
// ReceiveView — the wallet's "publish your address" surface.
//
// Mirrors views/03_receive.html: tier picker dropdown at top, the
// chosen address rendered in monospace below with copy/QR actions,
// and an incoming-cheque list.
//
// Per the integration rule: every address shown here came from the
// FFI's `wallet.allAddresses()`. The cheque list comes from the
// SDK's pending-cheque store. No URLSession, no direct TCP.
//
// In this commit the cheque list is an empty-state placeholder —
// rendering individual cheques (status chip + sender + tier badge +
// amount + timestamp) needs more FFI surface to expose Cheque
// fields cleanly. That lands in the next commit.
// =================================================================

struct ReceiveView: View {
    @EnvironmentObject private var session: AppSession
    /// Contacts store — used to resolve incoming cheque senders' raw
    /// wallet_id format addresses into human-friendly names. Keyed by
    /// `Contact.address` for an O(N) scan that's fine at the scale
    /// the user can hold in their head. App-scoped (see AxiomWalletApp)
    /// so newly-added contacts from ContactsView resolve names here
    /// without a relaunch.
    @EnvironmentObject private var contactsStore: ContactsStore
    /// Single-flight coordinators. Held here so they can be RE-INJECTED
    /// into the BundleDetailView sheet below — on macOS a `.sheet` is a
    /// separate window and does NOT reliably propagate @EnvironmentObject
    /// observation, so without this the detail sheet's Redeem button read
    /// a stale `isRedeeming = false` and let the user fire a second redeem
    /// while one was already in flight (YP §32 fork risk). Same class of
    /// bug as the Settings-scene env crash.
    @EnvironmentObject private var sendCoordinator: SendCoordinator
    @EnvironmentObject private var redeemCoordinator: RedeemCoordinator
    @EnvironmentObject private var claimCoordinator: ClaimCoordinator
    @EnvironmentObject private var versionSkew: VersionSkewWatcher
    /// Scar-consent retention (YPX-001 §1.5.1). `recvScarConsents()` is
    /// consume-once, so every drain immediately hands off to this
    /// app-scoped store; the cards below render from the store, never
    /// from the transient FFI return.
    @EnvironmentObject private var scarConsentStore: ScarConsentStore
    /// Forwarded into the BundleDetailView sheet so its Redeem gate can
    /// see a Core-rotation lock (separate-window sheet — see note below).
    @EnvironmentObject private var releaseUpdate: ReleaseUpdateWatcher

    // Address state removed 2026-05-25 — the wallet's receive
    // addresses live on the Overview screen now under "Show address"
    // (per YPX-007 §1.4: receiver chooses tier, sender enforces).
    // This view is the cheque-redeem inbox ONLY. Mixing address
    // display with the inbox confused the two distinct concerns:
    // "give my address to someone" vs "consume cheques others sent
    // me." Show address handles the first; this handles the second.

    /// The bundle the user has tapped to inspect, or nil when the
    /// detail sheet is closed.
    @State private var selectedBundle: ChequeBundleRow? = nil

    /// Auto-refresh tick — incremented on each FATMAMA pull. Mentioned
    /// in `bundleSummary` so SwiftUI re-renders the list when fresh
    /// bundles land. Without this hook the view only re-renders on
    /// pair / mode change.
    @State private var refreshTick: Int = 0
    @State private var refreshTimer: Timer? = nil

    /// Transient result line for the "Import cheque" action — shown
    /// under the bundle header for a few seconds after an import.
    @State private var importResult: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                scarConsentSection
                bundleHeader
                bundleList
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.lg, leading: DesignTokens.Spacing.xl, bottom: DesignTokens.Spacing.lg, trailing: DesignTokens.Spacing.xl))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bgPrimary)
        .onAppear { startAutoRefresh() }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        // Reload when the active wallet changes (tab or mode switch).
        .onChange(of: session.activePairIndex) { _, _ in
            startAutoRefresh()
        }
        .onChange(of: session.activeMode) { _, _ in
            startAutoRefresh()
        }
        .sheet(item: $selectedBundle) { bundle in
            BundleDetailView(bundle: bundle) {
                selectedBundle = nil
            }
            // Re-inject — a macOS sheet is a separate window and won't
            // observe the app-scoped coordinators otherwise (the gate
            // that blocks a second concurrent redeem depends on this).
            .environmentObject(session)
            .environmentObject(contactsStore)
            .environmentObject(sendCoordinator)
            .environmentObject(redeemCoordinator)
            .environmentObject(claimCoordinator)
            .environmentObject(versionSkew)
            .environmentObject(releaseUpdate)
        }
    }

    // MARK: - Bundle list

    private var bundleHeader: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("INCOMING CHEQUE BUNDLES")
                        .font(DesignTokens.Typography.sectionLabel)
                        .tracking(0.4)
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text(bundleSummary)
                        .font(DesignTokens.Typography.heading)
                }
                Spacer()
                Menu("Import cheque") {
                    Button("From file…") { importChequeFromFile() }
                    Button("Paste cheque text") { importChequeFromPasteboard() }
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .fixedSize()
                .help("Import a cheque you received out-of-band — a saved email, a file, or pasted text.")
                Button("Redeem all CLEAN") {}
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.small)
                    .disabled(true)
                    .help("Redeem flow lands in a follow-up commit (needs cheque-detail FFI surface).")
            }
            Text("Cheques arrive on their own time — there's no SLA on inbound delivery. Redemption is manual: open a bundle when you're ready, no auto-redeem.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .lineSpacing(2)
            if let importResult {
                // Success/failure styling routed through ChequeStatusStyle
                // (clean = imported, rejected = anything that didn't import)
                // with its symbol so the outcome is never color-only.
                let style = ChequeStatusStyle(
                    statusString: importResult.hasPrefix("Imported") ? "clean" : "rejected"
                )
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Image(systemName: style.symbol)
                        .font(DesignTokens.Typography.caption)
                    Text(importResult)
                        .font(DesignTokens.Typography.caption)
                }
                .foregroundStyle(style.fg)
            }
        }
    }

    // MARK: - Import cheque (out-of-band ingest)

    /// Pick a saved cheque file (a `.eml` exported from any mail
    /// client, a `.txt`, raw `.cbor`, …) and import it.
    private func importChequeFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a saved cheque email or file"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            flashImport("Couldn't read that file.")
            return
        }
        runChequeImport(data)
    }

    /// Import a cheque pasted into the clipboard — the natural path for
    /// an offline hand-off (someone messages you the cheque text).
    private func importChequeFromPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flashImport("Clipboard has no text to import.")
            return
        }
        runChequeImport(Data(text.utf8))
    }

    /// Hand the bytes to the SDK, then run `recv()` so the imported
    /// payload is grouped/stored exactly like a transport-delivered
    /// cheque, and refresh the bundle list.
    private func runChequeImport(_ data: Data) {
        guard let wallet = session.activeWallet else { return }
        do {
            let n = try wallet.importCheque(raw: data)
            if n == 0 {
                flashImport("No cheque found in that input.")
            } else {
                _ = try? wallet.recv()
                refreshTick &+= 1
                flashImport("Imported \(n) cheque\(n == 1 ? "" : "s") — bundle list updated.")
            }
        } catch {
            flashImport("Import failed: \(error.localizedDescription)")
        }
    }

    private func flashImport(_ message: String) {
        importResult = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if importResult == message { importResult = nil }
        }
    }

    private var bundleSummary: String {
        // Reference refreshTick so SwiftUI treats it as an observable
        // dependency — incrementing it on each FATMAMA pull triggers
        // a re-render, surfacing newly-arrived bundles without user
        // action.
        _ = refreshTick
        let count = session.activeWallet?.pendingChequeCount() ?? 0
        if count == 0 { return "No bundles yet" }
        return "\(count) bundle\(count == 1 ? "" : "s") pending"
    }

    /// Background Timer that bumps `refreshTick` every 3 seconds so
    /// the view re-reads `listPendingChequeBundles` from the local
    /// maildir. AxiomKiddo (or the dev env's KIDDO daemon) is what
    /// drops new cheques into inbox/; this Timer just makes the
    /// wallet view notice them.
    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            // Drain inbox/new → cheques/ before re-reading the bundle
            // list. AxiomKiddo drops raw cheque emails into inbox/new;
            // `recv()` extracts the payloads, deduplicates by validator,
            // and stores them as pending bundles. Without this tick the
            // bundle list would never grow even though mail is arriving.
            _ = try? session.activeWallet?.recv()
            // Scar-consent notifications ride the same maildir
            // (YPX-001 §1.5.1). CONSUME-ONCE: whatever this drain
            // returns must land in the store immediately or the
            // passcode is lost. try_lock inside the FFI mirrors
            // recv() — contention returns empty, next tick drains.
            let consents = (try? session.activeWallet?.recvScarConsents()) ?? []
            DispatchQueue.main.async {
                if !consents.isEmpty { scarConsentStore.ingest(consents) }
                refreshTick &+= 1
            }
        }
    }

    // MARK: - Scar-consent requests (YPX-001 §1.5.1)

    /// Consent cards for the ACTIVE wallet's addresses. Other wallets'
    /// notifications stay held in the store until that wallet is active.
    @ViewBuilder
    private var scarConsentSection: some View {
        let addresses = ((try? session.activeWallet?.allAddresses()) ?? []).map(\.address)
        let entries = scarConsentStore.entries(for: addresses)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                ForEach(entries) { entry in
                    ScarConsentInboxCard(entry: entry) {
                        scarConsentStore.dismiss(txidHex: entry.txidHex)
                    }
                }
            }
        }
    }

    /// Match a cheque sender's wallet_id-format address against the
    /// local contacts store. Returns the contact's display name if a
    /// match is found, `nil` otherwise. Case-insensitive on the email
    /// local-part, exact on the checksum/salt suffix.
    private func resolveContactName(for senderAddress: String) -> String? {
        let needle = senderAddress.lowercased()
        return contactsStore.contacts.first {
            $0.address.lowercased() == needle
        }?.name
    }

    private var bundleList: some View {
        let bundles = (session.activeWallet?.listPendingChequeBundles() ?? [])
            .sorted { $0.createdAt > $1.createdAt }
        return VStack(spacing: 0) {
            if bundles.isEmpty {
                emptyState
            } else {
                rowHeader
                ForEach(bundles, id: \.chequeId) { bundle in
                    Divider().opacity(0.3)
                    Button(action: { selectedBundle = bundle }) {
                        BundleRow(
                            bundle: bundle,
                            contactName: resolveContactName(for: bundle.sender)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("No incoming bundles.")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textSecondary)
            Text("Cheques sent to any of your tier addresses appear here once they arrive at your maildir. Share an address above to receive a payment. If a sender's cheque is in flight, it'll land whenever the carrier delivers — not a bug if it isn't here yet.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textTertiary)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.sm))
    }

    private var rowHeader: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("STATUS").frame(width: 90, alignment: .leading)
            Text("SENDER").frame(maxWidth: .infinity, alignment: .leading)
            Text("TIER").frame(width: 80, alignment: .trailing)
            Text("AMOUNT · AGE").frame(width: 150, alignment: .trailing)
        }
        .font(DesignTokens.Typography.sectionLabel)
        .tracking(0.4)
        .foregroundStyle(DesignTokens.textTertiary)
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
    }

    // MARK: - Actions
    // (loadAddresses / copyAddress removed 2026-05-25 with the
    // addressCard move to the Overview's Show address sheet.)
}

// =================================================================
// BundleRow — one cheque-bundle line in the Receive view's table.
// =================================================================
private struct BundleRow: View {
    let bundle: ChequeBundleRow
    /// Resolved contact name when the sender's wallet_id matches an
    /// entry in the local contacts store. `nil` falls back to the
    /// email local-part. Passed in by ReceiveView so the row stays
    /// decoupled from ContactsStore.
    let contactName: String?

    /// Hover feedback for the clickable row (plain button style has
    /// none of its own). Purely visual.
    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            statusChip.frame(width: 90, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(displaySender)
                    .font(DesignTokens.Typography.bodyStrong)
                Text(senderAddressOrReason)
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            tierPill.frame(width: 80, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 2) {
                Text(amountDisplay)
                    .font(DesignTokens.Typography.amount)
                    .strikethrough(bundle.displayStatus == "rejected")
                    .foregroundStyle(amountColor)
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Text(relativeAgeDisplay)
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textSecondary)
                    Text("·")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text(timestampDisplay)
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(DesignTokens.Motion.quick()) {
                isHovering = hovering
            }
        }
        .help(rowTooltip)
    }

    // ── Status chip ─────────────────────────────────────────────────
    //
    // Shape: a strip of `required_k` dots — `signature_count` filled
    // green, the rest gray (still waiting for that validator's copy).
    // Once the §4.6 Nabla verify lands as `"clean"`, a checkmark
    // appears on the right. `"scarred"` overlays a warning glyph;
    // `"rejected"` strikes the strip through and shows an X.
    @ViewBuilder
    private var statusChip: some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            dotStrip
            verifyGlyph
        }
    }

    private var dotStrip: some View {
        let k = max(1, Int(bundle.requiredK))
        let got = min(Int(bundle.signatureCount), k)
        return HStack(spacing: 3) {
            ForEach(0..<k, id: \.self) { i in
                Circle()
                    .fill(i < got ? DesignTokens.statusCleanFg : DesignTokens.bgTertiary)
                    .frame(width: 6, height: 6)
            }
        }
    }

    @ViewBuilder
    private var verifyGlyph: some View {
        switch bundle.displayStatus {
        case "clean", "scarred", "rejected":
            // Color + symbol both come from ChequeStatusStyle — the
            // single mapping for cheque states (never color-only).
            let style = ChequeStatusStyle(statusString: bundle.displayStatus)
            Image(systemName: style.symbol)
                .font(DesignTokens.Typography.labelStrong)
                .foregroundStyle(style.fg)
                .padding(.leading, DesignTokens.Spacing.xxs)
        default:
            // "loading" — no glyph; just the dots. The k-dot strip
            // alone tells the user the bundle is still assembling.
            EmptyView()
        }
    }

    // ── Tier pill ───────────────────────────────────────────────────
    @ViewBuilder
    private var tierPill: some View {
        if let name = bundle.tierDisplayName {
            let (fg, bg) = tierColors(name: name)
            Text(name)
                .font(DesignTokens.Typography.chip)
                .tracking(0.3)
                .foregroundStyle(fg)
                .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, 3)
                .background(bg)
                .clipShape(Capsule())
        } else {
            Text("—")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textTertiary)
        }
    }

    private func tierColors(name: String) -> (Color, Color) {
        let style = TierStyle(tierLabel: name)
        return (style.fg, style.bg)
    }

    // ── Cell content ────────────────────────────────────────────────
    private var displaySender: String {
        // Genesis/airdrop self-cheque — label it as the airdrop, not the
        // wallet's own (self) sender local-part. (SDK flag: self-send of
        // GENESIS_CLAIM_AMOUNT; HAL/HEAL dust self-cheques don't match.)
        if bundle.isGenesisAirdrop {
            return "1 AXC airdrop"
        }
        // Prefer the contact's display name if the user has saved this
        // sender; otherwise fall back to the email local-part. The full
        // wallet_id-format address always shows on the second line.
        if let name = contactName, !name.isEmpty {
            return name
        }
        let local = bundle.sender.split(separator: "@").first.map(String.init) ?? bundle.sender
        return local
    }

    /// Compact "5m / 2h / 3d" relative age based on the cheque's
    /// `created_at` Unix timestamp. Pure UI — the underlying state
    /// doesn't change as time passes; SwiftUI re-renders on the
    /// ReceiveView's 3-second refreshTick which is good enough for
    /// human-scale age display.
    private var relativeAgeDisplay: String {
        let nowSecs = UInt64(Date().timeIntervalSince1970)
        guard bundle.createdAt > 0, nowSecs >= bundle.createdAt else { return "—" }
        let delta = nowSecs - bundle.createdAt
        switch delta {
        case 0..<60:        return "just now"
        case 60..<3600:     return "\(delta / 60)m"
        case 3600..<86400:  return "\(delta / 3600)h"
        case 86400..<604800: return "\(delta / 86400)d"
        default:            return "\(delta / 604800)w"
        }
    }

    private var senderAddressOrReason: String {
        if bundle.displayStatus == "rejected", let reason = bundle.displayReason {
            return reason
        }
        if bundle.displayStatus == "scarred" {
            return "\(bundle.sender) · sender flagged on Nabla"
        }
        if bundle.isGenesisAirdrop {
            return "Genesis airdrop — redeem to credit your wallet (redeem · CLAIM)"
        }
        return bundle.sender
    }

    private var amountDisplay: String { formatBalance(bundle.amount) }

    private var amountColor: Color {
        switch bundle.displayStatus {
        case "rejected": return DesignTokens.textSecondary
        default: return DesignTokens.textPrimary
        }
    }

    private var timestampDisplay: String {
        let date = Date(timeIntervalSince1970: TimeInterval(bundle.createdAt))
        let f = DateFormatter()
        f.dateFormat = "MMM dd · HH:mm"
        return f.string(from: date)
    }

    private var rowBackground: Color {
        switch bundle.displayStatus {
        case "scarred", "rejected":
            // Large-area row tint — pre-blended soft fill from the
            // ONE cheque-status mapping (replaces ad-hoc .opacity).
            return ChequeStatusStyle(statusString: bundle.displayStatus).bgSoft
        default:
            return isHovering ? DesignTokens.bgTertiary : Color.clear
        }
    }

    private var rowTooltip: String {
        let sig = "\(bundle.signatureCount) of \(bundle.requiredK) validator signatures collected"
        switch bundle.displayStatus {
        case "clean":
            return "\(sig). Verified by Nabla — ready to redeem."
        case "scarred":
            return "\(sig). Sender has an unresolved scar on Nabla. Redeeming inherits the scar to your FACT chain — you can heal/burn afterwards."
        case "rejected":
            return "\(sig). Double-spend conflict detected by Nabla. Do not redeem."
        default:
            if bundle.signatureCount < bundle.requiredK {
                return "\(sig). Waiting for the remaining validators to forward their cheque copy."
            }
            return "\(sig). Quorum reached; awaiting Nabla §4.6 verify (gossip propagation + 5-tick maturity window)."
        }
    }
}
