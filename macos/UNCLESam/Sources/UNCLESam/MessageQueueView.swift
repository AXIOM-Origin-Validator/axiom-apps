import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AxiomSdk

// =================================================================
// MessageQueueView — the operator's default landing screen.
//
// Tabbed dense table:
//   Inbox                  → inbound messages from counterparties
//   Outbox                 → outbound, any non-pending status
//   Pending Authorization  → outbound awaiting checker (maker-checker
//                            gate)
//
// Rows are sortable + filterable. Clicking a row opens the
// MessageDetailSheet showing the full lifecycle + raw envelope
// blocks. The Pending Authorization tab adds an "Authorize" /
// "Reject" pair of buttons per row, gated by the maker-checker
// rule (checker cannot authorize their own message).
// =================================================================

enum QueueTab: String, CaseIterable, Identifiable {
    case inbox          = "Inbox"
    case outbox         = "Outbox"
    case pendingAuth    = "Pending Authorization"
    var id: String { rawValue }
}

struct MessageQueueView: View {
    @EnvironmentObject private var session: InstitutionSession
    @EnvironmentObject private var store: MessageStore

    @State private var tab: QueueTab = .pendingAuth
    @State private var filter: String = ""
    @State private var selectedId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            sectionHeader
            tabStrip
            filterBar
            Divider()
            messageTable
        }
        .sheet(item: Binding(
            get: { selectedId.flatMap { store.record($0) } },
            set: { _ in selectedId = nil }
        )) { rec in
            MessageDetailSheet(record: rec) { selectedId = nil }
                .environmentObject(session)
                .environmentObject(store)
        }
    }

    // ── Header ───────────────────────────────────────────────

    private var sectionHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MESSAGE QUEUE")
                    .font(DesignTokens.labelFont)
                    .tracking(0.6)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Inbound + outbound payment messages")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            Spacer()
            // Counter summary — banker scan-friendly
            HStack(spacing: 18) {
                queueStat(label: "PENDING AUTH",
                          value: "\(store.pendingAuthorization().count)",
                          tone: .amber)
                queueStat(label: "INBOX",
                          value: "\(store.inbound().count)",
                          tone: .info)
                queueStat(label: "OUTBOX",
                          value: "\(store.outbound().count)",
                          tone: .neutral)
            }
        }
        .padding(EdgeInsets(top: 22, leading: 28, bottom: 14, trailing: 28))
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            ForEach(QueueTab.allCases) { t in
                Button(action: { tab = t }) {
                    HStack(spacing: 8) {
                        Text(t.rawValue)
                            .font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                        Text("\(count(for: t))")
                            .font(DesignTokens.monoSmallFont)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tab == t
                                        ? DesignTokens.brandGold.opacity(0.18)
                                        : DesignTokens.bgTertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .foregroundStyle(tab == t
                                     ? DesignTokens.textPrimary
                                     : DesignTokens.textSecondary)
                    .padding(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(tab == t
                                  ? DesignTokens.brandGold
                                  : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.leading, 16)
        .background(DesignTokens.bgSecondary)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textTertiary)
            TextField("Filter by reference, counterparty, or BIC", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            Spacer()
        }
        .padding(EdgeInsets(top: 10, leading: 24, bottom: 10, trailing: 24))
    }

    // ── Table ────────────────────────────────────────────────

    /// Total intrinsic width of the table — sum of every column
    /// + horizontal padding. Used as `minWidth` on the inner
    /// VStack so the dual-axis ScrollView never collapses cells
    /// below their declared sizes (the bug: previously only the
    /// trailing column shrank because of `Spacer(minLength: 0)`,
    /// pushing it to zero width).
    static let queueColumnsBaseWidth: CGFloat =
        180 + 70 + 130 + 50 + 180 + 180 + 120 + 140       // 8 cols
        + 48                                              // 24pt × 2 padding
    /// Auth-actions column width — only present on the Pending
    /// Authorization tab. Sized to fit Reject + Authorize +
    /// optional "(own — needs other checker)" label without wrap.
    static let queueAuthActionsWidth: CGFloat = 260

    private var messageTable: some View {
        // Dual-axis ScrollView wrapped in a GeometryReader so the
        // inner table content can be sized to AT LEAST the viewport
        // dimensions. Without that, ScrollView centres content
        // smaller than the viewport — pushing the table to the
        // middle of its space both vertically and horizontally.
        // With the GeometryReader sizing trick:
        //   • If the window is wider than the table's intrinsic
        //     min width, the table fills the viewport width and
        //     anchors to .topLeading.
        //   • If narrower, the table stays at its intrinsic
        //     width and the horizontal scroll bar engages.
        //   • Vertical: same idea — content fills the viewport
        //     height, so few-row tables sit at the top instead of
        //     floating in the middle.
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    tableHeader
                    Divider()
                    ForEach(visibleRows) { rec in
                        MessageRow(record: rec,
                                   showAuthActions: tab == .pendingAuth,
                                   selected: selectedId == rec.id) {
                            selectedId = rec.id
                        }
                        Divider().opacity(0.4)
                    }
                    if visibleRows.isEmpty {
                        emptyState
                            .frame(width: tableMinWidth)
                    }
                }
                .frame(minWidth: max(tableMinWidth, geo.size.width),
                       minHeight: geo.size.height,
                       alignment: .topLeading)
            }
            .background(DesignTokens.bgPrimary)
        }
    }

    /// Intrinsic table width — base columns + auth column when
    /// the current tab includes it. The VStack uses this as its
    /// minWidth so SwiftUI doesn't try to squeeze columns below
    /// their declared sizes.
    private var tableMinWidth: CGFloat {
        MessageQueueView.queueColumnsBaseWidth
        + (tab == .pendingAuth
           ? MessageQueueView.queueAuthActionsWidth
           : 0)
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            tableHeaderCell("REFERENCE",       width: 180, align: .leading)
            tableHeaderCell("TYPE",            width: 70,  align: .leading)
            tableHeaderCell("AMOUNT",          width: 130, align: .trailing)
            tableHeaderCell("CCY",             width: 50,  align: .leading)
            tableHeaderCell("ORDERING",        width: 180, align: .leading)
            tableHeaderCell("BENEFICIARY",     width: 180, align: .leading)
            tableHeaderCell("STATUS",          width: 120, align: .leading)
            tableHeaderCell("LAST TOUCHED",    width: 140, align: .leading)
            if tab == .pendingAuth {
                tableHeaderCell("AUTHORIZATION",
                                width: MessageQueueView.queueAuthActionsWidth,
                                align: .leading)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(minWidth: tableMinWidth, alignment: .leading)
        .background(DesignTokens.bgTertiary)
    }

    private func tableHeaderCell(_ title: String, width: CGFloat,
                                 align: HorizontalAlignment) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(DesignTokens.textTertiary)
            .frame(width: width, alignment: align == .leading ? .leading : .trailing)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 24))
                .foregroundStyle(DesignTokens.textTertiary)
            Text("No messages match the current filter")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // ── Filtering / counts ───────────────────────────────────

    private var visibleRows: [MessageRecord] {
        let pool: [MessageRecord]
        switch tab {
        case .inbox:        pool = store.inbound()
        case .outbox:       pool = store.outbound()
        case .pendingAuth:  pool = store.pendingAuthorization()
        }
        if filter.isEmpty { return pool }
        let q = filter.lowercased()
        return pool.filter {
            $0.reference.lowercased().contains(q)
            || $0.orderingCustomerName.lowercased().contains(q)
            || $0.beneficiaryName.lowercased().contains(q)
            || $0.beneficiaryBIC.lowercased().contains(q)
        }
    }

    private func count(for t: QueueTab) -> Int {
        switch t {
        case .inbox:        return store.inbound().count
        case .outbox:       return store.outbound().count
        case .pendingAuth:  return store.pendingAuthorization().count
        }
    }

    private enum QueueStatTone {
        case amber, info, neutral
    }
    private func queueStat(label: String, value: String, tone: QueueStatTone) -> some View {
        let color: Color = {
            switch tone {
            case .amber:   return DesignTokens.statusPendingFg
            case .info:    return DesignTokens.statusInfoFg
            case .neutral: return DesignTokens.textSecondary
            }
        }()
        return VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(DesignTokens.textTertiary)
        }
    }
}

// =================================================================
// MessageRow — one dense, scannable line. Tight row height (28pt) +
// monospace for reference / BIC keeps a banker-familiar visual
// density. Pending Authorization tab adds inline Authorize/Reject.
// =================================================================

struct MessageRow: View {
    let record: MessageRecord
    let showAuthActions: Bool
    let selected: Bool
    let onTap: () -> Void

    @EnvironmentObject private var session: InstitutionSession
    @EnvironmentObject private var store: MessageStore

    @State private var confirmAuthorize = false
    @State private var confirmReject = false
    @State private var rejectNote: String = ""
    @State private var confirmPostCredit = false

    /// Show inline Post Credit action — true for inbound .received
    /// rows (cheques arrived via PullCheques but the operator hasn't
    /// explicitly posted them to the bank's ledger yet). Transitions
    /// the record to .ack with a lifecycle event recording the
    /// destination account.
    private var canPostCredit: Bool {
        record.direction == .inbound && record.status == .received
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(record.reference)
                .font(DesignTokens.monoSmallFont)
                .foregroundStyle(DesignTokens.textPrimary)
                .frame(width: 180, alignment: .leading)
            Text(record.format.display)
                .font(DesignTokens.monoSmallFont)
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(width: 70, alignment: .leading)
            Text(record.settlementAmount)
                .font(DesignTokens.monoFont)
                .foregroundStyle(DesignTokens.textPrimary)
                .frame(width: 130, alignment: .trailing)
            Text(record.settlementCurrency)
                .font(DesignTokens.monoSmallFont)
                .foregroundStyle(DesignTokens.textSecondary)
                .padding(.leading, 8)
                .frame(width: 50, alignment: .leading)
            Text(record.orderingCustomerName)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)
            Text(record.beneficiaryName)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)
            StatusPill(status: record.status)
                .frame(width: 120, alignment: .leading)
            Text(timestampDisplay(record.lastTouched))
                .font(DesignTokens.monoSmallFont)
                .foregroundStyle(DesignTokens.textTertiary)
                .frame(width: 140, alignment: .leading)
            if showAuthActions {
                authActions
                    .frame(width: MessageQueueView.queueAuthActionsWidth,
                           alignment: .leading)
            } else if canPostCredit {
                Button("Post credit") {
                    confirmPostCredit = true
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.statusSettledFg)
                .controlSize(.small)
                .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .background(selected
                    ? DesignTokens.brandNavySoft
                    : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .alert("Authorize message?", isPresented: $confirmAuthorize) {
            Button("Cancel", role: .cancel) {}
            // Affirmative, not destructive — authorize is the
            // happy-path action; only Reject reads destructive.
            Button("Authorize") {
                _ = store.authorize(record.id, by: session.operatorName)
            }
        } message: {
            Text("""
            Reference \(record.reference) — \(record.settlementCurrency) \(record.settlementAmount) to \(record.beneficiaryName).

            Sanctions pre-flight: \(record.sanctionsResult.rawValue) — \(record.sanctionsResult.rationale)

            Authorizing releases the AXIOM TX (irreversible after ~3 min) and hands the SWIFT envelope to the UNCLE gateway.
            """)
        }
        .alert("Reject message?", isPresented: $confirmReject) {
            TextField("Reason (optional)", text: $rejectNote)
            Button("Cancel", role: .cancel) {}
            Button("Reject", role: .destructive) {
                _ = store.reject(record.id, by: session.operatorName,
                                 note: rejectNote.isEmpty ? nil : rejectNote)
                rejectNote = ""
            }
        } message: {
            Text("Reference \(record.reference). The maker can revise and resubmit.")
        }
        .alert("Post credit to bank ledger?", isPresented: $confirmPostCredit) {
            Button("Cancel", role: .cancel) {}
            Button("Post credit") {
                let accountLabel = session.activeAccount?.config.displayName ?? "ledger"
                _ = store.postCredit(record.id,
                                      toAccount: accountLabel,
                                      by: session.operatorName)
            }
        } message: {
            Text("""
            Reference \(record.reference) — \(record.settlementCurrency) \(record.settlementAmount) from \(record.orderingCustomerName).

            Posting credit transitions this cheque from received to settled in UNCLE SAM's audit trail. The pending credit chip in Settings → Institution accounts will drop by the matching amount.

            In a production deployment this would also drive the receiver wallet's redeem flow to move the value on-chain. The demo records the lifecycle event without the SDK call.
            """)
        }
    }

    @ViewBuilder
    private var authActions: some View {
        let isOwn = record.createdBy == session.operatorName
        HStack(spacing: 6) {
            Button("Reject") {
                if !isOwn { confirmReject = true }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isOwn)
            Button("Authorize") {
                if !isOwn { confirmAuthorize = true }
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.brandNavy)
            .controlSize(.small)
            .disabled(isOwn)
            if isOwn {
                Text("(own — needs other checker)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.statusPendingFg)
                    .padding(.leading, 4)
            }
        }
        .padding(.leading, 12)
    }
}

// =================================================================
// StatusPill — colour-coded banker-conservative label.
// =================================================================

struct StatusPill: View {
    let status: MessageStatus

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var label: String {
        switch status {
        case .draft:                return "DRAFT"
        case .pendingAuthorization: return "PENDING AUTH"
        case .authorized:           return "AUTHORIZED"
        case .sent:                 return "SENT"
        case .ack:                  return "ACK"
        case .nack:                 return "NACK"
        case .rejected:             return "REJECTED"
        case .received:             return "RECEIVED"
        }
    }
    private var fg: Color {
        switch status {
        case .ack, .received:       return DesignTokens.statusSettledFg
        case .pendingAuthorization,
             .authorized,
             .sent,
             .draft:                return DesignTokens.statusPendingFg
        case .nack, .rejected:      return DesignTokens.statusRejectedFg
        }
    }
    private var bg: Color {
        switch status {
        case .ack, .received:       return DesignTokens.statusSettledBg
        case .pendingAuthorization,
             .authorized,
             .sent,
             .draft:                return DesignTokens.statusPendingBg
        case .nack, .rejected:      return DesignTokens.statusRejectedBg
        }
    }
}

// =================================================================
// MessageDetailSheet — clicked row → full lifecycle + raw envelope.
//
// Two panes:
//   Top    → lifecycle table (every state change: timestamp, actor,
//            event, note). The regulator audit trail.
//   Bottom → raw envelope body in monospace (FIN blocks for MT103,
//            XML for pacs.008). Selectable so the operator can copy
//            chunks if the receiver bank asks.
// =================================================================

struct MessageDetailSheet: View {
    let record: MessageRecord
    let onDone: () -> Void

    @EnvironmentObject private var session: InstitutionSession
    @EnvironmentObject private var store: MessageStore

    /// Non-nil shows a certified-slip export error.
    @State private var exportError: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            headerStrip
            Divider()
            // HStack (not HSplitView): on macOS HSplitView floats up inside a
            // VStack and overlaps the header strip above it. Fixed-width panes
            // don't need draggable splitters, so a plain HStack + Dividers lays
            // out cleanly below the header.
            HStack(spacing: 0) {
                lifecyclePane
                    .frame(minWidth: 320, idealWidth: 360, maxHeight: .infinity)
                Divider()
                axiomAnchorPane
                    .frame(minWidth: 280, idealWidth: 320, maxHeight: .infinity)
                Divider()
                envelopePane
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 1080, minHeight: 560)
    }

    /// AXIOM anchor panel — parallel to the SWIFT envelope, shows
    /// the rail-side state (txid, witnesses, FACT depth, Nabla
    /// notarisation). This is the dual-record model surfaced to
    /// the operator: same TX, two views.
    private var axiomAnchorPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("AXIOM ANCHOR")
                    .font(DesignTokens.labelFont)
                    .tracking(0.6)
                    .foregroundStyle(DesignTokens.textTertiary)
                AxiomAnchorTag()
            }
            .padding(EdgeInsets(top: 16, leading: 22, bottom: 10, trailing: 22))

            VStack(alignment: .leading, spacing: 14) {
                anchorRow(label: "TXID", value: record.axiomTxid ?? "(pending submit)",
                          mono: true, truncate: true,
                          help: "AXIOM transaction id — BLAKE3 over the signed TX. The wallet's UETR equivalent.")
                anchorRow(label: "WITNESSES",
                          value: "\(record.witnessCount) / \(record.requiredK)",
                          mono: true, truncate: false,
                          help: "Validator witness signatures collected vs required k-quorum.")
                anchorRow(label: "FACT CHAIN DEPTH",
                          value: "\(record.factChainDepth)",
                          mono: true, truncate: false,
                          help: "Append-only proof chain length after this TX.")
                anchorRow(label: "NABLA MESH",
                          value: record.nablaConfirmed ? "CONFIRMED" : "PENDING",
                          mono: true, truncate: false,
                          help: "Mesh-level txid notarisation across the Nabla network.",
                          valueColor: record.nablaConfirmed
                            ? DesignTokens.statusSettledFg
                            : DesignTokens.statusPendingFg)
                Divider()
                anchorRow(label: "SANCTIONS PRE-FLIGHT",
                          value: record.sanctionsResult.rawValue,
                          mono: true, truncate: false,
                          help: record.sanctionsResult.rationale,
                          valueColor: record.sanctionsResult.fg)
                Divider()
                Text("UNCLE SAM emits this AXIOM anchor in parallel to the SWIFT envelope. Both records describe the same transaction; the AXIOM side carries cryptographic finality (~3 min), the SWIFT side carries the bank's existing-pipeline metadata.")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let txid = record.axiomTxid {
                    Divider()
                    certifiedSlip(txid: txid)
                }
            }
            .padding(EdgeInsets(top: 0, leading: 22, bottom: 22, trailing: 22))
            Spacer()
        }
        .background(DesignTokens.bgSecondary)
    }

    /// Certified-slip export — the cryptographic TT slip for this payment.
    @ViewBuilder
    private func certifiedSlip(txid: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CERTIFIED SLIP")
                .font(DesignTokens.labelFont).tracking(0.6)
                .foregroundStyle(DesignTokens.textTertiary)
            HStack(spacing: 8) {
                Button("Export proof (.axproof)…") { exportProof(txid: txid) }
                Button("Certificate (PDF)…") { exportCertificate(txid: txid) }
            }
            Text("Core-verifiable evidence of this payment. Hand the .axproof (small data file, intake-friendly) to the counterparty, or the certificate PDF for filing. Either re-verifies through Core via UNCLE SAM → Verify Send Proof.")
                .font(.system(size: 10)).foregroundStyle(DesignTokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let e = exportError {
                Text(e).font(.system(size: 10)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The proof lives in the SENDING account's wallet dir; find the open account
    /// whose wallet holds it.
    private func proofBytes(for txid: String) -> Data? {
        for acct in session.accounts {
            if let w = acct.wallet, let d = try? w.exportSendProofCbor(txidHex: txid) {
                return d
            }
        }
        return nil
    }

    private func exportProof(txid: String) {
        exportError = nil
        guard let data = proofBytes(for: txid) else {
            exportError = "No retained proof for this payment — it predates proof retention, or was sent from another device/account."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export certified slip (.axproof)"
        panel.nameFieldStringValue = "axiom-slip-\(txid.prefix(12)).axproof"
        if let t = UTType(filenameExtension: "axproof") { panel.allowedContentTypes = [t] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url) }
        catch { exportError = "Could not save: \(error.localizedDescription)" }
    }

    private func exportCertificate(txid: String) {
        exportError = nil
        var row: SendCertificatePdfRow? = nil
        for acct in session.accounts {
            guard let w = acct.wallet else { continue }
            let r = w.exportSendCertificatePdf(txidHex: txid)
            if r.ok { row = r; break }
            if row == nil { row = r }   // remember a reason if none succeeds
        }
        guard let r = row, r.ok else {
            exportError = row?.reason ?? "No certificate available for this payment."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save certified slip (PDF)"
        panel.nameFieldStringValue = "axiom-slip-\(txid.prefix(12)).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try r.pdf.write(to: url) }
        catch { exportError = "Could not save: \(error.localizedDescription)" }
    }

    @ViewBuilder
    private func anchorRow(label: String, value: String,
                           mono: Bool, truncate: Bool,
                           help: String,
                           valueColor: Color = DesignTokens.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(DesignTokens.textTertiary)
                .help(help)
            Text(value)
                .font(mono ? DesignTokens.monoSmallFont : .system(size: 12))
                .foregroundStyle(valueColor)
                .lineLimit(truncate ? 2 : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var headerStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(record.reference)
                            .font(DesignTokens.monoFont)
                            .foregroundStyle(DesignTokens.textPrimary)
                        StatusPill(status: record.status)
                        SanctionsChip(result: record.sanctionsResult)
                    }
                    Text("\(record.format.display) · \(record.direction == .outbound ? "Outbound" : "Inbound") · created by \(record.createdBy)")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(record.settlementAmount) \(record.settlementCurrency)")
                        .font(DesignTokens.amountFont)
                        .foregroundStyle(DesignTokens.textPrimary)
                    Text("SWIFT value date \(dateOnly(record.valueDate))")
                        .font(DesignTokens.monoSmallFont)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
            }
            // Inline reconciliation line — only shows when the
            // submit captured a meaningful breakdown (e.g. there
            // were charges or an FX rate). Same line shape as the
            // composer for visual continuity.
            if let line = record.reconciliationLine {
                HStack(spacing: 6) {
                    Image(systemName: record.reconciliationBalanced
                          ? "checkmark.seal"
                          : "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(record.reconciliationBalanced
                                         ? DesignTokens.statusSettledFg
                                         : DesignTokens.statusPendingFg)
                    Text(line)
                        .font(DesignTokens.monoSmallFont)
                        .foregroundStyle(record.reconciliationBalanced
                                         ? DesignTokens.statusSettledFg
                                         : DesignTokens.statusPendingFg)
                    Spacer()
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(record.reconciliationBalanced
                            ? DesignTokens.statusSettledBg
                            : DesignTokens.statusPendingBg)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(EdgeInsets(top: 16, leading: 22, bottom: 14, trailing: 22))
        .background(DesignTokens.bgSecondary)
    }

    private var lifecyclePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("AUDIT TRAIL")
                .font(DesignTokens.labelFont)
                .tracking(0.6)
                .foregroundStyle(DesignTokens.textTertiary)
                .padding(EdgeInsets(top: 16, leading: 22, bottom: 10, trailing: 22))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(record.lifecycle) { evt in
                        lifecycleEntry(evt)
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 22, bottom: 22, trailing: 22))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func lifecycleEntry(_ evt: LifecycleEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(eventTone(evt.kind))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(eventLabel(evt.kind))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Text("\(timestampDisplay(evt.timestamp)) · \(evt.actor)")
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textTertiary)
                if let note = evt.note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var envelopePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(record.format == .pacs008
                     ? "PACS.008 ENVELOPE (ISO 20022 XML)"
                     : "MT103 ENVELOPE (SWIFT FIN BLOCKS)")
                    .font(DesignTokens.labelFont)
                    .tracking(0.6)
                    .foregroundStyle(DesignTokens.textTertiary)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(record.envelopeBody, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(EdgeInsets(top: 16, leading: 22, bottom: 10, trailing: 22))
            ScrollView {
                Text(record.envelopeBody)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 0, leading: 22, bottom: 22, trailing: 22))
            }
        }
        .background(DesignTokens.bgPrimary)
    }

    private var footer: some View {
        HStack {
            Text("Audit trail is append-only — retained per regulatory minimum (7 years).")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textTertiary)
            Spacer()
            Button("Close", action: onDone)
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandNavy)
                .controlSize(.regular)
        }
        .padding(EdgeInsets(top: 12, leading: 22, bottom: 14, trailing: 22))
    }

    private func eventLabel(_ kind: LifecycleEvent.Kind) -> String {
        switch kind {
        case .created:                  return "Created (draft)"
        case .submittedForAuthorization: return "Submitted for authorization"
        case .sanctionsScreened:        return "Sanctions / OFAC pre-flight"
        case .authorized:               return "Authorized by checker"
        case .rejected:                 return "Rejected by checker"
        case .sentToGateway:            return "Sent to UNCLE gateway"
        case .ackReceived:              return "ACK received"
        case .nackReceived:             return "NACK received"
        case .axiomWitnessQuorum:       return "AXIOM k-witness quorum"
        case .nablaConfirmed:           return "Nabla mesh notarisation"
        case .received:                 return "Received from gateway"
        }
    }
    private func eventTone(_ kind: LifecycleEvent.Kind) -> Color {
        switch kind {
        case .ackReceived, .received, .nablaConfirmed:
            return DesignTokens.statusSettledFg
        case .nackReceived, .rejected:
            return DesignTokens.statusRejectedFg
        case .authorized, .sentToGateway, .axiomWitnessQuorum:
            return DesignTokens.brandNavy
        default:
            return DesignTokens.statusPendingFg
        }
    }
}

// =================================================================
// Shared helpers — date / time display.
// =================================================================

func timestampDisplay(_ d: Date) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "MM-dd HH:mm:ss"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    return fmt.string(from: d)
}

func dateOnly(_ d: Date) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.locale = Locale(identifier: "en_US_POSIX")
    return fmt.string(from: d)
}
