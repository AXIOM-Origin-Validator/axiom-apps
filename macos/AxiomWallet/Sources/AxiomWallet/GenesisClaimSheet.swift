import SwiftUI
import AxiomSdk

// =================================================================
// GenesisClaimSheet — post-onboarding genesis-claim confirm modal.
//
// Triggered from OverviewView when `canClaimGenesis` is true (wallet
// has wallet_seq == 0 and balance == 0). Users who skipped step 5 of
// onboarding ("Skip — claim later") or whose claim failed land here.
//
// This sheet is PRE-FLIGHT + CONFIRM only. It runs the Kiddo readiness
// gate and the YP §17.11.7 terminal-risk acknowledgement, then hands
// the claim off to the app-scoped `ClaimCoordinator` and dismisses —
// exactly like `RedeemConfirmSheet`. The 5-stage progress, cancel
// affordance, and success/failure detail all live in the app chrome
// (ClaimProgressBanner / ClaimOutcomeBanner) so the witness round
// survives sheet dismissal and never freezes the UI.
//
// Per CLAUDE.md §8 and docs/AXIOM_DESIGN_MacOSReferenceApps.md, the
// wallet writes UMP to outbox/ and blocks on inbox/ — the user's
// carrier (AxiomKiddo.app or the dev env's KIDDO daemon) is the one
// shipping SMTP and dropping inbound cheques. The claim has no timeout
// (it waits indefinitely for the cheques and is cancellable from the
// chrome), so a slow carrier no longer fails a one-shot claim.
// =================================================================

struct GenesisClaimSheet: View {
    @EnvironmentObject private var session: AppSession
    /// App-scoped owner of the background claim. The sheet hands off via
    /// `start(...)` and dismisses; the witness round runs to completion
    /// regardless of whether the sheet is alive.
    @EnvironmentObject private var claimCoordinator: ClaimCoordinator
    let onCancel: () -> Void
    let onCompletion: () -> Void

    /// Surfaced only for the rare synchronous pre-handoff failure
    /// (no active wallet). Every real claim outcome surfaces in the
    /// chrome ClaimOutcomeBanner after hand-off.
    @State private var errorMessage: String? = nil

    /// Hard pre-flight gate. The claim writes UMP to outbox/ and
    /// blocks on inbox/ for k=3 cheques — if AxiomKiddo isn't running
    /// and configured for this wallet's email, every claim hangs
    /// (now indefinitely, since there's no timeout) instead of making
    /// progress. The watcher is constructed lazily (only after the view
    /// has an `activeWallet`); see the lazy unwrap in `onAppear` below.
    @StateObject private var kiddoWatcher: KiddoPreflightWatcher = {
        // Initial email is empty — `onAppear` rebuilds the watcher
        // with the real wallet email once `session.activeWallet` is
        // resolved. SwiftUI doesn't allow `@StateObject` to depend on
        // `@EnvironmentObject` at init time, so we bootstrap empty
        // and configure on appear.
        KiddoPreflightWatcher(walletEmail: "")
    }()

    /// True if the user explicitly chose to bypass the Kiddo gate.
    /// Modal-scoped — closing and reopening the sheet resets it.
    @State private var bypassConfirmed: Bool = false

    /// True once the user has acknowledged the terminal-failure
    /// risk (YP §17.11.7): if the genesis claim fails mid-flight,
    /// the wallet keypair is permanently unusable. Sheet-scoped —
    /// re-opening the sheet requires re-acknowledgement.
    @State private var terminalRiskAcknowledged: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("CLAIM GENESIS")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text("Claim your 1 AXC starter balance")
                .font(DesignTokens.Typography.heading)
            Text("YP §17.11 self-send. One-time claim, valid only while the wallet has wallet_seq=0 and balance=0. Network witnesses it, Nabla registers it, AXC lands. Runs in the background — you can keep using the wallet while it works.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)

            terminalRiskWarning

            // Pre-flight: replace the entire claim panel with a
            // Kiddo-setup prompt if the broadcast path isn't ready.
            // This is the hard gate — it disables the Claim button as
            // well as steering the user to fix the underlying setup.
            if case .ready = kiddoWatcher.state {
                kiddoReadyBanner
            } else if bypassConfirmed {
                kiddoBypassedBanner
            } else {
                kiddoBlockedPanel
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }

            // Genesis de-orchestration — demonstrate BOTH flows (the SDK never
            // auto-redeems; the app drives completion):
            //   • "Claim & redeem" — one-tap convenience: claim, then the app
            //     composes the completion redeem so the wallet funds immediately.
            //   • "Claim — redeem later" — the true 2-step: the genesis cheque lands
            //     PENDING in the Receive tab and the user redeems it there.
            // See docs/AXIOM_DESIGN_SelfTransactions.md.
            VStack(spacing: DesignTokens.Spacing.xs) {
                Button("Claim & redeem (1 AXC)") { startClaim(redeemAfter: true) }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(session.activeWallet == nil
                              || !claimAllowed
                              || claimCoordinator.isClaiming
                              // YPX-020: claim hits fund_genesis->send; rejected while hibernating.
                              || session.isHibernating)

                Button("Claim — redeem later in Receive") { startClaim(redeemAfter: false) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(session.activeWallet == nil
                              || !claimAllowed
                              || claimCoordinator.isClaiming
                              || session.isHibernating)

                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 520)
        .onAppear {
            // Rebuild the watcher around the actual wallet email now
            // that `session` is in scope. The bootstrap watcher (empty
            // email) is harmless — it just always reports
            // `.noAccountForEmail("")` until we replace it.
            if let wallet = session.activeWallet {
                kiddoWatcher.setEmail(wallet.email())
            }
            kiddoWatcher.start()
        }
        .onDisappear { kiddoWatcher.stop() }
    }

    // MARK: - Pre-flight gate

    /// The Claim button is enabled only when (a) the user has
    /// acknowledged the terminal-failure risk (YP §17.11.7), AND
    /// (b) the broadcast path is likely to deliver (Kiddo ready,
    /// or the user has explicitly waived the requirement).
    private var claimAllowed: Bool {
        guard terminalRiskAcknowledged else { return false }
        if case .ready = kiddoWatcher.state { return true }
        return bypassConfirmed
    }

    /// Yellow warning panel + acknowledgement checkbox enforcing
    /// the YP §17.11.7 client UX contract: the user MUST be told
    /// that a failed claim is terminal for this keypair, and MUST
    /// explicitly confirm before the Claim button enables.
    @ViewBuilder
    private var terminalRiskWarning: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.statusScarredFg)
                    .font(DesignTokens.Typography.body)
                Text("Genesis claim is one-shot")
                    .font(DesignTokens.Typography.labelStrong)
                Spacer()
            }
            Text("If this claim fails, what happens depends on the failure mode. Most Nabla cap rejections (per-node, daily cycle) are recoverable — the witness round is preserved and a retry once the cycle resets will resume the claim. Rare terminal failures (validator partial commit, pool fully drained) leave the wallet's keypair permanently unusable; the remedy is to create a new keypair. No funds are lost in either case — no funds existed yet.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("See Yellow Paper §17.11.7 for the full failure-mode taxonomy. AxiomWallet.app is a dev-reference implementation, not production software.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $terminalRiskAcknowledged) {
                Text("I understand: rare terminal failures will require creating a new keypair.")
                    .font(DesignTokens.Typography.caption)
            }
            .toggleStyle(.checkbox)
            .padding(.top, 2)
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusScarredBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    /// Tiny green confirmation when Kiddo is up and configured.
    @ViewBuilder
    private var kiddoReadyBanner: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DesignTokens.statusCleanFg)
                .font(DesignTokens.Typography.label)
            Text("AxiomKiddo is running and configured.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
            Spacer()
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusCleanBg)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    /// Yellow warning when the user has bypassed the gate — keeps
    /// the override visible so it doesn't feel like the gate just
    /// vanished and the user forgets they're flying without Kiddo.
    @ViewBuilder
    private var kiddoBypassedBanner: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.statusScarredFg)
                .font(DesignTokens.Typography.label)
            VStack(alignment: .leading, spacing: 2) {
                Text("Proceeding without AxiomKiddo")
                    .font(DesignTokens.Typography.labelStrong)
                Text("Claim will depend on whatever transport you've configured externally.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            Spacer()
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusScarredBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    /// Full-panel block when Kiddo isn't ready. Steers the user to
    /// the right recovery action; tapping "Continue without Kiddo"
    /// flips `bypassConfirmed` and reveals the claim form.
    @ViewBuilder
    private var kiddoBlockedPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                Text(blockedTitle)
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }
            Text(blockedDetail)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Continue without Kiddo") { bypassConfirmed = true }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Use this if you're relying on a different mail transport (dev FATMAMA env, sendmail, etc.).")
                Spacer()
                if let (label, action) = blockedPrimaryAction {
                    Button(label, action: action)
                        .buttonStyle(.borderedProminent)
                        .tint(DesignTokens.brandPrimary)
                        .controlSize(.regular)
                }
                Button("Refresh") { kiddoWatcher.recheck() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusRejectedBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private var blockedTitle: String {
        switch kiddoWatcher.state {
        case .ready:                  return ""  // unreachable here
        case .notInstalled:           return "AxiomKiddo isn't installed"
        case .notRunning:             return "AxiomKiddo isn't running"
        case .noAccountForEmail(let e): return "Kiddo has no account for \(e)"
        }
    }

    private var blockedDetail: String {
        switch kiddoWatcher.state {
        case .ready:
            return ""
        case .notInstalled:
            return "The wallet looked for \(KiddoPreflight.installPath) and didn't find it. Install AxiomKiddo (same DMG as the wallet, or the dev-build script) and try again."
        case .notRunning:
            return "AxiomKiddo is installed but not running. Launch it from /Applications, then return here — this gate refreshes automatically every second."
        case .noAccountForEmail(let email):
            return "AxiomKiddo is running but isn't configured to relay mail for \(email). Open Kiddo Settings, add an account for this wallet, then return here."
        }
    }

    private var blockedPrimaryAction: (String, () -> Void)? {
        switch kiddoWatcher.state {
        case .ready:                   return nil  // unreachable
        case .notInstalled:            return nil  // user has to install
        case .notRunning:              return ("Launch Kiddo", { KiddoPreflight.launchKiddo() })
        case .noAccountForEmail:       return ("Open Kiddo Settings", { KiddoPreflight.openKiddoForSettings() })
        }
    }

    // MARK: - Action

    /// Hand the claim off to the app-scoped coordinator and dismiss.
    /// Mirrors `RedeemConfirmSheet.broadcast` — the witness round runs
    /// in the background (no beachball, no timeout) and the user watches
    /// the ClaimProgressBanner / ClaimOutcomeBanner in the app chrome.
    /// `redeemAfter` picks the genesis-claim flow (both demoed, de-orchestration):
    ///   false → request leg only; the genesis cheque lands PENDING in Receive and
    ///           the user redeems it there (true 2-step).
    ///   true  → app-composed convenience; claim then redeem so one tap funds.
    private func startClaim(redeemAfter: Bool) {
        guard let wallet = session.activeWallet else {
            errorMessage = "No active wallet."
            return
        }
        errorMessage = nil
        claimCoordinator.start(
            wallet: wallet,
            amountAtoms: 10_000_000_000,
            reference: "genesis-claim",
            redeemAfter: redeemAfter
        )
        onCompletion()
    }
}
