import SwiftUI

// =================================================================
// The two capability rows and the probe panel for onboarding's mail step.
//
// docs/AXIOM_DESIGN_CarrierHandoff.md §6. The screen configures what this
// Mac CAN use; it does not ask the user to pick a carrier, because there is
// nothing to pick: outgoing is decided per validator at dispatch time, and
// incoming has exactly one option. Email is the requirement the protocol
// obliges every validator to accept; a direct connection is an optimisation
// taken automatically wherever one is offered.
//
// No validator is ever named here. They are interchangeable by design, and
// the seed list is a hint rather than a roster.
// =================================================================

/// A labelled group — the same shell for both rows so they read as one
/// object with two entries, not two unrelated panels.
struct MailSetupRow<Content: View>: View {
    let title: String
    let what: String
    let trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Text(title).font(DesignTokens.Typography.bodyStrong)
                Text(what)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textTertiary)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing.uppercased())
                        .font(DesignTokens.Typography.chip)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.md,
                                bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.md))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.bgSecondary)

            content
        }
        .background(DesignTokens.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel)
                .strokeBorder(DesignTokens.borderSecondary, lineWidth: DesignTokens.hairline)
        )
    }
}

/// One line inside a row: what it is, what it means, and whether it needs
/// anything from the user.
private struct CapabilityLine: View {
    let name: String
    let detail: String
    let chip: String
    let chipFg: Color
    let chipBg: Color

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(DesignTokens.Typography.bodyStrong)
                Text(detail)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DesignTokens.Spacing.xs)
            Text(chip.uppercased())
                .font(DesignTokens.Typography.chip)
                // A chip is a LABEL: a truncated one reads as a different
                // word ("ALWAYS WOR…"), so it must never compress.
                .fixedSize()
                .foregroundStyle(chipFg)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(chipBg)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.chip))
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Outgoing: what this Mac can use to reach validators.
///
/// These are statements, not controls — the carrier is picked per validator
/// from what that validator advertises, not by the user here.
///
/// ⚠ CORRECTED 2026-09-12 (the owner). This comment said "email is mandatory" and
/// the row said "Required. Every validator must accept email". Both put a
/// VALIDATOR obligation on a CLIENT screen. YP §27.5.2a clause 3 binds the
/// validator — "Every validator MUST advertise at least one email address …
/// Other kinds are optional accelerators; email is the floor" — and clause 2
/// says a client "picks the KIND by its carrier preference". Nothing compels
/// a client to send over email: `set_carrier_preference(["tot"])` is a
/// supported client choice (`sdk/client/src/runtime.rs:539`). Email is the
/// universal floor, so supporting it is standard practice for a wallet — it
/// is not a protocol requirement ON the wallet. Say "always works", never
/// "required".
///
/// The developer carrier appears only for a dev-class wallet, and it is
/// ABSENT rather than disabled for a real-email one: ANTIE rejects a
/// class/route disagreement outright, so offering it would offer a
/// transaction that cannot succeed.
struct OutgoingCapabilityRow: View {
    let isDevWallet: Bool

    var body: some View {
        MailSetupRow(title: "Outgoing",
                     what: "how requests reach validators",
                     trailing: "chosen per validator") {
            VStack(spacing: 0) {
                CapabilityLine(
                    name: "Email",
                    detail: "Reaches every validator, because every validator has to publish an email address. That makes it the one carrier that always works — not one you are obliged to use. AxiomKiddo carries it for this wallet.",
                    chip: "always works",
                    chipFg: DesignTokens.brandPrimary,
                    chipBg: DesignTokens.brandPrimarySoft)
                Divider().overlay(DesignTokens.borderTertiary)
                CapabilityLine(
                    name: "Direct connection, where offered",
                    detail: "Faster than mail, and preferred over it. Used automatically whenever a validator advertises one; nothing to turn on.",
                    chip: "automatic",
                    chipFg: DesignTokens.statusCleanFg,
                    chipBg: DesignTokens.statusCleanBg)
                if isDevWallet {
                    Divider().overlay(DesignTokens.borderTertiary)
                    CapabilityLine(
                        name: "Developer carrier",
                        detail: "Reached through the direct connection's tunnel. Only ever used by a developer wallet.",
                        chip: "dev only",
                        chipFg: DesignTokens.statusScarredFg,
                        chipBg: DesignTokens.statusScarredBg)
                }
            }
        }
    }
}

/// The probe's three states, and the button that runs it.
///
/// Failure names the fix rather than the fault, in the order these actually
/// happen. There is no error code on this screen — that belongs in the
/// diagnostic report.
struct MailProbePanel: View {
    let state: MailRoundTripProbe.State
    let canRun: Bool
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            switch state {
            case .idle:
                banner(icon: "envelope",
                       fg: DesignTokens.textSecondary,
                       bg: DesignTokens.bgSecondary,
                       title: "Check that mail reaches this wallet",
                       body: "Sends one message to your own address and waits for it to come back. The claim stays locked until it does.")
            case .running:
                banner(icon: "clock",
                       fg: DesignTokens.textSecondary,
                       bg: DesignTokens.bgSecondary,
                       title: "Checking your mail setup",
                       body: "Sent a test message. Waiting for it to come back — usually a few seconds.")
            case .passed(let secs):
                banner(icon: "checkmark.circle.fill",
                       fg: DesignTokens.statusCleanFg,
                       bg: DesignTokens.statusCleanBgSoft,
                       title: "Mail is working",
                       body: String(format: "Round trip in %.1fs — sent, and it came back to your mailbox.", secs))
            case .failed(let reason):
                banner(icon: "xmark.circle.fill",
                       fg: DesignTokens.statusRejectedFg,
                       bg: DesignTokens.statusRejectedBgSoft,
                       title: "The reply never arrived",
                       body: reason + " Usually one of:",
                       bullets: [
                        "the password is an account password where the provider wants an app password",
                        "the incoming server or port is wrong",
                        "mail is being filtered before it reaches the inbox",
                       ])
            }

            Button(buttonTitle) { onRun() }
                .buttonStyle(.bordered)
                .disabled(!canRun || state == .running)
        }
    }

    private var buttonTitle: String {
        switch state {
        case .idle:    return "Check it works"
        case .running: return "Checking…"
        case .passed:  return "Check again"
        case .failed:  return "Try again"
        }
    }

    @ViewBuilder
    private func banner(icon: String, fg: Color, bg: Color,
                        title: String, body: String,
                        bullets: [String] = []) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon).foregroundStyle(fg)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(fg)
                Text(body)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(bullets, id: \.self) { b in
                    Text("• " + b)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
    }
}
