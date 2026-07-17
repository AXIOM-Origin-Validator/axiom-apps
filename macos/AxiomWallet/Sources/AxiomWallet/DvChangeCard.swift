import SwiftUI
import AxiomSdk

// =================================================================
// DvChangeCard — shared visual for the L$ digit_version change
// notice. Used by both the launch popup (MainAppView, 3 app starts)
// and the pre-send verify gate (SendView, 3 sends). The caller adds
// its own buttons + outer padding/frame below the card.
//
// Layout: AXC on top (the invariant amount, prominent), then a
// BEFORE → NOW L$ comparison side-by-side in an amber attention box,
// then a short explanation.
// =================================================================
struct DvChangeCard: View {
    /// Reference amount in atoms. For a send this is the amount being
    /// sent; for the launch notice it's 1 AXC.
    let atoms: UInt64
    /// dv before the change (the "BEFORE" L$ scale).
    let fromDV: Int
    /// "1/3" … "3/3" counter shown in the header.
    let counter: String
    /// Header amount label ("YOU ARE SENDING" vs "EXAMPLE: 1 AXC").
    let topLabel: String
    /// Console-published date the change took effect ("2026-06-17"), or
    /// "" to omit the "in effect since" line (feed carried no date).
    var date: String = ""

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Text("L$ display unit changed")
                    .font(DesignTokens.Typography.bodyStrong)
                Spacer()
                Text(counter)
                    .font(DesignTokens.Typography.chip)
                    .foregroundStyle(DesignTokens.textTertiary)
            }

            // AXC on top — the real, invariant amount.
            VStack(spacing: 2) {
                Text(topLabel)
                    .font(DesignTokens.Typography.chip)
                    .tracking(0.6)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(formatAxcOnly(atoms))
                    .font(DesignTokens.Typography.heading)
                    .foregroundStyle(DesignTokens.textPrimary)
                Text("AXC — unchanged")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .frame(maxWidth: .infinity)

            // L$ BEFORE → NOW, side by side.
            HStack(spacing: 0) {
                VStack(spacing: 3) {
                    Text("BEFORE").font(DesignTokens.Typography.chip).tracking(0.6)
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text(formatLdollarShort(atoms: atoms, dv: UInt32(max(0, fromDV))))
                        .font(DesignTokens.Typography.bodyStrong)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                .frame(maxWidth: .infinity)
                Image(systemName: "arrow.right")
                    .foregroundStyle(DesignTokens.statusScarredFg)
                VStack(spacing: 3) {
                    Text("NOW").font(DesignTokens.Typography.chip).tracking(0.6)
                        .foregroundStyle(DesignTokens.statusScarredFg)
                    Text(formatBalance(atoms))
                        .font(DesignTokens.Typography.bodyStrong)
                        .foregroundStyle(DesignTokens.textPrimary)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(DesignTokens.Spacing.md)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.statusScarredBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))

            Text("Same value, same economics — only the L$ label rescaled. AXC is the real unit; you can ignore L$ and use AXC. (White Paper §J.14–J.18)")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if !date.isEmpty {
                VStack(spacing: 1) {
                    Text("IN EFFECT SINCE")
                        .font(DesignTokens.Typography.chip)
                        .tracking(0.6)
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text(date)
                        .font(DesignTokens.Typography.heading)
                        .foregroundStyle(DesignTokens.textPrimary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
