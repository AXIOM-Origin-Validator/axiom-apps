import SwiftUI
import AxiomSdk

// =================================================================
// Scar-consent sender UX (YPX-001 §1.5.1).
//
// A send whose FACT chain carries unresolved scar(s) PAUSES at the
// overlapped validator: the receiver is notified with a 6-digit
// passcode, the sender sees ScarConsentRequired, and the SDK persists
// the paused send at scar_pending/current.cbor. Two views own the
// sender side:
//
//   • ScarConsentPendingCard — shown on the Send pane while a pending
//     record exists (`AxiomWallet.pendingScarSend()` → non-nil), so a
//     paused payment can't be forgotten. `current == false` renders
//     the stale variant (wallet moved; only Discard is offered).
//   • ScarConsentSheet — the passcode-entry sheet. Collects the
//     6-digit code the receiver shared out-of-band and hands off to
//     SendCoordinator.completeScarConsent (background, same shape as
//     a normal send — progress bar + outcome banner).
//
// Mirrors ResumableSendCard's presentation-only discipline: data +
// action closures in, no wallet/coordinator state owned here.
// =================================================================

struct ScarConsentPendingCard: View {
    let row: PendingScarSendRow
    /// Disabled while another wallet op is in flight (single-flight,
    /// YP §32).
    var enterDisabled: Bool = false
    var onEnterPasscode: () -> Void = {}
    var onDiscard: () -> Void = {}

    private var descriptionText: String {
        if !row.current {
            return "A payment of \(formatAxcOnly(row.amount)) to \(row.to) was "
                + "paused for receiver consent, but this wallet has moved since — "
                + "the paused payment can no longer be completed. Discard it and "
                + "start a fresh send; the new send will pause again and the "
                + "receiver will get a new passcode. Nothing was committed and "
                + "no funds moved."
        }
        return "Your payment of \(formatAxcOnly(row.amount)) to \(row.to) is "
            + "paused: the money carries unverified provenance link(s), so the "
            + "validator notified the receiver with a 6-digit passcode. When the "
            + "receiver shares that passcode with you, enter it to complete the "
            + "payment. If they decline, discard — nothing has moved either way."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "hand.raised.circle.fill")
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Text(row.current
                     ? "PAYMENT AWAITING RECEIVER CONSENT"
                     : "PAUSED PAYMENT — STALE")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            Text(descriptionText)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DesignTokens.Spacing.xs) {
                if row.current {
                    Button("Enter passcode", action: onEnterPasscode)
                        .buttonStyle(.borderedProminent)
                        .tint(DesignTokens.brandPrimary)
                        .controlSize(.regular)
                        .disabled(enterDisabled)
                }
                Button("Discard", action: onDiscard)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                Spacer()
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.md, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.md))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusScarredBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }
}

// =================================================================
// ScarConsentSheet — passcode entry.
//
// The user types the 6-digit code the receiver shared out-of-band
// and confirms. The actual FFI call runs in SendCoordinator (app-
// scoped, off-main) — closing this sheet never kills the round (the
// SignModal lesson). Wrong-passcode / transient outcomes surface on
// the SendOutcomeBanner; the pending card persists (the record
// survives a rejection) so the user just opens this sheet again.
// =================================================================

struct ScarConsentSheet: View {
    let row: PendingScarSendRow
    var onCancel: () -> Void
    /// Called with the parsed 6-digit passcode. The presenter hands
    /// off to SendCoordinator.completeScarConsent and dismisses.
    var onSubmit: (UInt32) -> Void

    @State private var passcodeText: String = ""

    /// Exactly 6 digits → the parsed code; nil otherwise.
    private var parsedPasscode: UInt32? {
        let trimmed = passcodeText.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else { return nil }
        return UInt32(trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "hand.raised.circle.fill")
                    .font(DesignTokens.Typography.heading)
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Text(ScarConsent.pausedTitle)
                    .font(DesignTokens.Typography.heading)
            }

            Text(ScarConsent.pausedBody)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            // The paused payment, restated from the persisted record —
            // to/amount are NEVER editable here (they come from the
            // record the validator gated; only the passcode is input).
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                labeledRow("To", row.to)
                labeledRow("Amount", formatAxcOnly(row.amount))
                labeledRow("Transaction", String(row.txidHex.prefix(16)) + "…")
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("6-DIGIT PASSCODE FROM THE RECEIVER")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                TextField("000000", text: $passcodeText)
                    .textFieldStyle(.roundedBorder)
                    .font(Font.system(size: 20, design: .monospaced))
                    .frame(width: 140)
                    .onChange(of: passcodeText) { _, newValue in
                        // Digits only, max 6 — trim anything else as typed.
                        let filtered = String(newValue.filter(\.isNumber).prefix(6))
                        if filtered != newValue { passcodeText = filtered }
                    }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Complete payment") {
                    if let code = parsedPasscode { onSubmit(code) }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandPrimary)
                .disabled(parsedPasscode == nil)
                .help("Re-initiates the SAME transaction with the receiver's passcode. The validator verifies the code (single-use) and the payment completes normally.")
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 480)
    }

    @ViewBuilder
    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Text(label)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textTertiary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(DesignTokens.Typography.monoSmall)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
