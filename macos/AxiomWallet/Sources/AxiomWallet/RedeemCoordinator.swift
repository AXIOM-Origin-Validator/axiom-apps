import SwiftUI
import AxiomSdk

// =================================================================
// RedeemCoordinator — app-scoped owner of a background redeem.
//
// Mirrors `SendCoordinator`. The redeem witness round is one
// blocking FFI call (`wallet.redeem(chequeId:)`) that takes
// seconds-to-tens-of-seconds depending on Kiddo / FATMAMA / network
// latency. Pre-fix the call ran inside `BundleDetailView`'s
// `Task.detached`, so the sheet closing (user navigates away,
// switches pairs, dismisses to retry, etc.) killed the task
// mid-flight. The validator's final UMP would land back in
// `inbox/new` carrying a signed witness, but no SDK code was alive
// to consume it — the cheque sat in a half-redeemed state and the
// balance stayed stale.
//
// Worse failure mode this avoids: the SDK's `verify_cheque` step
// (redeem.rs §4.6) REGISTERS a cheque claim with Nabla as a side-
// effect before the witness round starts. Once that claim lands,
// Nabla's `/query-txid` returns `REDEEMED` forever for this txid.
// If the round then times out (or is cancelled by the sheet close),
// the user's retry hits the REDEEMED branch (redeem.rs:344), the
// SDK marks the local cheque redeemed, the file is deleted, and
// the wallet never credits — value locked at validators. Keeping
// the redeem alive past the sheet's lifetime is the only thing
// stopping this from happening on every flaky network.
//
// Same UI affordances as send: a transient outcome banner,
// app-chrome-level progress, single-flight (one redeem at a time
// per app).
// =================================================================

@MainActor
final class RedeemCoordinator: ObservableObject {

    /// The redeem currently in flight.
    struct ActiveRedeem {
        let wallet: AxiomWallet
        let chequeId: String
        let amountAtoms: UInt64
        let sender: String
        let startedAt: Date
    }

    /// How a finished redeem resolved — drives the transient banner.
    enum Outcome {
        case redeemed(newBalance: UInt64, factState: String)
        case cancelled
        case needsHeal(code: String?, message: String)
        case failed(code: String?, message: String)
    }

    /// Non-nil while a redeem is in flight. UI can render a banner.
    @Published private(set) var active: ActiveRedeem? = nil
    /// Set when a redeem resolves; cleared after a few seconds or
    /// when the user dismisses the banner.
    @Published var lastOutcome: Outcome? = nil
    /// True once the user pressed Cancel for the current redeem —
    /// greys the button and flips the label to "Cancelling…". Cleared
    /// when the round resolves. Mirrors `SendCoordinator.cancelRequested`.
    @Published private(set) var cancelRequested: Bool = false

    /// YPX-020 — set when the last redeem failed with dead-overlap
    /// (`SABRInsufficientOverlap`). Sticky; drives the HAL recovery
    /// banner. Mirrors `SendCoordinator.deadOverlapNeedsReanchor`.
    @Published var deadOverlapNeedsReanchor: Bool = false

    var isRedeeming: Bool { active != nil }

    /// Dismiss the HAL recovery offer.
    func clearReanchorOffer() { deadOverlapNeedsReanchor = false }

    /// Begin a background redeem. No-op if one is already running.
    ///
    /// Uses `DispatchQueue.global(qos: .userInitiated)` instead of
    /// `Task.detached` for the same reason SendCoordinator does:
    /// Swift's MainActor-isolation inheritance can re-pin a
    /// `Task.detached` closure to the main actor when the enclosing
    /// method is itself `@MainActor`, which `ObservableObject`
    /// view-models effectively are. That manifests here as a
    /// beachball for the entire 5-30s redeem round. GCD's
    /// `.userInitiated` queue is unambiguous — the closure runs off
    /// main regardless of caller context.
    func start(wallet: AxiomWallet,
               chequeId: String,
               amountAtoms: UInt64,
               sender: String) {
        guard active == nil else { return }
        active = ActiveRedeem(wallet: wallet, chequeId: chequeId,
                              amountAtoms: amountAtoms, sender: sender,
                              startedAt: Date())
        lastOutcome = nil
        cancelRequested = false
        deadOverlapNeedsReanchor = false

        // KI#34 WI2/WI5 — set THIS wallet's incoming-payment check mode on the
        // (process-global) SDK right before the redeem, which is the receive-side
        // verify_cheque path. Single-flight per wallet, so this set is exact; an
        // in-flight check keeps the mode it already captured. Mirrors how the
        // carrier picker pushes carrier_preference before driving an op.
        IncomingCheckPreference.applyToSdk(for: wallet)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Outcome
            var deadOverlap = false
            do {
                let r = try wallet.redeem(chequeId: chequeId)
                outcome = .redeemed(newBalance: r.newBalance,
                                    factState: r.factState)
            } catch {
                let parts = extractFfiErrorParts(error)
                // SendCancelled is the SDK's "user cancelled" code —
                // same AtomicBool as send because the wallet is
                // single-flight. Maps to the cancelled outcome.
                // PartialCommit routes to heal.  Everything else is
                // a plain failure with the SDK's code+message.
                deadOverlap = HalRecovery.isDeadOverlap(code: parts.code, message: parts.message)
                if parts.code == "SendCancelled" {
                    outcome = .cancelled
                } else if parts.code == "PartialCommit" {
                    outcome = .needsHeal(code: parts.code,
                                         message: parts.message)
                } else {
                    outcome = .failed(code: parts.code,
                                      message: parts.message)
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.active = nil
                self.cancelRequested = false
                self.lastOutcome = outcome
                // YPX-020: dead-overlap on redeem is the same stuck-wallet
                // condition as send — offer HAL re-anchor.
                if deadOverlap { self.deadOverlapNeedsReanchor = true }
                self.scheduleOutcomeClear(outcome)
            }
        }
    }

    /// Ask the SDK to cancel the in-flight redeem. Honored only
    /// before the final witness response makes the running total
    /// reach k; the SDK ignores the flag on the final hop so the
    /// round can finalise. UI must grey the Cancel button at that
    /// point — see RedeemProgressBanner. Same underlying AtomicBool
    /// as send (single-flight wallet), so we call
    /// `requestSendCancel` on the FFI even though this is the
    /// redeem path. Mirrors `SendCoordinator.requestCancel`.
    func requestCancel() {
        guard let active, !cancelRequested else { return }
        active.wallet.requestSendCancel()
        cancelRequested = true
    }

    /// Dismiss the transient outcome banner.
    func clearOutcome() { lastOutcome = nil }

    /// Auto-clear the banner after a delay, unless a newer outcome
    /// replaced it in the meantime.
    private func scheduleOutcomeClear(_ shown: Outcome) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard let self else { return }
            if case .some = self.lastOutcome { self.lastOutcome = nil }
            _ = shown
        }
    }
}

// =================================================================
// RedeemProgressBanner — strip shown in the app chrome during a
// redeem.
//
// No per-validator progress polling (the SDK doesn't expose a
// `redeemProgress()` FFI yet — redeem is shorter than send and the
// witness ordering is less informative). A spinner + sender row is
// enough to signal "still working, don't quit, the cheque is being
// redeemed in the background."
// =================================================================

struct RedeemProgressBanner: View {
    @EnvironmentObject private var coordinator: RedeemCoordinator
    /// Drives the cancel-confirmation alert. Cancelling mid-witness-
    /// round can leave the wallet in a partially-committed state
    /// (some validators advanced their ledger, the wallet's local
    /// receipt was never built), so the warning explicitly names the
    /// heal / burn recovery the user may need to run afterwards.
    @State private var showCancelAlert: Bool = false

    var body: some View {
        if let active = coordinator.active {
            // Repaint every 0.25s so the k segments + elapsed counter
            // track the lock-free sendProgress() snapshot (the SDK's
            // progress atomics are shared with send because the
            // wallet is single-flight). Mirrors SendProgressBar.
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                content(active: active)
            }
            .alert("Cancel redeem?", isPresented: $showCancelAlert) {
                Button("Keep redeeming", role: .cancel) {}
                Button("Cancel and risk a stuck wallet",
                       role: .destructive) {
                    coordinator.requestCancel()
                }
            } message: {
                Text("Cancelling now can leave the wallet partially committed: some validators have already witnessed and advanced their ledger, while your wallet's receipt was never built. Recovery REQUIRES running Heal or Burn from Activity afterwards — without it the wallet is unusable for any further send / redeem / claim. The cheque file stays on disk; no funds are lost, but the recovery path is mandatory, not optional.")
            }
        }
    }

    @ViewBuilder
    private func content(active: RedeemCoordinator.ActiveRedeem) -> some View {
        // Pull the live progress from the wallet's atomic slot — same
        // slot send writes to, since the wallet is single-flight. k
        // is latched at round entry by begin_send_progress(k); each
        // accepted witness sig bumps `responded` from the SDK side.
        let progress = active.wallet.sendProgress()
        let k = max(1, Int(progress?.expectedK ?? 3))
        let responded = min(Int(progress?.responded ?? 0), k)
        let registering = responded >= k
        // Cancel is live through the whole witness round, including the
        // final hop (the SDK honors a final-hop cancel after a short
        // grace). Mirror SendProgressBar's gate: greyed only once all k
        // are in and the round is registering.
        let cancelAllowed = responded < k
            && !coordinator.cancelRequested

        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: 3) {
                    ForEach(0..<k, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i < responded
                                  ? DesignTokens.statusCleanFg
                                  : DesignTokens.borderTertiary)
                            .frame(height: 4)
                    }
                }
                Text(statusLabel(active: active, responded: responded,
                                 k: k, registering: registering))
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(coordinator.cancelRequested ? "Cancelling…" : "Cancel") {
                showCancelAlert = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!cancelAllowed)
            .help(cancelAllowed
                  ? "Cancel this redeem. If a validator has already witnessed, the wallet will need Heal or Burn from Activity afterwards."
                  : (coordinator.cancelRequested
                     ? "Cancel request in flight…"
                     : "All witnesses are in — the redeem is registering and can no longer be cancelled."))
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(DesignTokens.brandPrimarySoft)
        .overlay(
            Rectangle().fill(DesignTokens.borderSecondary).frame(height: DesignTokens.hairline),
            alignment: .bottom
        )
    }

    private func statusLabel(active: RedeemCoordinator.ActiveRedeem,
                             responded: Int, k: Int,
                             registering: Bool) -> String {
        // k here is the FFI-reported expected_k, which the SDK sets
        // to (validator_count + 1) — segment 0 is the §4.6 Nabla
        // pre-flight (cheque-claim register), segments 1..k are
        // per-validator witnesses. So `k - 1` is the validator
        // count, `responded - 1` is the number of validator
        // witnesses we've collected so far (responded=0 → still
        // registering, responded=1 → register done, no witnesses
        // yet, etc).
        if coordinator.cancelRequested {
            return "Cancelling redeem…"
        }
        let validatorTotal = max(1, k - 1)
        if registering {
            return "All \(validatorTotal) witnesses in — finalising cheque \(formatBalance(active.amountAtoms))…"
        }
        if responded == 0 {
            return "Registering cheque-claim with Nabla…"
        }
        let validatorsIn = max(0, responded - 1)
        if validatorsIn == 0 {
            return "Nabla register ✓ — awaiting validator witnesses for \(formatBalance(active.amountAtoms))"
        }
        return "Nabla register ✓ — \(validatorsIn) of \(validatorTotal) validators witnessed \(formatBalance(active.amountAtoms))"
    }
}

// =================================================================
// RedeemOutcomeBanner — transient banner after redeem resolves.
//
// Parallels the SendOutcomeBanner pattern. Auto-dismisses after a
// few seconds; user can tap to dismiss earlier.
// =================================================================

struct RedeemOutcomeBanner: View {
    @EnvironmentObject private var coordinator: RedeemCoordinator

    var body: some View {
        if let outcome = coordinator.lastOutcome {
            content(outcome: outcome)
        }
    }

    @ViewBuilder
    private func content(outcome: RedeemCoordinator.Outcome) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: icon(outcome))
                .foregroundStyle(tint(outcome))
                .font(DesignTokens.Typography.bodyStrong)
            Text(message(outcome))
                .font(DesignTokens.Typography.caption)
                .lineLimit(2)
                .truncationMode(.tail)
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
    }

    private func icon(_ o: RedeemCoordinator.Outcome) -> String {
        switch o {
        case .redeemed:  return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .needsHeal: return "exclamationmark.triangle.fill"
        case .failed:    return "xmark.octagon.fill"
        }
    }

    private func tint(_ o: RedeemCoordinator.Outcome) -> Color {
        switch o {
        case .redeemed:  return DesignTokens.statusCleanFg
        case .cancelled: return DesignTokens.textTertiary
        case .needsHeal: return DesignTokens.statusScarredFg
        case .failed:    return DesignTokens.statusRejectedFg
        }
    }

    private func bg(_ o: RedeemCoordinator.Outcome) -> Color {
        switch o {
        case .redeemed:  return DesignTokens.statusCleanBg
        case .cancelled: return DesignTokens.bgTertiary
        case .needsHeal: return DesignTokens.statusScarredBgSoft
        case .failed:    return DesignTokens.statusRejectedBgSoft
        }
    }

    private func message(_ o: RedeemCoordinator.Outcome) -> String {
        switch o {
        case .redeemed(let bal, _):
            return "Redeemed. New balance: \(formatBalance(bal))"
        case .cancelled:
            return "Redeem cancelled. Cheque preserved — you can retry."
        case .needsHeal(_, let msg):
            return "Redeem needs a heal first — \(msg)"
        case .failed(let code, let msg):
            if code == FactChainCorruption.code {
                return FactChainCorruption.body
            }
            // Nabla refuses an in-window cheque-claim with a bare
            // "HIBERNATING"; Core refuses an in-window self-redeem with
            // E_WALLET_HIBERNATING. Show the friendly window message.
            if HalRecovery.isHibernating(code: code, message: msg) {
                return HalRecovery.hibernatingMessage()
            }
            if HalRecovery.isDeadOverlap(code: code, message: msg) {
                return "Redeem can't meet the validator overlap — this wallet's prior validators are gone. Re-anchor (HAL) to recover; see the recovery banner above."
            }
            let prefix = code.map { "\($0): " } ?? ""
            return "Redeem failed — \(prefix)\(msg)"
        }
    }
}
