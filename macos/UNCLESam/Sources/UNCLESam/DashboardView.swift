import SwiftUI

// =================================================================
// DashboardView — landing screen. Today's KPIs + recent wires
// table. Mock data; real deployment would query the UNCLE DB.
// =================================================================

struct DashboardView: View {
    @EnvironmentObject private var session: InstitutionSession
    @State private var showSendProofVerify = false

    private let mockRows: [WireRow] = WireRow.mockToday()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                kpiStrip
                recentTable
            }
            .padding(EdgeInsets(top: 22, leading: 28, bottom: 28, trailing: 28))
        }
        .sheet(isPresented: $showSendProofVerify) {
            SendProofVerifyView(onClose: { showSendProofVerify = false })
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DASHBOARD")
                    .font(DesignTokens.labelFont)
                    .tracking(0.6)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("\(session.bankName) · \(todayLong)")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            Spacer()
            Button("Verify Send Proof…") { showSendProofVerify = true }
        }
    }

    private var kpiStrip: some View {
        HStack(spacing: 14) {
            kpiCard(title: "Outbound today",  value: "127.50 AXC",
                    detail: "12 wires", trend: "+18% vs avg")
            kpiCard(title: "Inbound today",   value: "184.32 AXC",
                    detail: "9 wires",  trend: "—")
            kpiCard(title: "Pending settlement", value: "31.20 AXC",
                    detail: "3 wires", trend: "→ within 1 hr", status: .pending)
            kpiCard(title: "Audit records",   value: "4,217",
                    detail: "this month", trend: "retention 7+ yr")
        }
    }

    private func kpiCard(title: String, value: String, detail: String,
                        trend: String, status: KPIStatus = .normal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(DesignTokens.labelFont)
                .tracking(0.5)
                .foregroundStyle(DesignTokens.textTertiary)
            Text(value)
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .foregroundStyle(statusColor(status))
            HStack(spacing: 8) {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.textSecondary)
                Spacer()
                Text(trend)
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
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

    private enum KPIStatus { case normal, pending }
    private func statusColor(_ s: KPIStatus) -> Color {
        switch s {
        case .normal:  return DesignTokens.textPrimary
        case .pending: return DesignTokens.statusPendingFg
        }
    }

    private var recentTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RECENT WIRES (LAST 20)")
                    .font(DesignTokens.labelFont)
                    .tracking(0.5)
                    .foregroundStyle(DesignTokens.textTertiary)
                Spacer()
                Text("Click a row to drill into the wire detail (stubbed in this preview)")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            VStack(spacing: 0) {
                tableHeader
                ForEach(mockRows) { row in
                    tableRow(row)
                    if row.id != mockRows.last?.id {
                        Divider()
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
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("TIME")           .frame(width: 80,  alignment: .leading)
            Text("DIR")            .frame(width: 50,  alignment: .leading)
            Text("REFERENCE")      .frame(width: 140, alignment: .leading)
            Text("COUNTERPARTY")   .frame(maxWidth: .infinity, alignment: .leading)
            Text("AMOUNT")         .frame(width: 140, alignment: .trailing)
            Text("STATUS")         .frame(width: 90,  alignment: .center)
        }
        .font(DesignTokens.labelFont)
        .tracking(0.4)
        .foregroundStyle(DesignTokens.textTertiary)
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))
        .background(DesignTokens.bgTertiary)
    }

    private func tableRow(_ row: WireRow) -> some View {
        HStack(spacing: 0) {
            Text(row.time)
                .font(DesignTokens.monoSmallFont)
                .frame(width: 80, alignment: .leading)
            Text(row.direction.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(row.direction.color)
                .frame(width: 50, alignment: .leading)
            Text(row.reference)
                .font(DesignTokens.monoFont)
                .frame(width: 140, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.counterpartyName)
                    .font(.system(size: 12, weight: .medium))
                Text(row.counterpartyBIC)
                    .font(DesignTokens.monoSmallFont)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.amount)
                .font(DesignTokens.amountFont)
                .frame(width: 140, alignment: .trailing)
            statusBadge(row.status)
                .frame(width: 90, alignment: .center)
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
    }

    private func statusBadge(_ s: WireStatus) -> some View {
        Text(s.label)
            .font(.system(size: 9, weight: .medium))
            .tracking(0.4)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(s.fg)
            .background(s.bg)
            .clipShape(Capsule())
    }

    private var todayLong: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f.string(from: Date())
    }
}

// MARK: - Mock data shapes

struct WireRow: Identifiable {
    let id = UUID()
    let time: String
    let direction: WireDirection
    let reference: String
    let counterpartyName: String
    let counterpartyBIC: String
    let amount: String
    let status: WireStatus

    static func mockToday() -> [WireRow] {
        [
            WireRow(time: "14:23", direction: .out, reference: "UW-260528-A47C12",
                    counterpartyName: "EXPORT FINANCE LTD",
                    counterpartyBIC: "EXPFKHKXXX",
                    amount: "42.80 AXC", status: .settled),
            WireRow(time: "13:51", direction: .in, reference: "MT103-19872",
                    counterpartyName: "BANCO ATLANTICO SA",
                    counterpartyBIC: "BATLESMMXXX",
                    amount: "63.00 AXC", status: .settled),
            WireRow(time: "13:09", direction: .out, reference: "UW-260528-9F032A",
                    counterpartyName: "MERIDIAN BANK CORP",
                    counterpartyBIC: "MRDNGB2LXXX",
                    amount: "12.50 AXC", status: .pending),
            WireRow(time: "12:44", direction: .out, reference: "UW-260528-6BB401",
                    counterpartyName: "DAIIWA NORTH HOLDINGS",
                    counterpartyBIC: "DAIWJPJTXXX",
                    amount: "8.00 AXC", status: .settled),
            WireRow(time: "11:30", direction: .in, reference: "MT103-19868",
                    counterpartyName: "VENTURA TRADE PARTNERS",
                    counterpartyBIC: "VENTUS33XXX",
                    amount: "121.32 AXC", status: .settled),
            WireRow(time: "10:18", direction: .out, reference: "UW-260528-2D8F44",
                    counterpartyName: "FEN HUANG TECH GROUP",
                    counterpartyBIC: "FENGCNSHXXX",
                    amount: "5.00 AXC", status: .rejected),
            WireRow(time: "09:51", direction: .in, reference: "MT103-19864",
                    counterpartyName: "INDIGO HOLDINGS LTD",
                    counterpartyBIC: "INDGAU2SXXX",
                    amount: "18.70 AXC", status: .pending),
        ]
    }
}

enum WireDirection {
    case out, `in`
    var label: String { self == .out ? "OUT" : "IN" }
    var color: Color {
        self == .out ? DesignTokens.statusInfoFg : DesignTokens.brandGold
    }
}

enum WireStatus {
    case settled, pending, rejected
    var label: String {
        switch self {
        case .settled:  return "SETTLED"
        case .pending:  return "PENDING"
        case .rejected: return "REJECTED"
        }
    }
    var fg: Color {
        switch self {
        case .settled:  return DesignTokens.statusSettledFg
        case .pending:  return DesignTokens.statusPendingFg
        case .rejected: return DesignTokens.statusRejectedFg
        }
    }
    var bg: Color {
        switch self {
        case .settled:  return DesignTokens.statusSettledBg
        case .pending:  return DesignTokens.statusPendingBg
        case .rejected: return DesignTokens.statusRejectedBg
        }
    }
}
