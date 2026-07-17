import SwiftUI
import AxiomSdk

// =================================================================
// ClaimCoordinator — app-scoped owner of a background genesis claim.
//
// Mirrors `SendCoordinator` / `RedeemCoordinator`. A genesis claim
// (`wallet.claimGenesisFull`) is one long blocking FFI call that runs
// the five claim stages back-to-back (sign → witness → register →
// receive cheques → redeem). Pre-fix it ran inside `GenesisClaimSheet`'s
// `Task.detached`, which had two problems:
//
//   1. Beachball. Swift re-pins a `Task.detached` closure to the main
//      actor when the enclosing type is `@MainActor` (an
//      `ObservableObject` view-model effectively is). The multi-second
//      claim then ran ON MAIN and froze the whole UI — the exact bug
//      the 2026-05-26 SendCoordinator fix solved for send. GCD's
//      `.userInitiated` queue runs the closure off-main regardless of
//      caller context.
//   2. View-scoped lifetime. The claim died if the modal sheet closed.
//
// Like RedeemCoordinator, the claim now lives at the app level and
// survives sheet dismissal: the sheet hands off via `start(...)`,
// dismisses, and the witness round runs to completion with progress +
// outcome shown in the app chrome.
//
// The claim itself has NO timeout (the SDK's cheque-wait loop waits
// indefinitely so a slow network can't fail a potentially-terminal
// claim — YP §17.11.7). The only way to stop it short is a user cancel,
// which routes through the same `requestSendCancel()` AtomicBool send
// and redeem use (the wallet is single-flight) and surfaces as
// `SendCancelled`.
// =================================================================

@MainActor
final class ClaimCoordinator: ObservableObject {

    /// The genesis claim currently in flight.
    struct ActiveClaim {
        let wallet: AxiomWallet
        let amountAtoms: UInt64
        let startedAt: Date
    }

    /// How a finished claim resolved — drives the transient banner.
    enum Outcome {
        /// Success. Carries the rich detail (gross − fees = net
        /// conservation + per-validator witness list + Nabla
        /// registration) so the outcome banner's tap-detail sheet can
        /// render it without re-reading history.
        case claimed(newBalance: UInt64,
                     registration: String,
                     feeBreakdown: [TxFeeShareRow],
                     gross: UInt64)
        /// Genesis de-orchestration (2-step): the request leg succeeded — the
        /// genesis cheque is now PENDING in the Receive tab — but it has NOT been
        /// redeemed, so the wallet is NOT funded yet. The user completes the claim
        /// by redeeming `pendingChequeId` from Receive ("redeem · CLAIM"). Emitted
        /// when the Claim was run WITHOUT the one-tap "Claim & redeem" compose.
        case requested(pendingChequeId: String, registration: String)
        case cancelled
        case needsHeal(code: String?, message: String)
        /// Plain failure. `terminal` is true iff the wallet identity is
        /// permanently unusable (YP §17.11.7.2 — pool-exhausted), per
        /// the SDK's `is_wallet_terminal` field.
        case failed(code: String?, message: String, terminal: Bool)
    }

    /// Non-nil while a claim is in flight. UI can render progress.
    @Published private(set) var active: ActiveClaim? = nil
    /// Set when a claim resolves; cleared after a delay or when the
    /// user dismisses the banner.
    @Published var lastOutcome: Outcome? = nil
    /// True once the user pressed Cancel for the current claim — greys
    /// the button and flips the label to "Cancelling…". Cleared when the
    /// round resolves. Mirrors `RedeemCoordinator.cancelRequested`.
    @Published private(set) var cancelRequested: Bool = false

    var isClaiming: Bool { active != nil }

    /// Begin a background genesis claim. No-op if one is already running.
    ///
    /// Uses `DispatchQueue.global(qos: .userInitiated)` rather than
    /// `Task.detached` for the same MainActor-re-pinning reason
    /// SendCoordinator / RedeemCoordinator do — otherwise the 5-stage
    /// claim beachballs the UI for its full duration.
    /// `redeemAfter` selects the flow (genesis de-orchestration, both demoed):
    ///   • `false` (default) — request leg ONLY: claim leaves the genesis cheque
    ///     PENDING in Receive; the user redeems it there (true 2-step). Resolves
    ///     `.requested`.
    ///   • `true` — convenience 1-tap compose: claim THEN redeem(pendingChequeId)
    ///     so the wallet is funded on a single tap. Resolves `.claimed`.
    /// The compose lives here (the app), never in the SDK (CLAUDE.md §14).
    func start(wallet: AxiomWallet,
               amountAtoms: UInt64,
               reference: String,
               redeemAfter: Bool = false) {
        guard active == nil else { return }
        active = ActiveClaim(wallet: wallet, amountAtoms: amountAtoms,
                             startedAt: Date())
        lastOutcome = nil
        cancelRequested = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Outcome
            do {
                // CLAIM is a 2-step op (genesis de-orchestration, master 45dc832b):
                // `claim_genesis_full` runs the REQUEST leg only — witness round +
                // Nabla register, waits for the k validator cheques to land PENDING
                // — and returns the genesis cheque id WITHOUT redeeming. The wallet
                // is NOT funded on return; the SDK no longer auto-completes ANY
                // special op (CLAUDE.md §14 extended to HAL/HEAL/CLAIM).
                //   • redeemAfter=false → leave the cheque PENDING in Receive for the
                //     user to redeem (true 2-step) → `.requested`.
                //   • redeemAfter=true  → app-composed convenience: redeem it now so a
                //     single tap funds the wallet → `.claimed`.
                // See docs/AXIOM_DESIGN_SelfTransactions.md.
                let r = try wallet.claimGenesisFull(
                    amountAtoms: amountAtoms,
                    reference: reference
                )
                if r.pendingChequeId.isEmpty {
                    // Rare race: the genesis bundle was removed from the pending
                    // store out from under the request leg. Retryable — re-running
                    // the claim resumes from the cheque-wait step.
                    outcome = .failed(
                        code: "ChequeNotReady",
                        message: "Genesis claim registered (txid \(r.txid)) but its "
                            + "cheque isn't available to redeem yet — retry the claim "
                            + "to resume from the cheque-wait step.",
                        terminal: false
                    )
                } else if !redeemAfter {
                    // 2-step: the genesis cheque is now PENDING in Receive. Stop
                    // here — the user completes the claim by redeeming it there.
                    outcome = .requested(
                        pendingChequeId: r.pendingChequeId,
                        registration: r.registration
                    )
                } else {
                    // Convenience compose — redeem now to fund on a single tap. A
                    // normal redeem (Activity shows "redeem · CLAIM"); a PartialCommit
                    // here routes to heal via the catch below, like any redeem.
                    let red = try wallet.redeem(chequeId: r.pendingChequeId)
                    // Pull the just-written Redeem row's fee_breakdown for the
                    // conservation detail (gross − fees = net). limit:5 because
                    // cleanup can append rows; the first redeem since the claim
                    // started is the genesis one. (Off-main — history() is cached.)
                    let recent = wallet.history(limit: 5)
                    let genesisRedeem = recent.first { $0.txType == "redeem" }
                    outcome = .claimed(
                        newBalance: red.newBalance,
                        registration: r.registration,
                        feeBreakdown: genesisRedeem?.feeBreakdown ?? [],
                        gross: genesisRedeem?.amount ?? 0
                    )
                }
            } catch {
                let parts = extractFfiErrorParts(error)
                // SendCancelled is the SDK's "user cancelled" code (same
                // AtomicBool as send/redeem — single-flight wallet).
                // PartialCommit routes to heal. AirdropPoolExhausted is
                // the one genuinely-terminal claim failure (YP
                // §17.11.7.2) — latch the persistent flag so every wallet
                // on this Mac suppresses the Claim CTA. Everything else
                // is a plain failure carrying the terminal classification.
                if parts.code == "SendCancelled" {
                    outcome = .cancelled
                } else if parts.code == "PartialCommit" {
                    outcome = .needsHeal(code: parts.code,
                                         message: parts.message)
                } else {
                    if parts.code == "AirdropPoolExhausted" {
                        PoolExhaustedFlag.set()
                    }
                    outcome = .failed(code: parts.code,
                                      message: parts.message,
                                      terminal: parts.isWalletTerminal)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.active = nil
                self.cancelRequested = false
                self.lastOutcome = outcome
                self.scheduleOutcomeClear(outcome)
            }
        }
    }

    /// Ask the SDK to cancel the in-flight claim. Honored before each
    /// witness hop and on every cheque-wait poll; ignored only on the
    /// final witness hop so the round can finalise (the SDK then cancels
    /// safely at the post-register cheque-wait step). Same underlying
    /// AtomicBool as send (single-flight wallet), so we call
    /// `requestSendCancel` even on the claim path. Mirrors
    /// `RedeemCoordinator.requestCancel`.
    func requestCancel() {
        guard let active, !cancelRequested else { return }
        active.wallet.requestSendCancel()
        cancelRequested = true
    }

    /// Dismiss the transient outcome banner.
    func clearOutcome() { lastOutcome = nil }

    /// Auto-clear the banner after a delay. `.claimed` lingers longer
    /// because its banner is tappable for the conservation detail.
    private func scheduleOutcomeClear(_ shown: Outcome) {
        let delayNs: UInt64
        switch shown {
        case .claimed: delayNs = 20_000_000_000
        default:       delayNs = 9_000_000_000
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self else { return }
            if case .some = self.lastOutcome { self.lastOutcome = nil }
            _ = shown
        }
    }
}

// =================================================================
// ClaimProgressBanner — strip shown in the app chrome during a claim.
//
// Reuses the full 5-stage `ClaimProgressView` (the same one the
// onboarding step uses) for the body — it polls `sdkClaimPhase()` +
// `wallet.sendProgress()` and shows per-stage check/spinner rows plus
// an elapsed ticker. Adds a Cancel button gated behind a warning alert
// whose wording depends on the current stage: cancelling during the
// witness round (before Nabla register) can leave the genesis keypair
// permanently unusable (YP §17.11.7); cancelling once cheques are
// arriving is safe and resumable.
// =================================================================

struct ClaimProgressBanner: View {
    @EnvironmentObject private var coordinator: ClaimCoordinator
    @State private var showCancelAlert: Bool = false

    var body: some View {
        if let active = coordinator.active {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                ClaimProgressView(wallet: active.wallet,
                                  startedAt: active.startedAt)
                Button(coordinator.cancelRequested ? "Cancelling…" : "Cancel") {
                    showCancelAlert = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(coordinator.cancelRequested)
                .help(cancelHelp)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .background(DesignTokens.brandPrimarySoft)
            .overlay(
                Rectangle().fill(DesignTokens.borderSecondary).frame(height: DesignTokens.hairline),
                alignment: .bottom
            )
            .alert("Cancel genesis claim?", isPresented: $showCancelAlert) {
                Button("Keep claiming", role: .cancel) {}
                Button(cancelConfirmLabel, role: .destructive) {
                    coordinator.requestCancel()
                }
            } message: {
                Text(cancelWarning)
            }
        }
    }

    /// Terminal risk only while the witness round is still running
    /// (signing / witnessing, before Nabla register). Once registered
    /// (phase ≥ 3) the witnessed sigs are cached and a retry resumes.
    private var inTerminalWindow: Bool { sdkClaimPhase() <= 2 }

    private var cancelConfirmLabel: String {
        inTerminalWindow ? "Cancel and risk a dead keypair" : "Cancel claim"
    }

    private var cancelWarning: String {
        if inTerminalWindow {
            return "The genesis claim is still collecting validator signatures and hasn't registered with Nabla yet. Cancelling now can leave this wallet's keypair PERMANENTLY UNUSABLE (YP §17.11.7) — some validators may have already witnessed and advanced their per-wallet state, which a one-shot genesis claim cannot recover from. No funds are lost (none existed yet), but you would have to create a new wallet. If you can, wait — the claim has no timeout and will keep working through a slow network."
        }
        return "The genesis send is already witnessed and registered, so cancelling now is safe: the witness round is preserved and claiming again later resumes from where it stopped without re-witnessing. The cheque(s) will be redeemed on the next claim."
    }

    private var cancelHelp: String {
        coordinator.cancelRequested
            ? "Cancel request in flight…"
            : "Cancel this genesis claim."
    }
}

// =================================================================
// ClaimOutcomeBanner — transient banner after a claim resolves.
//
// Parallels SendOutcomeBanner / RedeemOutcomeBanner. The `.claimed`
// case is TAPPABLE: tapping opens a detail sheet with the full
// conservation breakdown (gross − fees = net + per-validator witness
// list), since the sheet that used to show it now dismisses on hand-off.
// =================================================================

struct ClaimOutcomeBanner: View {
    @EnvironmentObject private var coordinator: ClaimCoordinator
    @State private var showDetail: Bool = false

    var body: some View {
        if let outcome = coordinator.lastOutcome {
            content(outcome: outcome)
                .sheet(isPresented: $showDetail) {
                    claimedDetailSheet(outcome)
                }
        }
    }

    @ViewBuilder
    private func content(outcome: ClaimCoordinator.Outcome) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: icon(outcome))
                .foregroundStyle(tint(outcome))
                .font(DesignTokens.Typography.bodyStrong)
            Text(message(outcome))
                .font(DesignTokens.Typography.caption)
                .lineLimit(2)
                .truncationMode(.tail)
            if isClaimed(outcome) {
                Image(systemName: "chevron.right")
                    .font(DesignTokens.Typography.chip)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            Spacer()
            Button(action: { coordinator.clearOutcome() }) {
                Image(systemName: "xmark")
                    .font(DesignTokens.Typography.chip)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm,
                            bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .background(bg(outcome))
        .contentShape(Rectangle())
        .onTapGesture {
            if isClaimed(outcome) { showDetail = true }
        }
    }

    /// Detail sheet for the `.claimed` case — reuses ClaimSuccessDetail.
    @ViewBuilder
    private func claimedDetailSheet(_ outcome: ClaimCoordinator.Outcome) -> some View {
        if case let .claimed(bal, reg, fees, gross) = outcome {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("GENESIS CLAIM")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                ClaimSuccessDetail(newBalance: bal, registration: reg,
                                   feeBreakdown: fees, gross: gross)
                Button("Done") { showDetail = false }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(width: 480)
        } else {
            EmptyView()
        }
    }

    private func isClaimed(_ o: ClaimCoordinator.Outcome) -> Bool {
        if case .claimed = o { return true }
        return false
    }

    private func icon(_ o: ClaimCoordinator.Outcome) -> String {
        switch o {
        case .claimed:   return "checkmark.circle.fill"
        case .requested: return "tray.and.arrow.down.fill"
        case .cancelled: return "xmark.circle.fill"
        case .needsHeal: return "exclamationmark.triangle.fill"
        case .failed:    return "xmark.octagon.fill"
        }
    }

    private func tint(_ o: ClaimCoordinator.Outcome) -> Color {
        switch o {
        case .claimed:   return DesignTokens.statusCleanFg
        case .requested: return DesignTokens.statusCleanFg
        case .cancelled: return DesignTokens.textTertiary
        case .needsHeal: return DesignTokens.statusScarredFg
        case .failed:    return DesignTokens.statusRejectedFg
        }
    }

    private func bg(_ o: ClaimCoordinator.Outcome) -> Color {
        switch o {
        case .claimed:   return DesignTokens.statusCleanBg
        case .requested: return DesignTokens.statusCleanBg
        case .cancelled: return DesignTokens.bgTertiary
        case .needsHeal: return DesignTokens.statusScarredBgSoft
        case .failed:    return DesignTokens.statusRejectedBgSoft
        }
    }

    private func message(_ o: ClaimCoordinator.Outcome) -> String {
        switch o {
        case .claimed(let bal, _, _, _):
            return "Claimed. New balance: \(formatBalance(bal)) — tap for detail"
        case .requested:
            return "Airdrop received — open the Receive tab and redeem it to finish (redeem · CLAIM)."
        case .cancelled:
            return "Genesis claim cancelled. If witnessing had already started, this wallet is spent — use a fresh wallet to claim."
        case .needsHeal(_, let msg):
            return "Claim needs a heal first — \(msg)"
        case .failed(let code, let msg, let terminal):
            let prefix = code.map { "\($0): " } ?? ""
            let tail = terminal
                ? " The wallet keypair is unusable — create a new wallet."
                : ""
            return "Claim failed — \(prefix)\(msg)\(tail)"
        }
    }
}

// =================================================================
// ClaimSuccessDetail — reusable genesis-claim success panel.
//
// Extracted from the old in-sheet success panel so it can be shown
// both in the ClaimOutcomeBanner tap-detail sheet and (optionally) the
// onboarding success step. Renders the conservation row (gross − fees =
// net), the per-validator witness list, and the Nabla registration
// status.
// =================================================================

struct ClaimSuccessDetail: View {
    let newBalance: UInt64
    let registration: String
    let feeBreakdown: [TxFeeShareRow]
    let gross: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("✓ Genesis claim succeeded")
                .font(DesignTokens.Typography.bodyStrong)
                .foregroundStyle(DesignTokens.statusCleanFg)
            // Conservation row — gross cheque − validator fees = net.
            // Shown only when the SDK returned a fee_breakdown; older
            // wallets fall back to the bare "New balance" line.
            if !feeBreakdown.isEmpty {
                let totalFee = feeBreakdown.reduce(UInt64(0)) { $0 &+ $1.amount }
                Text("Cheque: \(formatAxcOnly(gross)) − Validator fees: \(formatAxcOnly(totalFee)) = New balance: \(formatAxcOnly(newBalance))")
                    .font(DesignTokens.Typography.amountCaption)
                    .foregroundStyle(DesignTokens.textSecondary)
                Text("Validators witnessed (\(feeBreakdown.count)):")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                ForEach(feeBreakdown.indices, id: \.self) { idx in
                    let fs = feeBreakdown[idx]
                    HStack(spacing: DesignTokens.Spacing.xxs) {
                        Text(validatorDisplay(fs))
                            .font(DesignTokens.Typography.monoSmall)
                            .foregroundStyle(DesignTokens.textSecondary)
                        Spacer()
                        Text("-\(formatAxcOnly(fs.amount))")
                            .font(DesignTokens.Typography.amountCaption)
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                    .padding(.leading, DesignTokens.Spacing.sm)
                }
            } else {
                Text("New balance: \(formatBalance(newBalance)) · \(formatAxcOnly(newBalance))")
                    .font(DesignTokens.Typography.amount)
            }
            Text("Nabla registration: \(registration)")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
            if registration != "confirmed" {
                Text("Registration didn't fully confirm. The TX is committed locally and will heal on next operation.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineSpacing(2)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusCleanBg)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    /// Operator name if known, else the hex-id prefix (same convention
    /// as ActivityView.validatorDisplay / GenesisClaimSheet).
    private func validatorDisplay(_ fs: TxFeeShareRow) -> String {
        if !fs.validatorName.isEmpty { return fs.validatorName }
        let prefix = fs.validatorIdHex.prefix(8)
        return "\(prefix)…"
    }
}
