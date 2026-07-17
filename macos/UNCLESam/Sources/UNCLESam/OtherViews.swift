import SwiftUI

// =================================================================
// Remaining top-level sections — Inbound, Audit, Counterparties,
// Settings. Each is a solid placeholder that conveys the intended
// information density + visual posture without requiring backend
// integration.
//
// Inbound and Audit are mostly tables (reusing the styling from
// DashboardView's recent-wires table). Counterparties is an address
// book of BICs. Settings collects institution profile + UNCLE
// endpoint config + key management placeholders.
// =================================================================

/// Outcome of an account `.axpw` export, surfaced via an alert in
/// the Settings accounts card.
struct AccountExportResult {
    let ok: Bool
    let message: String
}

// ── Inbound ───────────────────────────────────────────────────────

struct InboundView: View {
    @EnvironmentObject private var store: MessageStore
    @State private var selectedId: UUID? = nil

    private var inboundRows: [MessageRecord] { store.inbound() }

    var body: some View {
        VStack(spacing: 0) {
            sectionHeader
            HSplitView {
                inboundList
                    .frame(minWidth: 380, idealWidth: 460)
                detailPane
                    .frame(minWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sectionHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("INBOUND")
                    .font(DesignTokens.labelFont)
                    .tracking(0.6)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Incoming wires from counterparty banks")
                    .font(.system(size: 20, weight: .medium))
            }
            Spacer()
            Button {
                // Stub: would trigger a UNCLE pull from the
                // configured endpoint.
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("Pull from UNCLE")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(EdgeInsets(top: 22, leading: 28, bottom: 18, trailing: 28))
    }

    private var inboundList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(inboundRows) { row in
                    Button { selectedId = row.id } label: {
                        inboundRow(row, isSelected: row.id == selectedId)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                if inboundRows.isEmpty {
                    Text("No inbound messages")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
            }
        }
        .background(DesignTokens.bgSecondary)
    }

    private func inboundRow(_ r: MessageRecord, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(r.reference)
                    .font(DesignTokens.monoFont)
                Spacer()
                Text("\(r.settlementAmount) \(r.settlementCurrency)")
                    .font(DesignTokens.amountFont)
            }
            HStack {
                Text(r.orderingCustomerName)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(timestampDisplay(r.lastTouched))
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            HStack(spacing: 6) {
                Text(r.beneficiaryBIC)
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textTertiary)
                StatusPill(status: r.status)
                SanctionsChip(result: r.sanctionsResult)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? DesignTokens.brandNavySoft : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(DesignTokens.brandGold)
                    .frame(width: 3)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let id = selectedId, let row = store.record(id) {
            inboundDetail(row)
        } else {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "envelope.open")
                    .font(.system(size: 32))
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Select an inbound message to view its envelope")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignTokens.bgSecondary)
        }
    }

    private func inboundDetail(_ r: MessageRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("INBOUND DETAIL")
                        .font(DesignTokens.labelFont)
                        .tracking(0.6)
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text(r.reference)
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                }
                Divider()
                detailRow(label: "From", value: r.orderingCustomerName)
                detailRow(label: "BIC",  value: r.beneficiaryBIC, mono: true)
                detailRow(label: "Amount", value: "\(r.settlementAmount) \(r.settlementCurrency)", mono: true)
                detailRow(label: "Status", value: r.status.rawValue.uppercased())
                detailRow(label: "AXIOM txid",
                          value: r.axiomTxid ?? "(none)", mono: true)
                detailRow(label: "Nabla confirmed",
                          value: r.nablaConfirmed ? "YES" : "NO", mono: true)
                detailRow(label: "Sanctions",
                          value: r.sanctionsResult.rawValue, mono: true)
                Divider()
                Text(r.format == .pacs008
                     ? "PACS.008 ENVELOPE (ISO 20022 XML)"
                     : "MT103 ENVELOPE (SWIFT FIN BLOCKS)")
                    .font(DesignTokens.labelFont)
                    .tracking(0.5)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(r.envelopeBody)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(DesignTokens.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }
            .padding(EdgeInsets(top: 20, leading: 24, bottom: 24, trailing: 24))
        }
    }

    private func detailRow(label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textTertiary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(mono ? DesignTokens.monoFont : .system(size: 12))
                .textSelection(.enabled)
            Spacer()
        }
    }
}

// ── Audit Log ─────────────────────────────────────────────────────

struct AuditView: View {
    @EnvironmentObject private var store: MessageStore
    @State private var search: String = ""
    @State private var confirmExport: Bool = false
    @State private var exportFormat: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Filter by reference / counterparty / BIC", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 360)
                    Spacer()
                    Menu {
                        Button("CSV (all columns)") { promptExport("CSV") }
                        Button("MT940 (account statement)") { promptExport("MT940") }
                        Button("MT900 (debit confirmation)") { promptExport("MT900") }
                        Button("camt.053 / ISO 20022 XML") { promptExport("camt.053") }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export")
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(DesignTokens.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(DesignTokens.borderPrimary, lineWidth: 0.5)
                    )
                }
                auditTable
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 22, leading: 28, bottom: 28, trailing: 28))
        .alert("Generate \(exportFormat) export?", isPresented: $confirmExport) {
            Button("Cancel", role: .cancel) {}
            Button("Export") {
                // Real impl would write to disk + audit-log the
                // export event. Demo stub.
            }
        } message: {
            Text("This would produce a \(exportFormat) file covering all \(filteredRows.count) messages currently visible. Regulator-grade export — every audit log access is itself logged.")
        }
    }

    private func promptExport(_ format: String) {
        exportFormat = format
        confirmExport = true
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AUDIT LOG")
                .font(DesignTokens.labelFont)
                .tracking(0.6)
                .foregroundStyle(DesignTokens.textTertiary)
            Text("Full audit-grade transaction history (7+ year retention)")
                .font(.system(size: 20, weight: .medium))
        }
    }

    private var filteredRows: [MessageRecord] {
        if search.isEmpty { return store.messages }
        let q = search.lowercased()
        return store.messages.filter {
            $0.reference.lowercased().contains(q)
            || $0.orderingCustomerName.lowercased().contains(q)
            || $0.beneficiaryName.lowercased().contains(q)
            || $0.beneficiaryBIC.lowercased().contains(q)
        }
    }

    private var auditTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("LAST TOUCHED").frame(width: 130, alignment: .leading)
                Text("DIR")          .frame(width: 50,  alignment: .leading)
                Text("REFERENCE")    .frame(width: 170, alignment: .leading)
                Text("COUNTERPARTY") .frame(maxWidth: .infinity, alignment: .leading)
                Text("AMOUNT")       .frame(width: 140, alignment: .trailing)
                Text("TXID")         .frame(width: 110, alignment: .leading)
                Text("SCRN")         .frame(width: 80,  alignment: .leading)
                Text("STATUS")       .frame(width: 110, alignment: .leading)
            }
            .font(DesignTokens.labelFont)
            .tracking(0.4)
            .foregroundStyle(DesignTokens.textTertiary)
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))
            .background(DesignTokens.bgTertiary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filteredRows) { rec in
                        auditRow(rec)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(DesignTokens.borderSecondary, lineWidth: 0.5)
        )
    }

    private func auditRow(_ r: MessageRecord) -> some View {
        HStack(spacing: 0) {
            Text(timestampDisplay(r.lastTouched))
                .font(DesignTokens.monoSmallFont)
                .frame(width: 130, alignment: .leading)
            Text(r.direction == .outbound ? "OUT" : "IN")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(r.direction == .outbound
                                 ? DesignTokens.brandNavy
                                 : DesignTokens.statusSettledFg)
                .frame(width: 50, alignment: .leading)
            Text(r.reference)
                .font(DesignTokens.monoFont)
                .frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.direction == .outbound
                     ? r.beneficiaryName
                     : r.orderingCustomerName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(r.beneficiaryBIC)
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(r.settlementAmount) \(r.settlementCurrency)")
                .font(DesignTokens.amountFont)
                .frame(width: 140, alignment: .trailing)
            Text(r.axiomTxid.map { String($0.prefix(8)) + "…" } ?? "—")
                .font(DesignTokens.monoSmallFont)
                .foregroundStyle(DesignTokens.textTertiary)
                .frame(width: 110, alignment: .leading)
            SanctionsChip(result: r.sanctionsResult)
                .frame(width: 80, alignment: .leading)
            StatusPill(status: r.status)
                .frame(width: 110, alignment: .leading)
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
    }
}

// ── Counterparty Banks ────────────────────────────────────────────

struct CounterpartiesView: View {
    @State private var selected: Counterparty? = nil
    @State private var search: String = ""

    private let mockBanks: [Counterparty] = CounterpartyStore.demo

    var body: some View {
        VStack(spacing: 0) {
            header
            HSplitView {
                listPane
                    .frame(minWidth: 320, idealWidth: 380)
                detailPane
                    .frame(minWidth: 400)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("COUNTERPARTY BANKS")
                    .font(DesignTokens.labelFont)
                    .tracking(0.6)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Known UNCLE endpoints + BIC address book")
                    .font(.system(size: 20, weight: .medium))
            }
            Spacer()
            Button {
                // Stub: add new counterparty
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add bank")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.brandNavy)
        }
        .padding(EdgeInsets(top: 22, leading: 28, bottom: 18, trailing: 28))
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            TextField("Search by name / BIC / jurisdiction", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                .background(DesignTokens.bgTertiary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filteredBanks) { bank in
                        Button {
                            selected = bank
                        } label: {
                            counterpartyRow(bank, isSelected: bank.id == selected?.id)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        .background(DesignTokens.bgSecondary)
    }

    private var filteredBanks: [Counterparty] {
        if search.isEmpty { return mockBanks }
        let s = search.lowercased()
        return mockBanks.filter {
            $0.name.lowercased().contains(s)
                || $0.bic.lowercased().contains(s)
                || $0.jurisdiction.lowercased().contains(s)
        }
    }

    private func counterpartyRow(_ b: Counterparty, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(b.name)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                // Peer-wire readiness dot — single tiny indicator
                // visible in the list scan. Green = ready, amber =
                // pending fields. Hover shows missing list.
                let missing = Self.peerWireMissingFields(b)
                Circle()
                    .fill(missing.isEmpty
                          ? DesignTokens.statusSettledFg
                          : DesignTokens.statusPendingFg)
                    .frame(width: 6, height: 6)
                    .help(missing.isEmpty
                          ? "Peer wire ready"
                          : "Onboarding pending — missing \(missing.joined(separator: ", "))")
                Text(b.jurisdiction)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DesignTokens.bgTertiary)
                    .clipShape(Capsule())
            }
            Text(b.bic)
                .font(DesignTokens.monoSmallFont)
                .foregroundStyle(DesignTokens.textTertiary)
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? DesignTokens.brandNavySoft : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle()
                    .fill(DesignTokens.brandGold)
                    .frame(width: 3)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let b = selected {
            counterpartyDetail(b)
        } else {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "building.columns")
                    .font(.system(size: 32))
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Select a counterparty bank")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignTokens.bgSecondary)
        }
    }

    @State private var confirmRemove: Bool = false

    private func counterpartyDetail(_ b: Counterparty) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("COUNTERPARTY")
                            .font(DesignTokens.labelFont)
                            .tracking(0.6)
                            .foregroundStyle(DesignTokens.textTertiary)
                        Text(b.name)
                            .font(.system(size: 18, weight: .medium))
                    }
                    Spacer()
                    peerWireReadinessBadge(b)
                }
                Divider()
                // ── Identification (SWIFT side) ────────────────
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("SWIFT IDENTIFICATION")
                            .font(DesignTokens.labelFont)
                            .tracking(0.5)
                            .foregroundStyle(DesignTokens.textTertiary)
                        SwiftOnlyTag()
                    }
                    detailRow(label: "BIC",          value: b.bic, mono: true)
                    detailRow(label: "Jurisdiction", value: b.jurisdiction)
                    detailRow(label: "Since",        value: b.relationshipSince, mono: true)
                }
                Divider()
                // ── AXIOM bilateral arrangement ────────────────
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("AXIOM BILATERAL ARRANGEMENT")
                            .font(DesignTokens.labelFont)
                            .tracking(0.5)
                            .foregroundStyle(DesignTokens.textTertiary)
                        AxiomAnchorTag()
                    }
                    detailRow(label: "AXIOM tier address", value: b.axiomTierAddress, mono: true)
                    detailRow(label: "Peer UNCLE SAM endpoint",
                              value: b.peerEndpoint, mono: true)
                    detailRow(label: "PGP fingerprint",
                              value: b.pgpFingerprint.isEmpty
                                ? "(not yet provisioned)"
                                : b.pgpFingerprint,
                              mono: true)
                    detailRow(label: "Op ed25519 pubkey",
                              value: b.operatorEd25519PubkeyHex.isEmpty
                                ? "(not yet provisioned)"
                                : truncateMiddle(b.operatorEd25519PubkeyHex, max: 40),
                              mono: true)
                    detailRow(label: "Bilateral FX",
                              value: "1 AXC = \(String(format: "%.4f", b.fxRate)) \(b.fxCounterCurrency)",
                              mono: true)
                    detailRow(label: "Daily limit",
                              value: "\(fmtLimit(b.dailyLimit)) \(b.fxCounterCurrency)",
                              mono: true)
                    Text("Bilateral arrangement — each pair of banks negotiates its own AXC ↔ fiat rate and daily limit. UNCLE SAM has no global exchange.")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                pgpPublicKeyCard(b)
                Divider()
                HStack(spacing: 8) {
                    Button("Edit arrangement") { }
                        .buttonStyle(.bordered)
                    Button("New wire to this counterparty") { }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignTokens.brandNavy)
                    Spacer()
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Text("Remove")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(EdgeInsets(top: 20, leading: 24, bottom: 24, trailing: 24))
        }
        .alert("Remove counterparty?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { selected = nil }
        } message: {
            Text("This removes \(b.name) from the bilateral counterparty list. Any pending wires referencing this BIC must be re-routed.")
        }
    }

    private func fmtLimit(_ v: Double) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.groupingSeparator = ","
        fmt.maximumFractionDigits = 0
        return fmt.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// Collapsible armoured-PGP-key block. The fingerprint above is
    /// the operator-verified anchor; this card lets the operator
    /// inspect / copy the actual key block when they need to (e.g.
    /// re-verifying after a key rotation, exporting for the bank's
    /// own key escrow). We render it inside a `DisclosureGroup`
    /// because the block is 30+ lines and dominates the page if
    /// always-on.
    @ViewBuilder
    private func pgpPublicKeyCard(_ b: Counterparty) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("PGP PUBLIC KEY")
                    .font(DesignTokens.labelFont)
                    .tracking(0.5)
                    .foregroundStyle(DesignTokens.textTertiary)
                AxiomAnchorTag()
            }
            if b.pgpPublicKey.isEmpty {
                Text("Not yet provisioned. Use **Edit arrangement** to paste the counterparty's ASCII-armoured PGP public-key block, then verify the fingerprint above against the counterparty out-of-band (phone, in-person ceremony).")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DisclosureGroup {
                    ScrollView {
                        Text(b.pgpPublicKey)
                            .font(DesignTokens.monoSmallFont)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 200)
                    .background(DesignTokens.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } label: {
                    Text("Armoured block")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            Text("UNCLE SAM uses this key to encrypt outbound NotifyCheques to this counterparty and to verify their NotifyChequesAck signatures. The fingerprint above is operator-verified out-of-band; trust it, not the block.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailRow(label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textTertiary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(mono ? DesignTokens.monoFont : .system(size: 12))
                .textSelection(.enabled)
            Spacer()
        }
    }

    /// Peer-wire readiness badge — green PEER WIRE READY when the
    /// counterparty has all four onboarding fields populated
    /// (pgpFingerprint + pgpPublicKey + operatorEd25519PubkeyHex
    /// + peerEndpoint). Otherwise renders a yellow "NEEDS ONBOARDING
    /// — <count> field(s) missing" tag the operator can hover to
    /// see exactly which fields. Helps differentiate counterparties
    /// the bank can already NotifyCheques on the wire from those
    /// still waiting on a bilateral ceremony.
    @ViewBuilder
    private func peerWireReadinessBadge(_ b: Counterparty) -> some View {
        let missing = Self.peerWireMissingFields(b)
        if missing.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                Text("PEER WIRE READY")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
            }
            .foregroundStyle(DesignTokens.statusSettledFg)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(DesignTokens.statusSettledBg)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help("NotifyCheques can fire to this counterparty after a successful wallet.send.")
        } else {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text("NEEDS ONBOARDING — \(missing.count) FIELD\(missing.count == 1 ? "" : "S")")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
            }
            .foregroundStyle(DesignTokens.statusPendingFg)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(DesignTokens.statusPendingBg)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help("Missing: \(missing.joined(separator: ", ")). Provision via the bilateral arrangement ceremony before NotifyCheques can fire.")
        }
    }

    static func peerWireMissingFields(_ b: Counterparty) -> [String] {
        var missing: [String] = []
        if b.pgpFingerprint.isEmpty { missing.append("pgpFingerprint") }
        if b.pgpPublicKey.isEmpty { missing.append("pgpPublicKey") }
        if b.operatorEd25519PubkeyHex.isEmpty {
            missing.append("operatorEd25519PubkeyHex")
        }
        if b.peerEndpoint.isEmpty { missing.append("peerEndpoint") }
        return missing
    }

    /// Same shape as UNCLESettingsView.truncateMiddle — small enough
    /// to duplicate rather than route through a shared utility just
    /// for the ed25519 row.
    private func truncateMiddle(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        let head = s.prefix(max / 2 - 1)
        let tail = s.suffix(max / 2 - 1)
        return "\(head)…\(tail)"
    }
}

struct Counterparty: Identifiable {
    let id: UUID
    let name: String
    let bic: String
    let jurisdiction: String
    /// Counterparty bank's UNCLE SAM peer endpoint — `host:port` of
    /// THEIR running UNCLE SAM listener. This is where outbound
    /// NotifyCheques get delivered. Banks don't run validator
    /// UNCLEs (those are on the validator side at :9301); banks
    /// run UNCLE SAM the client at :9090. Naming was previously
    /// `uncle` which conflated the two roles — AXIOM Origin's 2026-05-31
    /// architectural correction made the split explicit.
    let peerEndpoint: String
    let relationshipSince: String

    // Bilateral arrangement — UNCLE SAM has no global FX exchange;
    // each pair of banks arranges its own AXC ↔ fiat rate, daily
    // limit, and AXIOM wallet id. This is the practical
    // equivalent of SWIFT's RMA + SSI.
    /// The counterparty bank's published AXIOM tier address — the
    /// SAME address-string format `wallet.allAddresses()` returns.
    /// Sender uses this directly as the `to:` arg of `wallet.send()`;
    /// the address itself encodes the receiver's security tier
    /// (k=5 DMAP or k=5 ZKVM) per YP §6.3 — sender cannot override.
    let axiomTierAddress: String
    /// AXC → counter-currency rate, bilaterally arranged. e.g.
    /// "1 AXC = 0.9132 USD" → fxRate = 0.9132.
    let fxRate: Double
    let fxCounterCurrency: String
    /// Daily-aggregate limit in the counter currency for
    /// outbound payments to this counterparty.
    let dailyLimit: Double

    /// Counterparty's OpenPGP public-key fingerprint — 40 hex chars,
    /// displayed in 4-char groups. The fingerprint is what the
    /// operator manually verifies against the counterparty bank
    /// (phone call, ceremony, in-person handoff) — it pins the
    /// public-key block so a swapped `pgpPublicKey` is detectable.
    let pgpFingerprint: String
    /// Counterparty's OpenPGP public key as an ASCII-armoured block
    /// (`-----BEGIN PGP PUBLIC KEY BLOCK----- ... -----END...`).
    /// Used by UNCLE SAM to encrypt outbound NotifyCheques to this
    /// counterparty and to verify their NotifyChequesAck signatures.
    /// Empty string in the seed list means "not yet provisioned —
    /// paste during Edit arrangement" (deferred UI).
    let pgpPublicKey: String
    /// Counterparty's operator ed25519 public key, hex-encoded
    /// (64 chars, no separators). DIFFERENT from the PGP key above:
    /// the PGP key wraps the envelope (transport-layer identity),
    /// this ed25519 key signs the NotifyCheques canonical bytes
    /// (Transaction-level intent). Defence in depth — a compromised
    /// PGP key alone shouldn't be enough to forge a cheque
    /// notification with arbitrary amount / receiver / piece-list.
    /// Provisioned at the same bilateral ceremony as the PGP
    /// fingerprint. Empty string = not yet provisioned (UNCLE SAM
    /// rejects NotifyCheques from this counterparty until set).
    let operatorEd25519PubkeyHex: String

    init(name: String, bic: String, jurisdiction: String,
         peerEndpoint: String, relationshipSince: String,
         axiomTierAddress: String, fxRate: Double,
         fxCounterCurrency: String, dailyLimit: Double,
         pgpFingerprint: String, pgpPublicKey: String,
         operatorEd25519PubkeyHex: String) {
        self.id = UUID()
        self.name = name
        self.bic = bic
        self.jurisdiction = jurisdiction
        self.peerEndpoint = peerEndpoint
        self.relationshipSince = relationshipSince
        self.axiomTierAddress = axiomTierAddress
        self.fxRate = fxRate
        self.fxCounterCurrency = fxCounterCurrency
        self.dailyLimit = dailyLimit
        self.pgpFingerprint = pgpFingerprint
        self.pgpPublicKey = pgpPublicKey
        self.operatorEd25519PubkeyHex = operatorEd25519PubkeyHex
    }
}

// ── Settings ──────────────────────────────────────────────────────

struct UNCLESettingsView: View {
    @EnvironmentObject private var session: InstitutionSession
    @EnvironmentObject private var store: MessageStore
    @EnvironmentObject private var nablaNodes: NablaNodesStore
    @EnvironmentObject private var peerListener: UncleSamListener
    @EnvironmentObject private var pgpHandler: PgpEnvelopeHandler
    @EnvironmentObject private var notifyChequesInbox: NotifyChequesInbox
    @EnvironmentObject private var gatewayClient: UncleGatewayClient
    @EnvironmentObject private var notifyChequesSender: NotifyChequesSender

    /// Validator UNCLE gateway endpoint Mac dials for PullCheques.
    /// Default is Linux's smoke target (alpha validator on the LAN).
    @AppStorage("uncle.sam.gateway.endpoint") private var gatewayEndpoint: String = "172.20.0.42:9301"
    /// Linux UNCLE's ASCII-armoured PGP public key. Pasted by the
    /// operator at smoke-setup time; in production this lives in
    /// a per-validator registry alongside Nabla pubkeys.
    @AppStorage("uncle.sam.gateway.pubkey_armored") private var gatewayPubkeyArmored: String = ""

    /// Self identity — Mac's OWN PGP public key path (file containing
    /// the ASCII-armoured public block). Used to register a "Self"
    /// counterparty so loopback self-sends (Mac → Mac at :9090)
    /// resolve through CounterpartyStore.byPgpFingerprint.
    @AppStorage("uncle.sam.self.pgp_public_path") private var selfPgpPublicPath: String = ""
    /// Self identity — Mac's ed25519 secret key file path (32 raw
    /// bytes). Used to sign canonical NotifyCheques bytes on
    /// outbound. Production deployments back this with HSM/keychain;
    /// demo is filesystem.
    @AppStorage("uncle.sam.self.ed25519_secret_path") private var selfEd25519SecretPath: String = ""
    /// Self identity — Mac's ed25519 PUBLIC key hex (64 chars, no
    /// separators). Used both as the self-counterparty's
    /// operatorEd25519PubkeyHex AND surfaced so the operator can
    /// share it with counterparty banks at bilateral onboarding.
    @AppStorage("uncle.sam.self.ed25519_public_hex") private var selfEd25519PublicHex: String = ""
    /// Loopback receiver account id (UUID). When set, the
    /// self-counterparty's axiomTierAddress is bound to that
    /// account's tier address — the wire composer can then route
    /// a real wallet.send to BIC=SELFXXXXXXX and the SDK targets
    /// the picked account. Default empty (use first non-active
    /// account).
    @AppStorage("uncle.sam.self.loopback_receiver_account_id") private var selfLoopbackReceiverId: String = ""

    // ── Outbound NotifyCheques composer state ─────────────────────
    @State private var sendSenderWalletId: String = ""
    @State private var sendReceiverWalletId: String = ""
    @State private var sendAmountAtoms: String = "100000"
    @State private var sendSwiftReference: String = "LOOPBACK-SELF-SEND-001"
    @State private var sendTargetEndpoint: String = "127.0.0.1:9090"

    /// Persisted across launches. Default port :9090 — distinct
    /// from the validator-side UNCLE gateway's :9301 so a bank
    /// running both processes on the same host doesn't collide.
    @AppStorage("uncle.sam.listener.port") private var listenerPort: Int = 9090
    /// Auto-start the listener at launch when the operator has
    /// previously toggled it on. Default off so first-launch
    /// installs don't bind a port before the operator has decided
    /// they want the peer protocol on.
    @AppStorage("uncle.sam.listener.enabled") private var listenerEnabled: Bool = false
    /// Operator PGP secret key file path. Persisted so the key is
    /// re-loaded at launch (Bucket 2 — bilateral peer protocol
    /// needs this loaded before any inbound NotifyCheques can be
    /// decrypted). Production deployments would back this with an
    /// HSM (PKCS#11) handle rather than a filesystem path.
    @AppStorage("uncle.sam.pgp.operator_key_path") private var operatorPgpKeyPath: String = ""
    /// Operator PGP key passphrase. UNENCRYPTED storage is a demo
    /// concession — production deployments use the OS keychain or
    /// HSM-side passphrase prompts. Documented honestly in the
    /// Settings card so the bank operator knows what's stored
    /// where.
    @AppStorage("uncle.sam.pgp.operator_key_passphrase") private var operatorPgpPassphrase: String = ""

    @State private var showAddAccount: Bool = false
    @State private var showImportWallet: Bool = false
    /// Drives the "Import from portable backup (.axpw)" sheet.
    @State private var showImportPortable: Bool = false
    /// Result of an account .axpw export — non-nil shows an alert.
    @State private var exportResult: AccountExportResult? = nil
    /// Same confirm-on-switch contract as the chrome strip — when
    /// the operator taps a different account's radio button we
    /// stash the id here and prompt before applying.
    @State private var pendingSwitchAccountId: UUID? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                operatorCard
                profileCard
                accountsCard
                endpointCard
                networkCard
                peerListenerCard
                gatewayClientCard
                selfIdentityCard
                notifyChequesSenderCard
                keysCard
                retentionCard
            }
            .padding(EdgeInsets(top: 22, leading: 28, bottom: 28, trailing: 28))
        }
        .onAppear {
            // Auto-load the operator PGP key when a path is
            // configured. Idempotent — re-load is OK.
            if !operatorPgpKeyPath.isEmpty,
               case .notLoaded = pgpHandler.keyState {
                pgpHandler.loadOperatorKey(
                    path: operatorPgpKeyPath,
                    passphrase: operatorPgpPassphrase.isEmpty
                        ? nil : operatorPgpPassphrase)
            }
            // Auto-register the self counterparty when key + self
            // PGP pubkey + ed25519 hex are all set. Re-runs cheaply
            // on every Settings open so changes to either field
            // refresh the registration.
            refreshSelfCounterparty()
            // Auto-start the peer listener once per launch when
            // the operator has previously toggled it on. Idempotent
            // — start() is a no-op when state is already running on
            // the requested port.
            if listenerEnabled, !peerListener.state.isRunning {
                peerListener.start(port: UInt16(listenerPort))
            }
        }
        .onChange(of: pgpHandler.keyState) { _, _ in
            refreshSelfCounterparty()
        }
        .onChange(of: selfLoopbackReceiverId) { _, _ in
            refreshSelfCounterparty()
        }
        .sheet(isPresented: $showAddAccount) {
            AddAccountSheet(onDone: { showAddAccount = false })
                .environmentObject(session)
        }
        .sheet(isPresented: $showImportWallet) {
            ImportWalletSheet(onDone: { showImportWallet = false })
                .environmentObject(session)
        }
        .sheet(isPresented: $showImportPortable) {
            ImportPortableBackupSheet(onDone: { showImportPortable = false })
                .environmentObject(session)
        }
        .alert(exportResult?.ok == true
               ? "Wallet backup exported"
               : "Export failed",
               isPresented: Binding(
                get: { exportResult != nil },
                set: { if !$0 { exportResult = nil } }
               ),
               presenting: exportResult
        ) { _ in
            Button("OK", role: .cancel) { exportResult = nil }
        } message: { result in
            Text(result.message)
        }
        .alert("Switch active account?",
               isPresented: Binding(
                get: { pendingSwitchAccountId != nil },
                set: { if !$0 { pendingSwitchAccountId = nil } }
               ),
               presenting: pendingSwitchAccountId.flatMap { session.account(id: $0) }
        ) { target in
            Button("Cancel", role: .cancel) {
                pendingSwitchAccountId = nil
            }
            Button("Switch") {
                session.setActiveAccount(target.id)
                pendingSwitchAccountId = nil
            }
        } message: { target in
            let current = session.activeAccount?.config.displayName ?? "—"
            Text("Switching from \(current) to \(target.config.displayName). This changes the funded position for every outbound message and the BIC that lands in :52A: of the SWIFT envelope. The chrome strip will tint to the new account's accent colour.")
        }
    }

    /// Institution accounts list — one row per funded position the
    /// bank operates from (HQ Treasury, FX Desk, branch
    /// settlements, etc.). Each row is a real AxiomWallet on disk.
    private var accountsCard: some View {
        settingsCard(title: "Institution accounts") {
            HStack(spacing: 6) {
                Text("\(session.accounts.count) account(s)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                Spacer()
                // Bucket 5(d) — total pending credit across all
                // accounts (every inbound .received MessageRecord
                // that hasn't been explicitly posted to ledger yet).
                let totalPendingAtoms = store.pendingCreditAtoms()
                if totalPendingAtoms > 0 {
                    Text("PENDING CREDIT: \(Self.fmtAtoms(totalPendingAtoms)) AXC")
                        .font(DesignTokens.labelFont)
                        .tracking(0.5)
                        .foregroundStyle(DesignTokens.statusSettledFg)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DesignTokens.statusSettledBg)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Button {
                    showImportWallet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import wallet")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Import an existing AxiomWallet into UNCLE SAM by copying its FOLDER. Only works for plaintext wallet folders — for an AxiomWallet that seals its keystore at rest, use “Import .axpw” instead.")
                Button {
                    showImportPortable = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.doc")
                        Text("Import .axpw")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Import a wallet from a password-encrypted AXPW portable backup. This is the cross-app transit format — use it to bring an AxiomWallet wallet across, since AxiomWallet now seals its on-disk keystore.")
                Button {
                    showAddAccount = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add account")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                Text("ACTIVE")  .frame(width: 50,  alignment: .leading)
                Text("NAME")    .frame(width: 160, alignment: .leading)
                Text("PURPOSE") .frame(width: 130, alignment: .leading)
                Text("BIC")     .frame(width: 100, alignment: .leading)
                Text("PENDING") .frame(width: 110, alignment: .trailing)
                Text("BALANCE") .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(DesignTokens.textTertiary)
            .padding(.vertical, 4)
            ForEach(session.accounts) { acct in
                accountRow(acct)
                Divider().opacity(0.4)
            }
            Text("Each account is a distinct AxiomWallet on disk — own keypair, own AXC float, own tier address. The operator picks which account funds a given wire in the composer (Send from). For a branch with its own SWIFT BIC, set the sub-BIC here so :52A: in outbound messages reflects the branch identifier.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func accountRow(_ acct: InstitutionAccount) -> some View {
        HStack(spacing: 0) {
            // Active-radio column — routes through confirm alert.
            HStack(spacing: 6) {
                Button {
                    if acct.id != session.activeAccountId {
                        pendingSwitchAccountId = acct.id
                    }
                } label: {
                    Image(systemName: session.activeAccountId == acct.id
                                      ? "largecircle.fill.circle"
                                      : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(session.activeAccountId == acct.id
                                         ? DesignTokens.brandNavy
                                         : DesignTokens.textTertiary)
                }
                .buttonStyle(.plain)
                // Colour swatch — same accent the chrome strip uses
                // when this account is active. Helps the operator
                // identify rows visually.
                Circle()
                    .fill(acct.config.color.color)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle().strokeBorder(DesignTokens.borderPrimary,
                                              lineWidth: 0.5)
                    )
                    .help("Chrome tint: \(acct.config.color.label)")
            }
            .frame(width: 50, alignment: .leading)
            // Name + tier address subtitle
            VStack(alignment: .leading, spacing: 1) {
                Text(acct.config.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.textPrimary)
                Text(acct.tierAddress.isEmpty
                     ? "(wallet not opened)"
                     : truncateMiddle(acct.tierAddress, max: 26))
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .help(acct.tierAddress)
            }
            .frame(width: 160, alignment: .leading)
            HStack(spacing: 4) {
                Image(systemName: acct.config.purpose.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textSecondary)
                Text(acct.config.purpose.label)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .frame(width: 130, alignment: .leading)
            .help(acct.config.purpose.explanation)
            Text(acct.config.effectiveBIC(fallback: session.bankBIC))
                .font(DesignTokens.monoSmallFont)
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(width: 100, alignment: .leading)
            // PENDING column — atoms received but not yet posted to
            // this account's ledger (matched by tier address).
            let pending = store.pendingCreditAtoms(
                forReceiverWallet: acct.tierAddress)
            Group {
                if pending > 0 {
                    Text("+\(Self.fmtAtoms(pending)) AXC")
                        .font(DesignTokens.monoSmallFont)
                        .foregroundStyle(DesignTokens.statusSettledFg)
                } else {
                    Text("—")
                        .font(DesignTokens.monoSmallFont)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
            }
            .frame(width: 110, alignment: .trailing)
            CensoredBalance(
                atoms: acct.balanceAtoms,
                canView: session.operatorRole.canViewBalance,
                font: DesignTokens.monoFont
            )
            .foregroundStyle(DesignTokens.textPrimary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button {
                exportAccountBackup(acct)
            } label: {
                Label("Export wallet backup (.axpw)…",
                      systemImage: "lock.doc")
            }
        }
    }

    /// Export an account's wallet as an AXPW portable backup.
    /// Prompts the operator for the wallet key (UNCLE SAM never
    /// stores it), picks a destination via NSSavePanel, then seals
    /// the plaintext canonical AXWL into the password-encrypted
    /// `.axpw` transit format. Surfaces the outcome via an alert.
    private func exportAccountBackup(_ acct: InstitutionAccount) {
        guard let key = promptWalletKey(displayName: acct.config.displayName) else {
            return  // operator cancelled
        }
        let panel = NSSavePanel()
        panel.title = "Export wallet backup"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "\(acct.config.pairName).axpw"
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let err = session.exportPortableBackup(
            appDir: uncleAppDir(),
            account: acct,
            walletKey: key,
            to: dest)
        if let err {
            exportResult = AccountExportResult(ok: false, message: err)
        } else {
            exportResult = AccountExportResult(
                ok: true,
                message: "Exported “\(acct.config.displayName)” to \(dest.path) as an encrypted portable backup (AXPW: PBKDF2 + AES-GCM). Import it with the SAME wallet key on AxiomWallet, the web wallet, or another UNCLE SAM install. The file is safe in transit, but keep it private.")
        }
    }

    /// AppKit secure prompt for the wallet key (the export flow is
    /// AppKit-modal via NSSavePanel anyway). Returns the entered
    /// key, or nil if cancelled. Mirrors AxiomWallet's export prompt.
    private func promptWalletKey(displayName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Export “\(displayName)” — wallet key"
        alert.informativeText = "Your wallet key encrypts the portable backup. The same key imports it on AxiomWallet, the web wallet, or another device."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Wallet key"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }

    /// Format `atoms` as AXC with up to 10 decimal places, trailing
    /// zeros trimmed for compact display. 1 AXC = 1e10 atoms.
    private static func fmtAtoms(_ atoms: UInt64) -> String {
        let axc = Double(atoms) / 1e10
        let s = String(format: "%.10f", axc)
        // trim trailing zeros and dangling dot
        var out = s
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }

    private func truncateMiddle(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        let head = s.prefix(max / 2 - 1)
        let tail = s.suffix(max / 2 - 1)
        return "\(head)…\(tail)"
    }

    /// Network → Nabla nodes table. Shows every node UNCLE SAM
    /// knows about from its seed list with its discovered service
    /// mode beside it. Provisional nodes are listed but marked
    /// "not used (institutional policy)" — UNCLE SAM only routes
    /// settlement-grade reads through Confirmed nodes per AXIOM Origin's
    /// 2026-05-30 design call.
    private var networkCard: some View {
        settingsCard(title: "Network — Nabla nodes") {
            HStack(spacing: 6) {
                Text("Settlement capacity")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("\(nablaNodes.confirmedGradeAvailable) of \(nablaNodes.total) Confirmed-grade reachable")
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(nablaNodes.hasSettlementCapacity
                                     ? DesignTokens.statusSettledFg
                                     : DesignTokens.statusRejectedFg)
                Spacer()
                if let started = nablaNodes.lastRefreshStartedAt {
                    Text("Last probe: \(relativeTimeString(from: started))")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                Button {
                    nablaNodes.refresh()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                    .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(nablaNodes.isProbing)
            }
            Divider().opacity(0.5)
            // Table header
            HStack(spacing: 0) {
                Text("NODE")     .frame(width: 80,  alignment: .leading)
                Text("ENDPOINT") .frame(maxWidth: .infinity, alignment: .leading)
                Text("MODE")     .frame(width: 110, alignment: .leading)
                Text("STATUS")   .frame(width: 180, alignment: .leading)
            }
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(DesignTokens.textTertiary)
            .padding(.vertical, 4)
            ForEach(nablaNodes.nodes) { node in
                nablaNodeRow(node)
                Divider().opacity(0.4)
            }
            Text("UNCLE SAM only routes Nabla queries through Confirmed-grade nodes — Provisional nodes (zero false positives required for institutional settlement) are listed for transparency but never queried. The Mode + Status columns are populated by live `sdkProbeNablaMode()` calls against each node's TCP endpoint at app launch and on Refresh.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    /// "5s ago" / "3m ago" / "just now" — relative-time string for
    /// the network card's "Last probe" header. We keep it cheap
    /// (no formatter cache) because it renders once per Settings
    /// open and updates on Refresh.
    private func relativeTimeString(from date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 2 { return "just now" }
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        return "\(Int(elapsed / 3600))h ago"
    }

    /// UNCLE SAM ↔ UNCLE SAM peer listener — inbound side of the
    /// bilateral correspondent protocol. Bucket 1 scaffolding ships
    /// the socket plumbing + logging stub; Buckets 2 + 3 add PGP
    /// envelope decode and NotifyCheques verification on top of
    /// the same UncleSamListener — no UI change at that point.
    private var peerListenerCard: some View {
        settingsCard(title: "Network — Peer listener (UNCLE SAM ↔ UNCLE SAM)") {
            HStack(spacing: 8) {
                Circle()
                    .fill(peerListenerStateColor)
                    .frame(width: 8, height: 8)
                Text(peerListenerStateLabel)
                    .font(DesignTokens.monoSmallFont)
                Spacer()
                Toggle(isOn: $listenerEnabled) {
                    Text("Auto-start at launch")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            HStack(spacing: 10) {
                Text("Listen port")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                TextField("9090", value: $listenerPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.monoSmallFont)
                    .frame(width: 90)
                    .disabled(peerListener.state.isRunning)
                if peerListener.state.isRunning {
                    Button("Stop") {
                        peerListener.stop()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Start") {
                        peerListener.start(port: UInt16(listenerPort))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandNavy)
                    .controlSize(.small)
                }
                Spacer()
            }
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                statBlock(label: "ACCEPTED",
                          value: "\(peerListener.connectionsAccepted)")
                statBlock(label: "ENVELOPES",
                          value: "\(peerListener.envelopesReceived)")
                statBlock(label: "LAST INBOUND",
                          value: peerListener.lastInboundAt
                            .map { relativeTimeString(from: $0) }
                            ?? "—")
                Spacer()
            }
            if peerListener.envelopesReceived > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    inboundEvidenceRow(label: "Peer",
                                       value: peerListener.lastInboundPeer)
                    inboundEvidenceRow(label: "Size",
                                       value: "\(peerListener.lastInboundSize) bytes")
                    inboundEvidenceRow(label: "Head (hex)",
                                       value: peerListener.lastInboundFirstBytes)
                }
                .padding(.top, 4)
            }
            if let err = peerListener.lastError,
               let at = peerListener.lastErrorAt {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                    Text("\(relativeTimeString(from: at)): \(err)")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                    Spacer()
                }
                .padding(.top, 4)
            }
            Text("Inbound side of the bilateral correspondent peer wire. A counterparty bank's UNCLE SAM opens a direct TCP connection here and ships a NotifyCheques envelope (PGP-wrapped, signed by the counterparty's operator key). PGP-decode + signature-verify + NotifyChequesAck are the next implementation pass — this build only frames bytes off the wire and logs them. u32 BE length-prefix framing matches axiom-uncle/src/listener.rs.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private var peerListenerStateLabel: String {
        switch peerListener.state {
        case .stopped: return "stopped"
        case .starting: return "starting…"
        case .running(let port): return "listening on :\(port)"
        case .failed(let msg): return "failed — \(msg)"
        }
    }

    private var peerListenerStateColor: Color {
        switch peerListener.state {
        case .stopped: return DesignTokens.textTertiary
        case .starting: return DesignTokens.statusPendingFg
        case .running: return DesignTokens.statusSettledFg
        case .failed: return DesignTokens.statusRejectedFg
        }
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignTokens.labelFont)
                .tracking(0.5)
                .foregroundStyle(DesignTokens.textTertiary)
            Text(value)
                .font(DesignTokens.monoSmallFont)
        }
        .frame(width: 130, alignment: .leading)
    }

    private func inboundEvidenceRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textTertiary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(DesignTokens.monoSmallFont)
                .textSelection(.enabled)
            Spacer()
        }
    }

    /// Self-identity card — Mac's own PGP pubkey path + ed25519
    /// keypair. Required for loopback self-send tests (Mac → Mac
    /// at :9090) AND for any future production send-side flow
    /// where Mac originates a transaction and notifies a peer bank.
    /// The same ed25519 secret signs canonical NotifyCheques bytes
    /// outbound; the ed25519 PUBLIC hex gets shared with peer banks
    /// at bilateral onboarding so they can verify inbound from us.
    private var selfIdentityCard: some View {
        settingsCard(title: "Self identity — Mac's outbound signing keys") {
            Text("Mac uses these when ORIGINATING a NotifyCheques (sending to a peer bank, or to itself for loopback self-send tests). The PGP public key is the same operator key loaded in Cryptographic keys above — the path here is just the matching .asc public-half file so a self-counterparty entry can be registered (lets the listener verify loopback envelopes via byPgpFingerprint).")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("PGP public key")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .frame(width: 120, alignment: .leading)
                TextField("/path/to/operator-pgp-public.asc",
                          text: $selfPgpPublicPath)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.monoSmallFont)
                Button("Browse…") {
                    pickSelfFile(into: $selfPgpPublicPath,
                                 title: "Select Mac PGP public key file")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            HStack(spacing: 8) {
                Text("ed25519 secret")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .frame(width: 120, alignment: .leading)
                TextField("/path/to/mac-ed25519.sk (32 raw bytes)",
                          text: $selfEd25519SecretPath)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.monoSmallFont)
                Button("Browse…") {
                    pickSelfFile(into: $selfEd25519SecretPath,
                                 title: "Select Mac ed25519 secret file")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            HStack(spacing: 8) {
                Text("ed25519 public hex")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .frame(width: 120, alignment: .leading)
                TextField("64 hex chars, no separators",
                          text: $selfEd25519PublicHex)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.monoSmallFont)
            }
            // Loopback receiver account picker — drives the
            // self-counterparty's axiomTierAddress so a real
            // wallet.send to BIC=SELFXXXXXXX routes to the picked
            // account's k=5 tier address. Required if the operator
            // wants the wire composer to drive an actual
            // intra-bank self-send (vs the smoke loopback).
            HStack(spacing: 8) {
                Text("Loopback receiver")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: $selfLoopbackReceiverId) {
                    Text("(none — receiver address synthetic)")
                        .tag("")
                    ForEach(session.accounts) { acct in
                        Text(acct.config.displayName +
                             (acct.tierAddress.isEmpty
                              ? " (wallet not open)"
                              : ""))
                            .tag(acct.id.uuidString)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            Button("Refresh self counterparty") {
                refreshSelfCounterparty()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            // Status badge — fires when the self counterparty is
            // registered.
            HStack(spacing: 6) {
                Circle()
                    .fill(CounterpartyStore.selfEntry != nil
                          ? DesignTokens.statusSettledFg
                          : DesignTokens.textTertiary)
                    .frame(width: 8, height: 8)
                Text(CounterpartyStore.selfEntry != nil
                     ? "Self counterparty registered — loopback ready"
                     : "Self counterparty not registered (set the three fields above)")
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textSecondary)
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    /// Outbound NotifyCheques composer. Mac → peer UNCLE SAM at
    /// :9090 (or 127.0.0.1:9090 for loopback self-send). Doesn't
    /// trigger any AXIOM transaction — just composes a NotifyCheques
    /// message, signs the canonical bytes, PGP-wraps, sends. The
    /// receiver-side handler verifies + ingests via the same path
    /// that handles real production peer-wire arrivals.
    private var notifyChequesSenderCard: some View {
        settingsCard(title: "Outbound NotifyCheques (peer wire / loopback test)") {
            Text("Compose + sign + send a NotifyCheques to a peer UNCLE SAM. For loopback (Mac → Mac at 127.0.0.1:9090) the listener must be running, the operator PGP key must be loaded, the self counterparty must be registered, and the ed25519 secret must be configured.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            composerRow(label: "Sender wallet_id",
                        binding: $sendSenderWalletId,
                        placeholder: "treasury@bank.example/abcd1234ef")
            composerRow(label: "Receiver wallet_id",
                        binding: $sendReceiverWalletId,
                        placeholder: "fx@bank.example/9876543210")
            composerRow(label: "Amount (atoms)",
                        binding: $sendAmountAtoms,
                        placeholder: "100000")
            composerRow(label: "SWIFT reference",
                        binding: $sendSwiftReference,
                        placeholder: "LOOPBACK-SELF-SEND-001")
            composerRow(label: "Target (host:port)",
                        binding: $sendTargetEndpoint,
                        placeholder: "127.0.0.1:9090")
            HStack(spacing: 8) {
                Button("Send NotifyCheques") {
                    Task { await runSendNotifyCheques() }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandNavy)
                .controlSize(.small)
                .disabled(notifyChequesSender.sending
                          || CounterpartyStore.selfEntry == nil
                          || selfEd25519SecretPath.isEmpty
                          || sendSenderWalletId.isEmpty
                          || sendReceiverWalletId.isEmpty
                          || sendAmountAtoms.isEmpty)
                if notifyChequesSender.sending {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
            if let err = notifyChequesSender.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.top, 4)
            }
            if let ack = notifyChequesSender.lastAck,
               let sentAt = notifyChequesSender.lastSentAt {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("LAST ACK — \(relativeTimeString(from: sentAt))")
                            .font(DesignTokens.labelFont)
                            .tracking(0.5)
                            .foregroundStyle(DesignTokens.textTertiary)
                        Spacer()
                        Text(ack.status.rawValue.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(ack.status == .accepted
                                             ? DesignTokens.statusSettledFg
                                             : DesignTokens.statusRejectedFg)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ack.status == .accepted
                                        ? DesignTokens.statusSettledBg
                                        : DesignTokens.statusRejectedBg)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    if let bid = notifyChequesSender.lastBundleIdHex {
                        inboundEvidenceRow(label: "bundle_id",
                                           value: bid.prefix(32) + "…")
                    }
                    if let reason = ack.reason, !reason.isEmpty {
                        inboundEvidenceRow(label: "reason",
                                           value: reason)
                    }
                }
            }
        }
    }

    private func composerRow(label: String,
                              binding: Binding<String>,
                              placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignTokens.textTertiary)
                .frame(width: 130, alignment: .leading)
            TextField(placeholder, text: binding)
                .textFieldStyle(.roundedBorder)
                .font(DesignTokens.monoSmallFont)
        }
    }

    /// Compose + fire one NotifyCheques send. Pre-fills with active
    /// account's wallet_id (best-effort) when sender field is blank.
    private func runSendNotifyCheques() async {
        // 1. Resolve recipient pubkey (self-counterparty for
        //    loopback) and ed25519 secret bytes.
        guard let self_ = CounterpartyStore.selfEntry else {
            notifyChequesSender.objectWillChange.send()
            return
        }
        let ed25519Bytes: Data
        do {
            ed25519Bytes = try Data(
                contentsOf: URL(fileURLWithPath: selfEd25519SecretPath))
        } catch {
            // surface via state
            return
        }
        guard let atoms = UInt64(sendAmountAtoms) else {
            return
        }
        await notifyChequesSender.send(
            senderWalletId: sendSenderWalletId,
            receiverWalletId: sendReceiverWalletId,
            amountAtoms: atoms,
            swiftReference: sendSwiftReference,
            expectedPieces: [],
            ed25519SecretBytes: ed25519Bytes,
            recipientPubkeyArmored: self_.pgpPublicKey,
            targetEndpoint: sendTargetEndpoint)
    }

    /// Read the self PGP pubkey from disk + register the self
    /// counterparty when all three self-identity fields are set
    /// AND the operator PGP key is loaded. Idempotent — re-running
    /// with the same inputs leaves the entry unchanged.
    ///
    /// When a loopback receiver account is configured the
    /// counterparty's `axiomTierAddress` is bound to that account's
    /// tier address — wire composer routes wallet.send to it.
    /// Otherwise the tier address is a placeholder and the
    /// composer's "Send" button surfaces an error.
    private func refreshSelfCounterparty() {
        guard case .loaded(let fp) = pgpHandler.keyState else {
            CounterpartyStore.selfEntry = nil
            return
        }
        guard !selfPgpPublicPath.isEmpty,
              !selfEd25519PublicHex.isEmpty
        else {
            CounterpartyStore.selfEntry = nil
            return
        }
        let armored: String
        do {
            armored = try String(
                contentsOfFile: selfPgpPublicPath, encoding: .utf8)
        } catch {
            CounterpartyStore.selfEntry = nil
            return
        }
        // Resolve the loopback receiver account → its tier address.
        var receiverTierAddress = "(self — pick a receiver in Settings → Self identity)"
        if !selfLoopbackReceiverId.isEmpty,
           let receiverId = UUID(uuidString: selfLoopbackReceiverId),
           let acct = session.accounts.first(where: { $0.id == receiverId }),
           !acct.tierAddress.isEmpty {
            receiverTierAddress = acct.tierAddress
        }
        // Build the entry. Use the operator name from session if
        // available; otherwise a generic label.
        let displayName = "Self — \(session.operatorName) (this terminal)"
        CounterpartyStore.selfEntry = Counterparty(
            name: displayName,
            bic: "SELFXXXXXXX",
            jurisdiction: "—",
            peerEndpoint: "127.0.0.1:9090",
            relationshipSince: "—",
            axiomTierAddress: receiverTierAddress,
            fxRate: 1.0,
            fxCounterCurrency: "AXC",
            dailyLimit: 0,
            pgpFingerprint: fp,
            pgpPublicKey: armored,
            operatorEd25519PubkeyHex: selfEd25519PublicHex)
    }

    /// Generic file picker used by self-identity rows. Writes the
    /// selected path back into the bound @AppStorage key.
    private func pickSelfFile(into path: Binding<String>,
                                title: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = title
        if panel.runModal() == .OK, let url = panel.url {
            path.wrappedValue = url.path
        }
    }

    /// Mac UNCLE SAM → validator UNCLE gateway client. Bucket 4 —
    /// production-direction flow per AXIOM Origin's 2026-05-31 architectural
    /// correction (UNCLE listens only; UNCLE SAM dials it for both
    /// Status warm-up and PullCheques). This card drives the cross-
    /// process smoke against Linux's :9301.
    private var gatewayClientCard: some View {
        settingsCard(title: "Network — Validator UNCLE gateway (Mac→Linux PullCheques)") {
            HStack(spacing: 10) {
                Text("Endpoint")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .frame(width: 90, alignment: .leading)
                TextField("host:port", text: $gatewayEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.monoSmallFont)
                    .frame(maxWidth: 280)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("UNCLE PGP public key (armoured)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                TextEditor(text: $gatewayPubkeyArmored)
                    .font(DesignTokens.monoSmallFont)
                    .frame(height: 110)
                    .border(DesignTokens.bgTertiary)
            }
            HStack(spacing: 8) {
                Button("Status") {
                    Task {
                        await gatewayClient.status(
                            endpoint: gatewayEndpoint,
                            targetPubkeyArmored: gatewayPubkeyArmored)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(gatewayClient.inFlight
                          || gatewayEndpoint.isEmpty
                          || gatewayPubkeyArmored.isEmpty)
                Button("PullCheques") {
                    Task {
                        await gatewayClient.pullCheques(
                            endpoint: gatewayEndpoint,
                            targetPubkeyArmored: gatewayPubkeyArmored,
                            sinceTick: 0,
                            walletFilter: nil,
                            maxRows: 100)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandNavy)
                .controlSize(.small)
                .disabled(gatewayClient.inFlight
                          || gatewayEndpoint.isEmpty
                          || gatewayPubkeyArmored.isEmpty)
                if gatewayClient.inFlight {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 4)
                }
                Spacer()
            }
            // Last-error row
            if let err = gatewayClient.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                    Text(err.localizedDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.top, 4)
            }
            // StatusResponse panel
            if let s = gatewayClient.lastStatus {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 4) {
                    Text("STATUS RESPONSE")
                        .font(DesignTokens.labelFont)
                        .tracking(0.5)
                        .foregroundStyle(DesignTokens.textTertiary)
                    inboundEvidenceRow(label: "version",
                                       value: s.version)
                    inboundEvidenceRow(label: "uptime",
                                       value: "\(s.uptimeSecs)s")
                    inboundEvidenceRow(label: "pending in/out",
                                       value: "\(s.pendingInbound) / \(s.pendingOutbound)")
                    inboundEvidenceRow(label: "audit tip",
                                       value: s.auditChainTip.prefix(8)
                                          .map { String(format: "%02x", $0) }
                                          .joined() + "…")
                }
            }
            // PullChequesResponse panel
            if let pr = gatewayClient.lastPullResponse {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("PULL CHEQUES RESPONSE — \(pr.cheques.count) row(s)")
                            .font(DesignTokens.labelFont)
                            .tracking(0.5)
                            .foregroundStyle(DesignTokens.textTertiary)
                        Spacer()
                        // New-cheques-ingested chip — fires when the
                        // pull worker added 1+ records to the Inbox.
                        // Zero means every cheque in the response was
                        // already in the store (dedup hit by txid).
                        if gatewayClient.lastIngestedCount > 0 {
                            Text("+\(gatewayClient.lastIngestedCount) NEW IN INBOX")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.4)
                                .foregroundStyle(DesignTokens.statusSettledFg)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DesignTokens.statusSettledBg)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        } else if !pr.cheques.isEmpty {
                            Text("ALL DEDUPED")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.4)
                                .foregroundStyle(DesignTokens.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DesignTokens.bgTertiary)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    if let e = pr.error {
                        Text("daemon error \(e.code): \(e.message)")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.statusRejectedFg)
                            .textSelection(.enabled)
                    }
                    ForEach(pr.cheques) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            inboundEvidenceRow(label: "txid",
                                               value: c.txidHex.prefix(16) + "…")
                            inboundEvidenceRow(label: "receiver",
                                               value: c.receiverWallet)
                            inboundEvidenceRow(label: "sender",
                                               value: c.senderWallet)
                            inboundEvidenceRow(label: "amount",
                                               value: "\(c.amountAtoms) atoms")
                            inboundEvidenceRow(label: "blob size",
                                               value: "\(c.chequeBlob.count) bytes")
                        }
                        .padding(.vertical, 2)
                        Divider().opacity(0.3)
                    }
                    if pr.moreAvailable {
                        Text("more rows available — bump max_rows")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                    Text("Ingested cheques flow into MessageStore as inbound .received records — visible in the Inbox tab with reference 'PULL-' + txid prefix. cheque_blob bytes are the raw witness-signed protocol cheque; decoding + signature verification against validator_ids is the next integration step.")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
            Text("Production-direction flow: Mac UNCLE SAM dials Linux validator UNCLE at host:port, wraps Status / PullCheques in a PGP envelope addressed to UNCLE's operator pubkey, frames with u32 BE length-prefix (matches axiom-uncle/src/listener.rs read_framed). Wire types post-50b7058d (receiver_wallet / sender_wallet are canonical email-form String).")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func nablaNodeRow(_ n: NablaNodeStatus) -> some View {
        HStack(spacing: 0) {
            Text(n.name)
                .font(DesignTokens.monoSmallFont)
                .foregroundStyle(DesignTokens.textPrimary)
                .frame(width: 80, alignment: .leading)
            Text(n.endpoint)
                .font(DesignTokens.monoSmallFont)
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                NablaModeChip(mode: n.mode)
            }
            .frame(width: 110, alignment: .leading)
            HStack(spacing: 4) {
                Circle()
                    .fill(rowStatusColor(n))
                    .frame(width: 6, height: 6)
                Text(rowStatusLabel(n))
                    .font(.system(size: 10))
                    .foregroundStyle(rowStatusColor(n))
            }
            .frame(width: 180, alignment: .leading)
        }
        .padding(.vertical, 5)
    }

    private func rowStatusColor(_ n: NablaNodeStatus) -> Color {
        if n.isProbing { return DesignTokens.textTertiary }
        if !n.online { return DesignTokens.statusRejectedFg }
        if !n.inServiceForSettlement {
            // Online but Provisional — informational only
            return DesignTokens.textTertiary
        }
        return DesignTokens.statusSettledFg
    }

    private func rowStatusLabel(_ n: NablaNodeStatus) -> String {
        if n.isProbing { return "probing…" }
        if !n.online { return "unreachable" }
        if !n.inServiceForSettlement {
            return "not used (institutional policy)"
        }
        return "in service"
    }

    /// Operator identity + role. Lets the demo reviewer switch
    /// between the maker and checker halves of the workflow
    /// without rebuilding. In a real deployment the role would
    /// come from SSO/RBAC and never be self-mutable.
    private var operatorCard: some View {
        settingsCard(title: "Operator session (demo only — real role comes from SSO)") {
            field(label: "Operator name", text: $session.operatorName)
            VStack(alignment: .leading, spacing: 3) {
                Text("Role")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                Picker("", selection: $session.operatorRole) {
                    ForEach(OperatorRole.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            Text("**Maker** composes new wires. **Checker** authorizes (releases pending messages to the UNCLE gateway). **Treasurer** sees per-account balances, bilateral FX, and position-level reporting — does NOT compose or authorize. **Auditor** is read-only across everything. A real production deployment grants exactly one of these to each human — the demo's \"Maker + Checker + Auditor\" gives an executive reviewer the full compose + authorize + balance/audit flow as one identity.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SETTINGS")
                .font(DesignTokens.labelFont)
                .tracking(0.6)
                .foregroundStyle(DesignTokens.textTertiary)
            Text("Institution profile + UNCLE backend configuration")
                .font(.system(size: 20, weight: .medium))
        }
    }

    private var profileCard: some View {
        settingsCard(title: "Institution profile") {
            field(label: "Bank name", text: $session.bankName)
            field(label: "BIC (8 or 11 chars)", text: $session.bankBIC, mono: true)
            field(label: "Wallet email", text: $session.walletEmail, mono: true)
            field(label: "Jurisdiction (ISO 3166-1 alpha-2)",
                  text: $session.jurisdiction, mono: true)
            HStack(spacing: 6) {
                Text("Bank tier")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(session.bankTier.label)
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textPrimary)
                Text("(locked — set at onboarding)")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            if !session.bankTierAddress.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Published tier address (\(session.bankTier.sdkDisplayName))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text(session.bankTierAddress)
                        .font(DesignTokens.monoSmallFont)
                        .foregroundStyle(DesignTokens.textPrimary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DesignTokens.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    @State private var endpoint: String = "0.0.0.0:9301"
    @State private var pgpPath: String = "/etc/uncle/pgp.asc"
    @State private var dbPath: String = "/var/lib/uncle/uncle.db"

    private var endpointCard: some View {
        settingsCard(title: "UNCLE backend") {
            field(label: "Listen address (TCP)", text: $endpoint, mono: true)
            field(label: "PGP keyring path", text: $pgpPath, mono: true)
            field(label: "Audit DB path", text: $dbPath, mono: true)
            HStack(spacing: 8) {
                Button("Test connection") { }
                    .buttonStyle(.bordered)
                Button("View backend status") { }
                    .buttonStyle(.bordered)
            }
        }
    }

    @State private var confirmRotate: Bool = false

    private var keysCard: some View {
        settingsCard(title: "Cryptographic keys") {
            Text("Operator PGP key bound to this terminal. In a real deployment this would be backed by the institution's HSM (PKCS#11) — for the design preview it's a passphrase-protected on-disk key file. Required to decrypt inbound NotifyCheques from counterparties on the peer wire.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Operator key state badge
            HStack(spacing: 8) {
                Circle()
                    .fill(pgpStateColor)
                    .frame(width: 8, height: 8)
                Text(pgpStateLabel)
                    .font(DesignTokens.monoSmallFont)
                Spacer()
            }
            // Key path field + browse button
            HStack(spacing: 8) {
                TextField("/path/to/operator-pgp-secret.asc",
                          text: $operatorPgpKeyPath)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.monoSmallFont)
                Button("Browse…") {
                    selectOperatorKeyFile()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            // Optional passphrase
            HStack(spacing: 8) {
                Text("Passphrase")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .frame(width: 90, alignment: .leading)
                SecureField("(empty for passphrase-less key)",
                            text: $operatorPgpPassphrase)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.monoSmallFont)
            }
            HStack(spacing: 8) {
                Button("Load key") {
                    pgpHandler.loadOperatorKey(
                        path: operatorPgpKeyPath,
                        passphrase: operatorPgpPassphrase.isEmpty
                            ? nil : operatorPgpPassphrase)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandNavy)
                .controlSize(.small)
                .disabled(operatorPgpKeyPath.isEmpty)
                Button("Unload") {
                    pgpHandler.clearOperatorKey()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled({
                    if case .notLoaded = pgpHandler.keyState { return true }
                    return false
                }())
                Spacer()
                Button("Rotate operator key") { confirmRotate = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Export public key") { }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            // Fingerprint display when key is loaded
            if case .loaded(let fp) = pgpHandler.keyState {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 4) {
                    Text("OPERATOR FINGERPRINT")
                        .font(DesignTokens.labelFont)
                        .tracking(0.5)
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text(fp)
                        .font(DesignTokens.monoSmallFont)
                        .textSelection(.enabled)
                    Text("Share this fingerprint with counterparty banks via the same bilateral channel used to exchange their PGP fingerprint. They verify it out-of-band before trusting NotifyCheques from this terminal.")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("⚠ Passphrase stored unencrypted in app preferences for this demo. Production deployments use OS keychain or HSM-side prompt — bank fork-authors should replace this Settings field with the institution's secret-management integration.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.statusPendingFg)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .alert("Rotate operator PGP key?", isPresented: $confirmRotate) {
            Button("Cancel", role: .cancel) {}
            Button("Rotate", role: .destructive) {}
        } message: {
            Text("This generates a new operator keypair. Every counterparty bank in the bilateral arrangement table must be notified of the new public-key fingerprint before they can verify messages from this terminal. Inflight authorized messages remain valid under the old key.")
        }
    }

    private var pgpStateLabel: String {
        switch pgpHandler.keyState {
        case .notLoaded: return "key not loaded"
        case .loaded:    return "key loaded"
        case .failed(let msg): return "load failed — \(msg)"
        }
    }

    private var pgpStateColor: Color {
        switch pgpHandler.keyState {
        case .notLoaded: return DesignTokens.textTertiary
        case .loaded:    return DesignTokens.statusSettledFg
        case .failed:    return DesignTokens.statusRejectedFg
        }
    }

    private func selectOperatorKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select operator PGP secret key"
        panel.message = "Choose the ASCII-armoured .asc (or unarmoured .pgp) file containing the operator's PGP secret key."
        if panel.runModal() == .OK, let url = panel.url {
            operatorPgpKeyPath = url.path
        }
    }

    @State private var retentionYears: String = "7"

    private var retentionCard: some View {
        settingsCard(title: "Audit retention") {
            field(label: "Retention period (years)", text: $retentionYears, mono: true)
            Text("UNCLE audit DB rows are immutable. The retention period is the regulator-mandated minimum (typically 7 years per BCBS / FATF / local). Deletion is hard-deletion after the retention window via a quarterly archive job.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsCard<C: View>(
        title: String,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(DesignTokens.labelFont)
                .tracking(0.5)
                .foregroundStyle(DesignTokens.textTertiary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(DesignTokens.borderSecondary, lineWidth: 0.5)
            )
        }
    }

    private func field(label: String, text: Binding<String>, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignTokens.textTertiary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? DesignTokens.monoFont : .system(size: 12))
        }
    }
}
