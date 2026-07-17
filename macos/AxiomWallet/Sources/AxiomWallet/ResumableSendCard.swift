import SwiftUI
import AxiomSdk

// =================================================================
// ResumableSendCard — the "interrupted send, resumable" affordance.
//
// Extracted from SendView so the LIVE Send pane and the dev-tools
// "Send-state reference" render the EXACT same view (no drift — the
// reference is always what users actually see). Presentation-only:
// the card takes its data + action closures + a disabled flag; it
// owns no wallet/coordinator state.
//
// Shown on the Send pane only while a resumable round exists on disk
// (`AxiomWallet.resumableSend()` → non-nil). A round is resumable when
// a witness hop TIMED OUT (not a rejection, not a completion), the
// quorum wasn't reached, and the wallet hasn't moved since. See
// sdk/client/src/send.rs (pending_round persistence) and
// `resume_send` / `discard_resumable_send` in the FFI.
// =================================================================

struct ResumableSendCard: View {
    let row: ResumableSendRow
    /// Disabled while another wallet op is in flight (single-flight, YP §32)
    /// or the wallet is hibernating. The reference passes `false`.
    var resumeDisabled: Bool = false
    /// `true` in the dev reference so the buttons are inert + labelled.
    var isReference: Bool = false
    var onResume: () -> Void = {}
    var onDiscard: () -> Void = {}

    /// Live cards name the exact payment + progress; the reference render
    /// stays generic (no amount, no signature count) so it can't be mistaken
    /// for an actual pending send you could act on.
    private var descriptionText: String {
        if isReference {
            return "When a send times out waiting for a validator after some witnesses have already signed, it can be resumed — a witness never expires. Resuming picks up any responses that arrived after the timeout and finishes the remaining witnesses with the same transaction. Starting a new send abandons it instead. (This is a reference render; the real card appears on the Send pane only when a send is actually resumable.)"
        }
        return "Your send of \(formatAxcOnly(row.amount)) to \(row.to) timed out waiting for a validator, but \(row.sigsHave) of \(row.sigsNeeded) witnesses had already signed — and a witness never expires. Resuming picks up any responses that arrived after the timeout and finishes the remaining witnesses with the same transaction. Starting a new send abandons it instead."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(DesignTokens.brandPrimary)
                Text("INTERRUPTED SEND — RESUMABLE")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                if isReference {
                    Text("· reference")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
            }
            Text(descriptionText)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Resume send", action: onResume)
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.regular)
                    .disabled(isReference || resumeDisabled)
                Button("Discard", action: onDiscard)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(isReference)
                Spacer()
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.md, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.md))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.brandPrimarySoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    /// Representative sample used by the dev-tools reference + previews so
    /// contributors can see the card without reproducing a timed-out send.
    static var sampleRow: ResumableSendRow {
        ResumableSendRow(
            to: "treasury@axiom.internal/c11838be2f",
            amount: 69_000_000,          // 0.0069 AXC
            sigsHave: 2,
            sigsNeeded: 3,
            createdAtSecs: 0
        )
    }
}
