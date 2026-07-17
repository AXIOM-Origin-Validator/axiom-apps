import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AxiomSdk

// =================================================================
// ActivityView — transaction history.
//
// Mirrors views/05_activity.html: header with FACT chain summary +
// search + Export CSV, then a row table with one entry per
// transaction. Each row: type icon, counterparty + txid + reference,
// tier pill, FACT status chip, amount with sign.
//
// Pure on-disk read via wallet.history() (FFI). Fresh wallet has no
// history → empty state.
// =================================================================

// Friendly display label for a raw FFI tx_type string. The HAL re-anchor
// self-send (YPX-020) comes across the wire as "hal_reanchor"; the raw
// `.uppercased()` would render the ugly "HAL_REANCHOR". (Completion is a
// Redeem under §2 — there is no "hal_complete" row.)
func prettyTxType(_ raw: String) -> String {
    switch raw {
    case "hal_reanchor": return "HAL RE-ANCHOR"
    default:             return raw.uppercased()
    }
}

// True for wallet-internal self-sends that move no counterparty value
// (heal + HAL re-anchor). Used to suppress the misleading "0.0000 AXC"
// amount + the "To/From" counterparty row.
func isSelfRecoveryTx(_ raw: String) -> Bool {
    raw == "heal" || raw == "hal_reanchor"
}

struct ActivityView: View {
    @EnvironmentObject private var session: AppSession
    /// Consent ledger (YPX-001 §1.5.1) — permanent per-txid records that
    /// label consent-gated payments in this log: the sender's "scarred
    /// send, completed with passcode" and the receiver's "you consented
    /// via passcode".
    @EnvironmentObject private var scarConsentStore: ScarConsentStore
    @State private var search: String = ""
    @State private var showHealSheet: Bool = false
    /// Non-nil shows the certificate-export error alert.
    @State private var certError: String? = nil
    /// Non-nil presents the per-transaction detail sheet.
    @State private var detail: TxDetail? = nil
    /// Presents the import-and-verify (Core-attested) Send Proof sheet.
    @State private var showVerify: Bool = false

    /// In-app log: interleave the captured app log (SDK diagnostics) with the
    /// send/receive history. Persisted (global) preference; untick = activity
    /// only (the previous behaviour).
    @AppStorage("activityShowLogs") private var showLogs: Bool = false
    @ObservedObject private var logStore = LogStore.shared

    private let limit: UInt32 = 200

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                header
                if !scars.isEmpty {
                    scarsSection
                }
                if feed.isEmpty {
                    emptyState
                } else {
                    rowTable
                }
                footnote
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.lg, leading: DesignTokens.Spacing.xl, bottom: DesignTokens.Spacing.lg, trailing: DesignTokens.Spacing.xl))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bgPrimary)
        .sheet(isPresented: $showHealSheet) {
            HealConfirmSheet(
                onCancel: { showHealSheet = false },
                onCompletion: { showHealSheet = false }
            )
            .environmentObject(session)
        }
        .alert("Certificate", isPresented: Binding(
            get: { certError != nil },
            set: { if !$0 { certError = nil } }
        )) {
            Button("OK", role: .cancel) { certError = nil }
        } message: {
            Text(certError ?? "")
        }
        .sheet(isPresented: $showVerify) {
            VerifyProofSheet(onClose: { showVerify = false })
        }
        .sheet(item: $detail) { d in
            TxDetailSheet(
                row: d.row,
                isArk: session.activeMode == .ark,
                walletName: session.activeWallet?.name() ?? "",
                scarTxids: Set(scars.map { $0.txidHex.lowercased() }),
                consent: scarConsentStore.consentRecord(txidHex: d.row.txid),
                exportCertificate: {
                    session.activeWallet?.exportSendCertificatePdf(txidHex: d.row.txid)
                        ?? SendCertificatePdfRow(ok: false, pdf: Data(), reason: "Wallet unavailable.")
                },
                exportProofBundle: {
                    guard let w = session.activeWallet else { return nil }
                    return try? w.exportSendProofCbor(txidHex: d.row.txid)
                },
                onClose: { detail = nil }
            )
            .environmentObject(session)
        }
    }

    private var scars: [ScarLinkRow] {
        session.activeWallet?.listScarredLinks() ?? []
    }

    private var records: [TxHistoryRow] {
        guard let wallet = session.activeWallet else { return [] }
        let all = wallet.history(limit: limit)
        if search.trimmingCharacters(in: .whitespaces).isEmpty {
            return all
        }
        let needle = search.lowercased()
        return all.filter { row in
            row.counterparty.lowercased().contains(needle)
                || row.txid.lowercased().contains(needle)
                || (row.reference ?? "").lowercased().contains(needle)
                || row.txType.contains(needle)
        }
    }

    /// Unified time-sorted feed: history rows, plus captured log lines when the
    /// Logs toggle is on (also filtered by the search box).
    private var feed: [ActivityFeedItem] {
        var items = records.map { ActivityFeedItem.tx($0) }
        if showLogs {
            let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
            let logs = needle.isEmpty
                ? logStore.entries
                : logStore.entries.filter { $0.text.lowercased().contains(needle) }
            items += logs.map { ActivityFeedItem.log($0) }
        }
        return items.sorted { $0.time > $1.time }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TRANSACTION HISTORY")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(factChainSummary)
                    .font(DesignTokens.Typography.heading)
            }
            Spacer()
            HStack(spacing: DesignTokens.Spacing.xxs) {
                TextField("Search by sender, txid, amount", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 280)
                Button("Verify proof…") { showVerify = true }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Import a .cbor Send Proof and verify it through Core (CL12).")
                Button("Export CSV") { exportCsv() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(records.isEmpty)
                Toggle(isOn: $showLogs) {
                    Label("Logs", systemImage: "terminal")
                }
                .toggleStyle(.button)
                .controlSize(.regular)
                .help("Interleave the app's live log (SDK diagnostics) with activity, and write it to a file. Untick for activity only.")
            }
        }
    }

    private var factChainSummary: String {
        guard let wallet = session.activeWallet else { return "—" }
        let depth = wallet.factLinkCount()
        let scars = wallet.factScarCount()
        if scars == 0 {
            return "FACT chain · \(depth) of 8 link(s) · VERIFIED"
        }
        return "FACT chain · \(depth) of 8 link(s) · \(scars) scar(s)"
    }

    // MARK: - Empty state

    // MARK: - Scars section
    //
    // One row per unresolved scar in the FACT chain, surfaced above the
    // history. The CTA opens HealConfirmSheet — the SDK's heal() picks
    // the oldest scar itself, so this is a one-click "resolve next" rather
    // than per-link targeting. Targeting a specific tx_id requires an SDK
    // addition (parameterised burn_scar) — separate work.

    private var scarsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Text("UNRESOLVED SCARS")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Spacer()
                Text("\(scars.count) of \(session.activeWallet?.factLinkCount() ?? 0) link\(scars.count == 1 ? "" : "s")")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            VStack(spacing: 0) {
                ForEach(Array(scars.enumerated()), id: \.offset) { idx, scar in
                    scarRow(scar)
                    if idx < scars.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }
            .background(DesignTokens.statusScarredBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                    .strokeBorder(DesignTokens.statusScarredFg.opacity(0.3), lineWidth: DesignTokens.hairline)
            )
            Text("Each row is a FACT link missing its Nabla confirmation. Heal next will register a supplemental confirmation or burn the oldest link if it can't be resolved. SDK picks the oldest; targeting a specific link lands in a follow-up.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .lineSpacing(2)
        }
    }

    private func scarRow(_ scar: ScarLinkRow) -> some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Text("Link #\(scar.linkIndex + 1)")
                        .font(DesignTokens.Typography.labelStrong)
                    Text(scarShortTxid(scar.txidHex))
                        .font(DesignTokens.Typography.monoSmall)
                        .foregroundStyle(DesignTokens.textTertiary)
                        .textSelection(.enabled)
                }
                Text("Amount: \(formatBalance(scar.amount)) · \(formatAxcOnly(scar.amount))")
                    .font(DesignTokens.Typography.amountCaption)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            Spacer()
            // First-in-chain scars are the SDK's heal target. Marking
            // the row with "next" hints which one will resolve when
            // the user clicks.
            if scar.linkIndex == (scars.first?.linkIndex ?? UInt32.max) {
                Button("Heal next") { showHealSheet = true }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.statusScarredFg)
                    .controlSize(.small)
                    // YPX-020: heal is rejected while hibernating.
                    .disabled(session.isHibernating)
            } else {
                Text("queued")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
    }

    private func scarShortTxid(_ hex: String) -> String {
        guard hex.count > 16 else { return hex }
        let head = hex.prefix(8)
        let tail = hex.suffix(8)
        return "\(head)…\(tail)"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("No transactions yet.")
                .font(DesignTokens.Typography.labelStrong)
                .foregroundStyle(DesignTokens.textSecondary)
            Text("Sends, receives, redeems, heals, and burns appear here as you make them. Each row is signed off-chain by the SDK and recorded locally — no network call needed to display.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.sm))
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    // MARK: - Recall origin correlation

    /// For a recall-completion redeem (a self-redeem tagged "RECALL"), find the
    /// ORIGINAL payment it retracted so the row can read "was sent to <who> on
    /// <when> · txid <x>" instead of the misleading "Received from <self>". The
    /// recall record carries the retracted send's txid + amount; we match the
    /// redeem to it by amount, then look the original send up in history for the
    /// recipient + date. Returns nil for any non-recall row.
    private func recallOrigin(for r: TxHistoryRow) -> String? {
        guard r.txType == "redeem",
              (r.reference ?? "").uppercased() == "RECALL",
              let wallet = session.activeWallet else { return nil }
        let records = wallet.recallRecords()
        guard let rec = records.first(where: { $0.amount == r.amount }) else { return nil }
        let txid8 = String(rec.recalledTxidHex.prefix(8))
        let sends = wallet.history(limit: 300)
        guard let orig = sends.first(where: { $0.txid == rec.recalledTxidHex }) else {
            return "recalled payment · txid \(txid8)…"
        }
        let to = orig.counterparty.split(separator: "@").first.map(String.init) ?? orig.counterparty
        let f = DateFormatter(); f.dateFormat = "MMM dd, yyyy"
        let when = f.string(from: Date(timeIntervalSince1970: TimeInterval(orig.timestamp)))
        return "was sent to \(to) on \(when) · txid \(txid8)…"
    }

    // MARK: - Row table

    private var rowTable: some View {
        VStack(spacing: 0) {
            tableHeader
            ForEach(feed) { item in
                Divider().opacity(0.3)
                switch item {
                case .tx(let row):
                    ActivityRow(row: row, isArk: session.activeMode == .ark,
                                onTap: { detail = TxDetail(row: row) },
                                recallOrigin: recallOrigin(for: row),
                                consent: scarConsentStore.consentRecord(txidHex: row.txid))
                        .contextMenu {
                            if row.txType == "send" {
                                Button("Save certificate / receipt (PDF)…") {
                                    saveCertificate(for: row.txid)
                                }
                            }
                        }
                case .log(let entry):
                    LogRow(entry: entry)
                }
            }
        }
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private var tableHeader: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("").frame(width: 22)
            Text("COUNTERPARTY").frame(maxWidth: .infinity, alignment: .leading)
            Text("TYPE").frame(width: 96, alignment: .trailing)
            // AMOUNT uses the SAME fixed width the rows use below so
            // the TYPE / AMOUNT headers line up exactly over the pill +
            // figure. ~30% of a typical window; the figures never wrap
            // (lineLimit(1) + minimumScaleFactor on the cells below).
            Text("AMOUNT").frame(width: 175, alignment: .trailing)
        }
        .font(DesignTokens.Typography.sectionLabel)
        .tracking(0.4)
        .foregroundStyle(DesignTokens.textTertiary)
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
    }

    // MARK: - Footnote

    private var footnote: some View {
        Text("Records are stored locally — the SDK writes one entry per signed transaction. Click any row to see the full txid, the witnessing validator set, the fee breakdown, and the FACT-chain / Nabla-confirmation status for that transaction.")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.textSecondary)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.sm))
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    // MARK: - Export CSV

    private func exportCsv() {
        let panel = NSSavePanel()
        panel.title = "Export transaction history as CSV"
        panel.nameFieldStringValue = "axiom-history-\(Int(Date().timeIntervalSince1970)).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        var lines = ["txid,type,amount_atoms,counterparty,timestamp_unix,reference"]
        for r in records {
            let ref = (r.reference ?? "")
                .replacingOccurrences(of: "\"", with: "\"\"")
            lines.append(
                "\(r.txid),\(r.txType),\(r.amount),\"\(r.counterparty)\",\(r.timestamp),\"\(ref)\""
            )
        }
        let csv = lines.joined(separator: "\n")
        try? csv.write(to: target, atomically: true, encoding: .utf8)
    }

    // MARK: - Send Proof certificate

    /// Export a bank-grade certificate PDF for a sent transaction. One FFI call
    /// does export → verify (against the local CoreID) → render the PDF (with the
    /// CBOR bundle embedded). `ok=false` (no retained proof, or it didn't verify)
    /// surfaces the reason in an alert.
    private func saveCertificate(for txid: String) {
        guard let wallet = session.activeWallet else { return }
        let result = wallet.exportSendCertificatePdf(txidHex: txid)
        guard result.ok else {
            certError = result.reason ?? "No retained Send Proof for this transaction."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Send Proof certificate"
        panel.nameFieldStringValue = "axiom-certificate-\(txid.prefix(12)).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try result.pdf.write(to: target)
        } catch {
            certError = "Could not save the certificate: \(error.localizedDescription)"
        }
    }
}

// =================================================================
// ActivityRow — one transaction-history line.
// =================================================================
// ── Unified Activity feed item: a history row OR a captured log line ──
private enum ActivityFeedItem: Identifiable {
    case tx(TxHistoryRow)
    case log(LogStore.Entry)
    var id: String {
        switch self {
        case .tx(let r):  return "tx-\(r.txid)-\(r.timestamp)"
        case .log(let e): return "log-\(e.id.uuidString)"
        }
    }
    var time: Date {
        switch self {
        case .tx(let r):  return Date(timeIntervalSince1970: TimeInterval(r.timestamp))
        case .log(let e): return e.time
        }
    }
}

// LogRow — one captured app-log line (monospace; red-tinted on error).
private struct LogRow: View {
    let entry: LogStore.Entry
    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.textTertiary)
                .frame(width: 22)
            Text(LogStore.stamp(entry.time))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DesignTokens.textTertiary)
            Text(entry.text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(entry.isError ? DesignTokens.statusRejectedFg : DesignTokens.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 3)
        .background(entry.isError ? DesignTokens.statusRejectedBgSoft : Color.clear)
    }
}

private struct ActivityRow: View {
    let row: TxHistoryRow
    /// Pulled from the parent so an Ark wallet's per-row amounts
    /// pick up the `⟠` glyph on both the L$ and AXC lines.
    let isArk: Bool
    /// Open the per-transaction detail sheet. Fired by a tap on the
    /// row body (not the fee-disclosure chevron, which has its own
    /// button).
    var onTap: () -> Void = {}
    /// For a recall-completion redeem: the origin of the retracted payment
    /// ("was sent to johnny on … · txid …"), correlated by the parent from the
    /// recall records + history. Shown in the subtitle instead of a bare
    /// "RECALL" reference so the row reads as a recall of a real payment.
    var recallOrigin: String? = nil
    /// Consent-ledger match (YPX-001 §1.5.1): this row is a consent-gated
    /// payment — role "sender" (scarred send completed with the receiver's
    /// passcode) or "receiver" (inbound the user consented to by sharing
    /// the passcode). Renders the CONSENT chip + subtitle label.
    var consent: ConsentLedgerRecord? = nil

    /// Receiver-side service-fee disclosure. Hidden by default to
    /// keep the activity list scannable; opens on chevron tap.
    @State private var feesExpanded: Bool = false

    /// Hover feedback for the plain-style disclosure toggle. Purely
    /// visual.
    @State private var isHoveringDisclosure: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                iconCircle.frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headlineText)
                        .font(DesignTokens.Typography.labelStrong)
                    Text(subtitleText)
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    typePill
                    if consent != nil {
                        // Never color-only: the chip pairs with the
                        // subtitle text below for the full story.
                        Text("CONSENT")
                            .font(DesignTokens.Typography.chip)
                            .tracking(0.3)
                            .foregroundStyle(DesignTokens.statusScarredFg)
                            .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, 2)
                            .background(DesignTokens.statusScarredBg)
                            .clipShape(Capsule())
                            .help(consentTooltip)
                    }
                }
                .frame(width: 96, alignment: .trailing)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(amountDisplay)
                        .font(DesignTokens.Typography.amount)
                        .foregroundStyle(amountColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    // Heal + HAL re-anchor/complete have no counterparty
                    // value transfer (wallet-internal recovery self-sends
                    // re-anchoring state), so skip the AXC subtitle too —
                    // "0.0000 AXC" is misleading there.
                    if !isSelfRecoveryTx(row.txType) {
                        Text("\(amountSignPrefix)\(isArk ? formatAxcOnlyArk(displayedAmount) : formatAxcOnly(displayedAmount))")
                            .font(DesignTokens.Typography.amountCaption)
                            .foregroundStyle(DesignTokens.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .frame(width: 175, alignment: .trailing)
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            // fee_breakdown carries the witnessing-validator set on
            // every send / redeem row written since Bug I (2026-06-06).
            // On redeem rows each entry has `amount > 0` (validator
            // fees); on send rows `amount == 0` (cashier's-cheque
            // model — sender pays nothing) and the disclosure renders
            // as a plain witness list. Overlapped validators (carried
            // from prior round's witness set) get a green border on
            // their "witness" pill so the operator-overlap shape is
            // visible at a glance.
            if !row.feeBreakdown.isEmpty {
                feeOrWitnessDisclosure
            }
        }
    }

    @ViewBuilder
    private var feeOrWitnessDisclosure: some View {
        let totalFee = row.feeBreakdown.reduce(UInt64(0)) { $0 &+ $1.amount }
        let hasFees = totalFee > 0
        let netCredit = row.amount > totalFee ? row.amount - totalFee : 0
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DesignTokens.Motion.standard()) {
                    feesExpanded.toggle()
                }
            } label: {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Image(systemName: feesExpanded ? "chevron.down" : "chevron.right")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                    if hasFees {
                        Text("Service charges")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(DesignTokens.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Text("-\(isArk ? formatAxcOnlyArk(totalFee) : formatAxcOnly(totalFee))")
                            .font(DesignTokens.Typography.amountCaption)
                            .foregroundStyle(DesignTokens.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    } else {
                        Text("Witnesses")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(DesignTokens.textTertiary)
                            .lineLimit(1)
                    }
                    Text("(\(row.feeBreakdown.count) validator\(row.feeBreakdown.count == 1 ? "" : "s"))")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary.opacity(0.7))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: DesignTokens.Spacing.xs)
                    if hasFees {
                        Text("Net credit: +\(isArk ? formatAxcOnlyArk(netCredit) : formatAxcOnly(netCredit))")
                            .font(DesignTokens.Typography.amountCaption)
                            .foregroundStyle(DesignTokens.statusCleanAccent.opacity(0.85))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, DesignTokens.Spacing.xxs)
                .background(isHoveringDisclosure ? DesignTokens.bgTertiary : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(DesignTokens.Motion.quick()) {
                    isHoveringDisclosure = hovering
                }
            }

            if feesExpanded {
                VStack(spacing: DesignTokens.Spacing.xxs) {
                    ForEach(Array(row.feeBreakdown.enumerated()), id: \.offset) { idx, fs in
                        let share = hasFees
                            ? Double(fs.amount) / Double(totalFee) * 100.0
                            : 0
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Text(validatorDisplay(fs))
                                .font(DesignTokens.Typography.micro)
                                .foregroundStyle(DesignTokens.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            witnessPill(isOverlapped: fs.isOverlapped)
                            if fs.isOverlapped {
                                // Tiny help affordance — hover shows
                                // the S-ABR overlap explanation
                                // without crowding the row.
                                Image(systemName: "info.circle")
                                    .font(DesignTokens.Typography.micro)
                                    .foregroundStyle(DesignTokens.statusCleanFg.opacity(0.6))
                                    .help("Overlapped — this validator was carried from the prior round's witness set per the S-ABR overlap requirement (YPX-007 §10). Validators picked fresh for this round don't have this mark.")
                            }
                            Spacer(minLength: DesignTokens.Spacing.xs)
                            if hasFees {
                                Text(String(format: "%.1f%%", share))
                                    .font(DesignTokens.Typography.monoSmall)
                                    .foregroundStyle(DesignTokens.textTertiary)
                                    .lineLimit(1)
                                    .frame(width: 52, alignment: .trailing)
                                Text("-\(isArk ? formatAxcOnlyArk(fs.amount) : formatAxcOnly(fs.amount))")
                                    .font(DesignTokens.Typography.amountCaption)
                                    .foregroundStyle(DesignTokens.textSecondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .padding(.horizontal, DesignTokens.Spacing.md)
                    }
                }
                .padding(.vertical, DesignTokens.Spacing.xxs)
            }
        }
        .background(DesignTokens.bgSecondary.opacity(0.4))
    }

    /// Small "witness" pill. Overlapped validators (carried from prior
    /// round's witness set) get a green border to make the S-ABR
    /// overlap shape visible at a glance — the operator quickly sees
    /// which validators were the protocol-mandated picks vs fresh
    /// choices. Non-overlapped validators get the original solid
    /// background (no border).
    @ViewBuilder
    private func witnessPill(isOverlapped: Bool) -> some View {
        Text("witness")
            .font(DesignTokens.Typography.micro)
            .foregroundStyle(isOverlapped
                ? DesignTokens.statusCleanFg
                : DesignTokens.textTertiary.opacity(0.7))
            .padding(.horizontal, DesignTokens.Spacing.xxs).padding(.vertical, 1)
            .background(isOverlapped
                ? DesignTokens.statusCleanBg
                : DesignTokens.bgTertiary)
            .overlay(
                Capsule()
                    .strokeBorder(
                        isOverlapped
                            ? DesignTokens.statusCleanFg.opacity(0.9)
                            : Color.clear,
                        lineWidth: 1
                    )
            )
            .clipShape(Capsule())
    }

    /// Display label for one fee share — operator-chosen name when
    /// the runtime resolved it, otherwise the hex-id prefix (same
    /// shorthand the rest of the wallet uses for validators).
    private func validatorDisplay(_ fs: TxFeeShareRow) -> String {
        if !fs.validatorName.isEmpty { return fs.validatorName }
        let prefix = fs.validatorIdHex.prefix(8)
        return "\(prefix)…"
    }

    // MARK: - Icon + color semantics

    @ViewBuilder
    private var iconCircle: some View {
        ZStack {
            Circle().fill(iconBg)
                .frame(width: 22, height: 22)
            Text(iconGlyph)
                .font(DesignTokens.Typography.labelStrong)
                .foregroundStyle(iconFg)
        }
    }

    private var iconGlyph: String {
        switch row.txType {
        case "receive", "redeem": return "↓"
        case "send":              return "↑"
        case "heal":              return "✚"
        case "hal_reanchor":      return "⚓"
        case "burn":              return "🔥"
        case "genesis":           return "★"
        default:                  return "·"
        }
    }

    private var iconBg: Color {
        switch row.txType {
        case "receive", "redeem", "genesis": return DesignTokens.statusCleanBg
        case "burn":                          return DesignTokens.statusRejectedBg
        case "heal", "hal_reanchor": return DesignTokens.statusScarredBg
        default:                              return DesignTokens.bgTertiary
        }
    }

    private var iconFg: Color {
        switch row.txType {
        case "receive", "redeem", "genesis": return DesignTokens.statusCleanAccent
        case "burn":                          return DesignTokens.statusRejectedFg
        case "heal", "hal_reanchor": return DesignTokens.statusScarredFg
        default:                              return DesignTokens.textSecondary
        }
    }

    // MARK: - Type pill

    @ViewBuilder
    private var typePill: some View {
        let label = prettyTxType(row.txType)
        let (fg, bg) = typeColors
        Text(label)
            .font(DesignTokens.Typography.chip)
            .tracking(0.3)
            .foregroundStyle(fg)
            .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, 3)
            .background(bg)
            .clipShape(Capsule())
    }

    private var typeColors: (Color, Color) {
        switch row.txType {
        case "receive", "redeem", "genesis":
            return (DesignTokens.statusCleanFg, DesignTokens.statusCleanBg)
        case "burn":
            return (DesignTokens.statusRejectedFg, DesignTokens.statusRejectedBg)
        case "heal", "hal_reanchor":
            return (DesignTokens.statusScarredFg, DesignTokens.statusScarredBg)
        default:
            return (DesignTokens.textSecondary, DesignTokens.bgTertiary)
        }
    }

    // MARK: - Cells

    // ONE source of truth for the row headline — shared with the Overview
    // recent-activity preview via `TxHistoryRow.displayHeadline`, so the two
    // can't drift (the airdrop label appearing only in Activity is exactly that
    // drift). See the extension at the bottom of this file.
    private var headlineText: String { row.displayHeadline }

    private var displayCounterparty: String {
        let local = row.counterparty.split(separator: "@").first.map(String.init) ?? row.counterparty
        return local
    }

    private var subtitleText: String {
        var parts: [String] = []
        let date = Date(timeIntervalSince1970: TimeInterval(row.timestamp))
        let f = DateFormatter()
        f.dateFormat = "MMM dd · HH:mm"
        parts.append(f.string(from: date))
        // Recall completion: show the retracted payment's origin instead of the
        // recall cheque's own txid + a bare "RECALL" tag.
        if let ro = recallOrigin {
            parts.append(ro)
            return parts.joined(separator: " · ")
        }
        let txidShort = row.txid.count >= 12 ? "txid \(row.txid.prefix(8))…" : "txid \(row.txid)"
        parts.append(txidShort)
        // YPX-001 §1.5.1 — identify consent-gated payments in the log.
        if let c = consent {
            parts.append(c.role == "sender"
                ? "scarred send — receiver consented (passcode ✓)"
                : "scarred payment — you consented via passcode")
        }
        if let ref = row.reference, !ref.isEmpty {
            parts.append(ref)
        }
        return parts.joined(separator: " · ")
    }

    private var consentTooltip: String {
        guard let c = consent else { return "" }
        return c.role == "sender"
            ? "This money carried unverified provenance link(s). The payment was paused by the validator and completed only after the receiver approved it by sharing consent passcode \(String(format: "%06u", c.passcode))."
            : "This incoming payment carried unverified provenance link(s). You consented by sharing passcode \(String(format: "%06u", c.passcode)) with the sender; your wallet inherited the link(s), which resolve when the sender's registration heals."
    }

    private var amountSignPrefix: String {
        switch row.txType {
        case "receive", "redeem", "genesis": return "+"
        case "send", "burn":                  return "−"
        default:                               return ""
        }
    }

    /// Total receiver-side service fee on this row. Non-zero only on
    /// inbound rows that pay validators under the cashier's-cheque model
    /// (redeem / genesis claim); 0 on send / heal / burn.
    private var totalFee: UInt64 {
        row.feeBreakdown.reduce(UInt64(0)) { $0 &+ $1.amount }
    }

    /// The figure that actually moved this wallet's balance — the number
    /// the headline must show. For an inbound row carrying receiver-pays
    /// fees (redeem, genesis claim), that's the NET credit (gross − fees),
    /// matching the wallet's balance delta and the detail sheet's "Net
    /// credited" line. Showing the gross face value there made the fees
    /// look like they vanished (e.g. a heal self-cheque redeem credited
    /// +0.00005 while the balance only rose by gross − delta/beta/kappa).
    /// Everything else (sends, the gross when there are no fees) is the
    /// face value unchanged.
    private var displayedAmount: UInt64 {
        let inbound = row.txType == "redeem"
            || row.txType == "receive"
            || row.txType == "genesis"
        if inbound && totalFee > 0 && row.amount > totalFee {
            return row.amount - totalFee
        }
        return row.amount
    }

    private var amountDisplay: String {
        // Heal is a wallet-internal recovery self-send (no
        // counterparty, no value transfer to display); rendering
        // "0.00 L$" reads as "zero money moved" which misleads.
        // Em dash signals "not applicable" instead.
        if row.txType == "heal" { return "—" }
        let l = isArk ? formatBalanceArk(displayedAmount) : formatBalance(displayedAmount)
        return "\(amountSignPrefix)\(l)"
    }

    private var amountColor: Color {
        switch row.txType {
        case "receive", "redeem", "genesis": return DesignTokens.statusCleanAccent
        case "burn":                          return DesignTokens.statusRejectedFg
        default:                              return DesignTokens.textPrimary
        }
    }
}

// =================================================================
// TxDetail / TxDetailSheet — per-transaction drill-in.
//
// Opened by tapping an Activity row. Renders only locally-held,
// SDK-exposed data for that one record: full txid, timestamp,
// counterparty, reference, the amount breakdown, the witnessing
// validator set (from `fee_breakdown`), and the FACT-chain /
// Nabla-confirmation status (derived from `listScarredLinks()` —
// a row whose txid is in the scar set has no Nabla confirmation).
// No network call; everything here is already on disk.
// =================================================================

struct TxDetail: Identifiable {
    var id: String { row.txid }
    let row: TxHistoryRow
}

private struct TxDetailSheet: View {
    let row: TxHistoryRow
    let isArk: Bool
    let walletName: String
    /// Lowercased txids of the wallet's currently-scarred FACT links.
    let scarTxids: Set<String>
    /// Consent-ledger match for this tx (YPX-001 §1.5.1), if any.
    let consent: ConsentLedgerRecord?
    /// Returns the FFI certificate result for this tx (ok + pdf, or ok=false +
    /// reason). The sheet itself drives the save panel + error display so
    /// feedback isn't swallowed behind the parent view.
    let exportCertificate: () -> SendCertificatePdfRow
    /// Returns the raw Send Proof bundle bytes (the verifiable object), or nil
    /// when this tx has no retained proof. Exported as a branded `.axproof` file.
    let exportProofBundle: () -> Data?
    let onClose: () -> Void

    /// Needed by the Recall lifecycle button (YPX-022): hibernation flag,
    /// convergence estimate, recall records, and the wallet FFI (txidStatus,
    /// retainedSendTxCbor, recall/recallComplete via RecallConfirmSheet).
    @EnvironmentObject private var session: AppSession

    /// Non-nil shows an export error alert.
    @State private var exportError: String? = nil

    // ── Recall lifecycle (YPX-022) ──────────────────────────────────
    // The retained send proof CBOR (recall argument); nil ⇒ no recall
    // target ⇒ the Recall button is hidden entirely. Loaded onAppear.
    @State private var retainedCbor: Data? = nil
    // The one-shot txid settlement enquiry (network, off-main). nil while
    // loading; stays nil (with `statusLoaded == true`) if unreachable.
    @State private var txStatus: TxidStatusRow? = nil
    @State private var statusLoaded: Bool = false
    // Non-nil presents the commit confirm (RecallConfirmSheet .reclaim).
    @State private var recallTarget: RecallTarget? = nil
    // Presents the finish confirm (RecallConfirmSheet .complete).
    @State private var showFinishRecall: Bool = false
    /// Set when a commit was refused TOO_EARLY. The button re-greys with a
    /// countdown until this moment — a corrected estimate anchored to the fresh
    /// failure time (eligible within one window-low of it) rather than the
    /// stale local send-time guess. Cleared once it passes.
    @State private var recallRetryAfter: Date? = nil

    private var isScarred: Bool { scarTxids.contains(row.txid.lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack {
                Text(headline).font(.title2.bold())
                Spacer()
                Button("Close", action: onClose)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    transactionSection
                    amountSection
                    if !row.feeBreakdown.isEmpty { witnessSection }
                    factStatusSection
                    exportRow
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(minWidth: 560, minHeight: 460)
        .alert("Export", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onAppear {
            // Only sends have a recall target; load the retained proof + kick
            // off the (network) settlement enquiry once.
            if row.txType == "send" {
                retainedCbor = session.activeWallet?.retainedSendTxCbor(txidHex: row.txid)
                fetchTxStatus()
            }
        }
        // Commit — retract the (unredeemed) payment (opens reservation + witnessed
        // recall + hibernate). RecallConfirmSheet drives the FFI, not this view.
        .sheet(item: $recallTarget) { t in
            RecallConfirmSheet(
                onCancel: { recallTarget = nil },
                onCompletion: {
                    recallTarget = nil
                    session.refreshHibernation()
                    fetchTxStatus()
                },
                onTooEarly: {
                    // The protocol's completion-tick gate hadn't opened. Anchor a
                    // corrected countdown to NOW: a too-early at now means the
                    // payment becomes eligible within one window-low of now, so
                    // re-grey until now + lowSecs (a tight, self-correcting
                    // estimate that supersedes the stale send-time guess).
                    recallRetryAfter = Date().addingTimeInterval(Double(recallWindow().lowSecs))
                },
                mode: .reclaim,
                target: t
            )
            .environmentObject(session)
        }
        // Finish — redeem the recall cheque (clears hibernation). No target.
        .sheet(isPresented: $showFinishRecall) {
            RecallConfirmSheet(
                onCancel: { showFinishRecall = false },
                onCompletion: {
                    showFinishRecall = false
                    session.refreshHibernation()
                    fetchTxStatus()
                },
                mode: .complete
            )
            .environmentObject(session)
        }
    }

    // ── Export row: ONE export. For a send, the certificate PDF is the single
    // all-in-one artifact — human-readable AND it embeds the verifiable proof
    // bundle, which the verify tools extract and Core re-checks. For other tx
    // types (no proof) it's a plain local record.
    private var exportRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            if row.txType == "send" {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button("Export proof (.axproof)…", action: saveProofBundle)
                        .buttonStyle(.borderedProminent)
                    Button("Certificate (PDF)…", action: saveCertificatePdf)
                        .buttonStyle(.bordered)
                    recallButton
                    Spacer()
                }
                Text("Two artifacts, the SAME verifiable proof. The .axproof is a small data file — best for bank / system intake that blocks inbound PDFs. The certificate (PDF) is the human-readable version and embeds the same bundle. The verifier accepts either.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            } else {
                Button("Export record (PDF)…", action: exportRecordPdf)
                    .buttonStyle(.borderedProminent)
                Text("A rendered statement of this wallet's local entry — an audit record, not a network-verified certificate (those exist only for sends, via the retained Send Proof).")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
    }

    // ── Export the raw proof bundle (.axproof — small, the verifiable object) ──
    private func saveProofBundle() {
        guard let data = exportProofBundle() else {
            exportError = "No retained Send Proof for this transaction — only sends made with proof retention have a verifiable bundle."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Send Proof bundle"
        panel.nameFieldStringValue = "axiom-\(row.txid.prefix(12)).axproof"
        if let t = UTType(filenameExtension: "axproof") { panel.allowedContentTypes = [t] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url) }
        catch { exportError = "Could not save the proof: \(error.localizedDescription)" }
    }

    // ── Export the cryptographic Send Proof certificate ─────────────
    // Runs in the sheet's own context: the save panel presents correctly and a
    // failure (no retained proof for this send) surfaces in the sheet's alert,
    // instead of setting a parent-view alert hidden behind this sheet.
    private func saveCertificatePdf() {
        let result = exportCertificate()
        guard result.ok else {
            exportError = result.reason
                ?? "No retained Send Proof for this transaction — only sends made with proof retention have a verifiable certificate."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Send Proof certificate"
        panel.nameFieldStringValue = "axiom-certificate-\(row.txid.prefix(12)).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try result.pdf.write(to: url) }
        catch { exportError = "Could not save the certificate: \(error.localizedDescription)" }
    }

    // ── Render the transaction record to a PDF document ─────────────
    private func exportRecordPdf() {
        let doc = TxRecordDocument(
            row: row, isArk: isArk, isScarred: isScarred, walletName: walletName
        )
        let renderer = ImageRenderer(content: doc)
        // A4 at 72 dpi (points). Lock the layout width so the document
        // is paginated-page-sized regardless of the on-screen sheet.
        renderer.proposedSize = ProposedViewSize(width: 595, height: 842)
        let panel = NSSavePanel()
        panel.title = "Export transaction record"
        panel.nameFieldStringValue = "axiom-record-\(row.txid.prefix(12)).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var ok = false
        renderer.render { size, renderInContext in
            var box = CGRect(x: 0, y: 0, width: max(size.width, 1), height: max(size.height, 1))
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            renderInContext(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
            ok = true
        }
        if !ok {
            exportError = "Could not render the record to PDF."
        }
    }

    // ── Transaction identity ────────────────────────────────────────
    private var transactionSection: some View {
        section("TRANSACTION") {
            kv("Type", prettyTxType(row.txType))
            kv("txid", row.txid, mono: true)
            kv("When", fullTimestamp)
            // YPX-001 §1.5.1 — the consent trail, both roles.
            if let c = consent {
                kv("Scar consent",
                   c.role == "sender"
                    ? "Paused by the validator (scarred provenance); completed after the receiver approved with passcode \(String(format: "%06u", c.passcode))."
                    : "You approved this scarred payment by sharing passcode \(String(format: "%06u", c.passcode)) with the sender.")
            }
            if !isSelfRecoveryTx(row.txType) && row.txType != "burn" {
                kv(row.txType == "send" ? "To" : "From", row.counterparty, mono: true)
            }
            if let ref = row.reference, !ref.isEmpty {
                kv("Reference", ref)
            }
        }
    }

    // ── Amount (gross / fees / net for redeem) ──────────────────────
    private var amountSection: some View {
        let totalFee = row.feeBreakdown.reduce(UInt64(0)) { $0 &+ $1.amount }
        let net = row.amount > totalFee ? row.amount - totalFee : row.amount
        return section("AMOUNT") {
            if row.txType == "heal" {
                Text("Wallet-internal recovery self-send — no counterparty value transfer.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textTertiary)
            } else {
                kv(totalFee > 0 ? "Gross" : "Amount",
                   "\(isArk ? formatBalanceArk(row.amount) : formatBalance(row.amount)) · \(isArk ? formatAxcOnlyArk(row.amount) : formatAxcOnly(row.amount))")
                if totalFee > 0 {
                    kv("Service charges", "−\(isArk ? formatAxcOnlyArk(totalFee) : formatAxcOnly(totalFee))")
                    kv("Net credited", "+\(isArk ? formatAxcOnlyArk(net) : formatAxcOnly(net))")
                }
            }
        }
    }

    // ── Witnessing validators ───────────────────────────────────────
    private var witnessSection: some View {
        let totalFee = row.feeBreakdown.reduce(UInt64(0)) { $0 &+ $1.amount }
        return section("WITNESSED BY \(row.feeBreakdown.count) VALIDATOR\(row.feeBreakdown.count == 1 ? "" : "S")") {
            ForEach(Array(row.feeBreakdown.enumerated()), id: \.offset) { _, fs in
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(fs.validatorName.isEmpty ? String(fs.validatorIdHex.prefix(12)) + "…" : fs.validatorName)
                        .font(DesignTokens.Typography.monoSmall)
                        .textSelection(.enabled)
                    if fs.isOverlapped {
                        Text("overlap")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(DesignTokens.statusCleanFg)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(DesignTokens.statusCleanBg)
                            .clipShape(Capsule())
                    }
                    Spacer()
                    if totalFee > 0 {
                        Text("−\(isArk ? formatAxcOnlyArk(fs.amount) : formatAxcOnly(fs.amount))")
                            .font(DesignTokens.Typography.amountCaption)
                            .foregroundStyle(DesignTokens.textSecondary)
                    }
                }
            }
            Text("These validator IDs are the k-witness set recorded on this transaction's receipt. Overlapped validators were carried from the prior round per the S-ABR requirement (YPX-007 §10).")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .padding(.top, 2)
        }
    }

    // ── FACT-chain / Nabla confirmation status ──────────────────────
    private var factStatusSection: some View {
        section("FACT CHAIN · NABLA") {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: isScarred ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(isScarred ? DesignTokens.statusScarredFg : DesignTokens.statusCleanFg)
                Text(isScarred ? "Scarred — no Nabla confirmation on this link yet" : "Confirmed — Nabla registration present")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(isScarred ? DesignTokens.statusScarredFg : DesignTokens.textSecondary)
            }
            if isScarred {
                Text("Heal from the Activity view registers a supplemental Nabla confirmation (or burns the link if it can't be resolved).")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
    }

    // ── small layout helpers ────────────────────────────────────────
    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.sm)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private func kv(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Text(k)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textTertiary)
                .frame(width: 110, alignment: .leading)
            Text(v)
                .font(mono ? DesignTokens.Typography.monoSmall : DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headline: String {
        switch row.txType {
        case "receive", "redeem": return "Received"
        case "send":              return "Sent"
        case "heal":              return "Heal"
        case "burn":              return "Burn"
        case "genesis":           return "Genesis claim"
        default:                  return row.txType.capitalized
        }
    }

    private var fullTimestamp: String {
        let d = Date(timeIntervalSince1970: TimeInterval(row.timestamp))
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d yyyy · HH:mm:ss"
        return f.string(from: d)
    }

    // =============================================================
    // Recall lifecycle button (YPX-022)
    //
    // ONE stateful button that drives the whole recall lifecycle by
    // changing its own label + enabled state. Only shown for a `send`
    // row that has a retained send proof (the recall argument). The
    // countdowns + the too-early→enabled transition update live inside
    // a per-second TimelineView; Nabla's gate stays the authority, the
    // wall-clock age is just for the display countdown.
    // =============================================================

    /// The per-tap presentation state of the Recall button.
    private enum RecallState {
        case checking                       // status enquiry in flight
        case unavailable                    // enquiry returned nothing
        case recalled                       // this txid was recalled (RETRACTED)
        case redeemed                       // receiver claimed it — can't recall
        case hibernating(secs: UInt64)      // committed, converging
        case finish                         // convergence passed — redeem cheque
        case tooEarly(secs: UInt64)         // window not open yet
        case windowClosed                   // aged past the window
        case recallable                     // in window, unclaimed — commit
    }

    @ViewBuilder
    private var recallButton: some View {
        // No retained proof ⇒ no recall target ⇒ hide the button entirely.
        if row.txType == "send", let cbor = retainedCbor {
            // Per-second tick so countdowns + the too-early→enabled flip are live.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let state = recallState(now: context.date)
                // Recall is the exception, not the norm. A send that simply
                // aged past the window without ever being recalled (the
                // EXPECTED majority), or that the receiver redeemed normally,
                // shows NO recall control at all — surfacing "Recall window
                // closed" on every old payment wrongly implies recall was
                // something everyone should have done. The button appears only
                // when recall is actually relevant: coming (tooEarly),
                // actionable (recallable), in progress (hibernating/finish), or
                // already done (recalled ✓).
                if recallVisible(state) {
                    HStack(spacing: DesignTokens.Spacing.xxs) {
                        Button(recallLabel(state)) {
                            switch state {
                            case .recallable: presentRecallCommit(cbor: cbor)
                            case .finish:     showFinishRecall = true
                            default:          break
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(!recallEnabled(state))
                        if case .checking = state {
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
            }
        }
    }

    private func recallState(now: Date) -> RecallState {
        // 1. A recall THIS wallet already committed takes priority (the
        // reservation may not have committed at Nabla yet). Cheap local read.
        let records = session.activeWallet?.recallRecords() ?? []
        if records.contains(where: { $0.recalledTxidHex == row.txid }) {
            // Still hibernating from this recall → it's IN PROGRESS: converging
            // (est>0) or ready to finish (est==0). recallComplete redeems the
            // recall cheque AND clears hibernation — so a recall record with the
            // wallet NO LONGER hibernating means the recall is FINISHED. Show the
            // terminal (greyed) "Recalled ✓", not another enabled "Finish Recall".
            if session.isHibernating {
                let est = session.hibernationConvergenceEstimateSecs()
                return est > 0 ? .hibernating(secs: est) : .finish
            }
            return .recalled
        }

        // 2. Redeemed / retracted — the ONLY recall fact that isn't knowable
        // locally: redeem-wins is the RECEIVER's action, so it can only come
        // from the network. Overlay it when the enquiry has told us; otherwise
        // fall through to the local estimate (the enquiry only REFINES, never
        // gates — the button is never stuck "checking").
        if let s = txStatus {
            if s.status == "REDEEMED" && s.claimStatus == "RETRACTED" { return .recalled }
            if s.status == "REDEEMED" { return .redeemed }
        }

        // 2b. Corrected countdown — if a prior commit was refused TOO_EARLY, a
        // fresh failure moment was captured (the payment becomes eligible within
        // one window-low of it). Honor that tighter estimate until it elapses;
        // it supersedes the stale send-time guess below.
        if let retry = recallRetryAfter, now < retry {
            return .tooEarly(secs: UInt64(max(0, retry.timeIntervalSince(now))))
        }

        // 3. Window state — ESTIMATED PURELY from the wallet's OWN send time +
        // the window constants. The wallet knows its tx time; no validator is
        // needed to decide too-early / in-window / window-closed.
        //
        // EXACT when we have it: the protocol measures age from the COMPLETION
        // TICK (nabla/src/smt.rs: age = current_tick − completion_tick), which
        // the enquiry now returns (TxidStatusRow.completionTick). When non-zero
        // gate on it directly — no lag buffer needed, the estimate matches the
        // protocol exactly. FALLBACK when it's 0 (enquiry not loaded yet, or the
        // completion isn't registered at the queried node): the local send-time
        // estimate + lag buffer, so the button still greys/counts down offline
        // and never enables before Nabla's gate would accept.
        let window = recallWindow()
        let nowSecs = UInt64(max(0, now.timeIntervalSince1970))
        if let ct = txStatus?.completionTick, ct > 0 {
            let age = nowSecs > ct ? nowSecs - ct : 0
            if age < window.lowSecs { return .tooEarly(secs: window.lowSecs - age) }
            if age > window.highSecs { return .windowClosed }
            return .recallable
        }
        let effectiveLow = window.lowSecs + recallLagBufferSecs
        let age = nowSecs > row.timestamp ? nowSecs - row.timestamp : 0
        if age < effectiveLow { return .tooEarly(secs: effectiveLow - age) }
        if age > window.highSecs { return .windowClosed }
        return .recallable
    }

    /// Conservative estimate of the send→completion-registration lag (witness
    /// round + gossip). Added to the recall window's low bound so the button
    /// never enables before Nabla's completion-tick-based gate would accept.
    /// Negligible against the prod window (18000s); meaningful against dev (10s).
    private let recallLagBufferSecs: UInt64 = 10

    private func recallLabel(_ s: RecallState) -> String {
        switch s {
        case .checking:            return "Recall"
        case .unavailable:         return "Status unavailable"
        case .recalled:            return "Recalled ✓"
        case .redeemed:            return "Redeemed — can't recall"
        case .hibernating(let t):  return "Hibernating · \(durationLabel(t))"
        case .finish:              return "Finish Recall"
        case .tooEarly(let t):     return "Recall in \(durationLabel(t))"
        case .windowClosed:        return "Recall window closed"
        case .recallable:          return "Recall"
        }
    }

    private func recallEnabled(_ s: RecallState) -> Bool {
        switch s {
        case .recallable, .finish: return true
        default:                   return false
        }
    }

    /// Whether to render the recall control at all. Hidden for the normal
    /// terminal outcomes — a payment that aged out of the window unrecalled
    /// (`.windowClosed`, the expected majority) or that the receiver redeemed
    /// (`.redeemed`) — so recall never reads as an expected step on ordinary
    /// sends. Shown only while recall is coming / actionable / in-progress /
    /// done.
    private func recallVisible(_ s: RecallState) -> Bool {
        switch s {
        case .windowClosed, .redeemed, .unavailable: return false
        default:                                      return true
        }
    }

    private func presentRecallCommit(cbor: Data) {
        recallTarget = RecallTarget(
            txidHex: row.txid,
            txCbor: cbor,
            summary: "\(formatAxcOnly(row.amount)) to \(row.counterparty) · sent \(recallDateLabel(row.timestamp))"
        )
    }

    /// One-shot settlement enquiry (network, off-main). Re-run after a commit /
    /// finish so the button advances to its next state.
    private func fetchTxStatus() {
        guard let wallet = session.activeWallet else { return }
        let txid = row.txid
        statusLoaded = false
        Task.detached {
            let s = wallet.txidStatus(txidHex: txid)
            await MainActor.run {
                txStatus = s
                statusLoaded = true
            }
        }
    }

    private func recallDateLabel(_ ts: UInt64) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Compact countdown label, e.g. "2m 05s", "45s", "1h 03m".
    private func durationLabel(_ secs: UInt64) -> String {
        if secs >= 3600 {
            let h = secs / 3600, m = (secs % 3600) / 60
            return "\(h)h \(String(format: "%02d", m))m"
        }
        if secs >= 60 {
            let m = secs / 60, s = secs % 60
            return "\(m)m \(String(format: "%02d", s))s"
        }
        return "\(secs)s"
    }
}

// =================================================================
// TxRecordDocument — print-styled (light) A4 layout rendered to PDF
// by ImageRenderer. Deliberately NOT theme-aware: a record/evidence
// document is black-on-white regardless of the app's dark chrome.
// Renders only locally-held facts; for a network-verifiable proof of
// a send, the Send Proof certificate is the cryptographic artifact.
// =================================================================
private struct TxRecordDocument: View {
    let row: TxHistoryRow
    let isArk: Bool
    let isScarred: Bool
    let walletName: String

    private let ink = Color.black
    private let dim = Color(white: 0.40)
    private let hair = Color(white: 0.82)
    private let panel = Color(white: 0.96)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Masthead
            VStack(alignment: .leading, spacing: 2) {
                Text("AXIOM — TRANSACTION RECORD")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(ink)
                Text("Wallet: \(walletName.isEmpty ? "—" : walletName)")
                    .font(.system(size: 11)).foregroundStyle(dim)
                Text("Generated \(generatedStamp)")
                    .font(.system(size: 10)).foregroundStyle(dim)
            }
            Rectangle().fill(hair).frame(height: 1)

            block("TRANSACTION") {
                kv("Type", prettyTxType(row.txType))
                kv("txid", row.txid, mono: true)
                kv("When", whenStamp)
                if !isSelfRecoveryTx(row.txType) && row.txType != "burn" {
                    kv(row.txType == "send" ? "To" : "From", row.counterparty, mono: true)
                }
                if let r = row.reference, !r.isEmpty { kv("Reference", r) }
            }

            block("AMOUNT") {
                let fee = row.feeBreakdown.reduce(UInt64(0)) { $0 &+ $1.amount }
                let net = row.amount > fee ? row.amount - fee : row.amount
                if row.txType == "heal" {
                    Text("Wallet-internal recovery self-send — no counterparty value transfer.")
                        .font(.system(size: 11)).foregroundStyle(dim)
                } else {
                    kv(fee > 0 ? "Gross" : "Amount",
                       "\(isArk ? formatBalanceArk(row.amount) : formatBalance(row.amount)) · \(isArk ? formatAxcOnlyArk(row.amount) : formatAxcOnly(row.amount))")
                    if fee > 0 {
                        kv("Service charges", "−\(isArk ? formatAxcOnlyArk(fee) : formatAxcOnly(fee))")
                        kv("Net credited", "+\(isArk ? formatAxcOnlyArk(net) : formatAxcOnly(net))")
                    }
                }
            }

            if !row.feeBreakdown.isEmpty {
                block("WITNESSED BY \(row.feeBreakdown.count) VALIDATOR\(row.feeBreakdown.count == 1 ? "" : "S")") {
                    let fee = row.feeBreakdown.reduce(UInt64(0)) { $0 &+ $1.amount }
                    ForEach(Array(row.feeBreakdown.enumerated()), id: \.offset) { _, fs in
                        HStack(spacing: 8) {
                            Text(fs.validatorName.isEmpty ? fs.validatorIdHex : "\(fs.validatorName)  (\(String(fs.validatorIdHex.prefix(16)))…)")
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(ink)
                            if fs.isOverlapped {
                                Text("overlap").font(.system(size: 8, weight: .semibold)).foregroundStyle(dim)
                            }
                            Spacer()
                            if fee > 0 {
                                Text("−\(isArk ? formatAxcOnlyArk(fs.amount) : formatAxcOnly(fs.amount))")
                                    .font(.system(size: 9)).foregroundStyle(dim)
                            }
                        }
                    }
                }
            }

            block("FACT CHAIN · NABLA") {
                Text(isScarred
                     ? "SCARRED — no Nabla confirmation on this link at time of export."
                     : "CONFIRMED — Nabla registration present on this link.")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(ink)
            }

            Spacer(minLength: 0)

            Rectangle().fill(hair).frame(height: 1)
            Text("This document is a rendered statement of an entry in this wallet's local transaction log. It is an audit record, not a network-verified certificate. For cryptographic proof of a send, export the Send Proof certificate, which embeds the retained proof bundle and re-verifies against the network's k-witness set.")
                .font(.system(size: 8)).foregroundStyle(dim).lineSpacing(1.5)
        }
        .padding(36)
        .frame(width: 595, height: 842, alignment: .topLeading)
        .background(Color.white)
    }

    @ViewBuilder
    private func block(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(dim)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(panel)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(hair, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func kv(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k).font(.system(size: 10)).foregroundStyle(dim).frame(width: 96, alignment: .leading)
            Text(v).font(.system(size: mono ? 9 : 10, design: mono ? .monospaced : .default))
                .foregroundStyle(ink).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var generatedStamp: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return f.string(from: Date())
    }
    private var whenStamp: String {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d yyyy · HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(row.timestamp)))
    }
}

// =================================================================
// Shared row labelling — the SINGLE source of truth for a history
// row's headline, used by BOTH the full Activity list and the
// Overview "recent activity" preview. They used to carry separate
// copies, which is how the airdrop label ended up in one and not the
// other; this extension makes the Overview a true (shorter) mirror of
// Activity for labelling purposes.
// =================================================================
extension TxHistoryRow {
    /// Counterparty's local-part (text before "@") for compact display.
    var counterpartyLocalPart: String {
        counterparty.split(separator: "@").first.map(String.init) ?? counterparty
    }

    /// The headline shown for this row in Activity and Overview.
    /// The genesis airdrop is a self-send redeem — label it "Airdrop",
    /// never "Received from <my own address>".
    var displayHeadline: String {
        if isGenesisAirdrop { return "Airdrop" }
        // A recall completion is a self-redeem of the recall cheque — labelling
        // it "Received from <self>" is misleading. It's the money coming back
        // from a payment YOU retracted. The origin detail (who it was sent to,
        // when, which txid) is filled in from the recall records at the row.
        if txType == "redeem", (reference ?? "").uppercased() == "RECALL" {
            return "Recalled payment · funds returned"
        }
        switch txType {
        case "receive", "redeem": return "Received from \(counterpartyLocalPart)"
        case "send":              return "Sent to \(counterpartyLocalPart)"
        case "heal":              return "Heal · self"
        case "hal_reanchor":      return "HAL re-anchor · self"
        case "burn":              return "Burn · scarred FACT link"
        case "genesis":           return "Genesis claim"
        default:                  return txType.capitalized
        }
    }
}
