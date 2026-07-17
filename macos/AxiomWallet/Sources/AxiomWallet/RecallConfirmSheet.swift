import SwiftUI
import AxiomSdk

// =================================================================
// RecallConfirmSheet — retract a COMPLETED but UNDELIVERED payment
// (YPX-022, repurposed 2026-07-07).
//
// RECALL is for the one failure the social layer cannot fix: a send
// that reached 3-of-3 and debited this wallet, whose cheque never
// reached the receiver (bounced email, dropped connection, dead
// device), and which the receiver has NOT redeemed. It is a
// deliberate, later action on a payment that has sat unclaimed long
// enough to age into the recall window — NOT a reaction to a failed
// send (under the quorum gate a sub-quorum send is a no-op; there is
// no failed-send money to reclaim).
//
// Two-phase at Nabla (§2.2.1): initiate opens a RESERVATION — the
// receiver's cheque stays live and redeemable, and a redeem that
// finalizes during the reservation WINS (the recall aborts cleanly,
// the payment stands). The witnessed recall self-send COMMITS at
// hibernation-entry — the point of no return for the receiver.
//
// Drives the FFI directly: the caller supplies the completed send's
// canonical tx CBOR (from the durable Send Proof store via
// wallet.retainedSendTxCbor(txidHex:)) → wallet.recall(sendTxCbor:).
// The SDK enquires first (query-txid) and surfaces the legible
// refusals before spending the consume-once reservation.
// =================================================================

/// The completed payment a recall targets — assembled by the
/// Sent-payments surface from the history row + Send Proof store.
struct RecallTarget: Identifiable {
    var id: String { txidHex }
    let txidHex: String
    /// The completed send's exact canonical Transaction CBOR
    /// (`retainedSendTxCbor`) — Nabla recomputes the txid from it.
    let txCbor: Data
    /// Human summary for the confirm copy, e.g.
    /// "0.5000 AXC to bob@example.com · sent 2026-07-01 14:02".
    let summary: String
}

struct RecallConfirmSheet: View {
    @EnvironmentObject private var session: AppSession
    let onCancel: () -> Void
    let onCompletion: () -> Void
    /// Fired when a COMMIT is refused because the payment hasn't aged into the
    /// recall window yet ("TOO_EARLY"). Carries the fresh moment so the caller
    /// can re-grey its button with a corrected countdown (a too-early at now
    /// means the payment becomes eligible within one window-low of now — a
    /// tighter estimate than the local send-time guess). Optional.
    var onTooEarly: (() -> Void)? = nil
    /// Two-step, like HAL: `.reclaim` opens the reservation + runs the
    /// witnessed recall self-send + hibernates (recall()); Lambda delivers the
    /// recall cheque to our own inbox. `.complete` redeems that cheque —
    /// crediting the recovered amount AND clearing hibernation
    /// (recall_complete = the shared HAL-style completion).
    var mode: RecallMode = .reclaim
    /// REQUIRED for `.reclaim` — the completed payment being retracted.
    /// Ignored for `.complete`.
    var target: RecallTarget? = nil

    enum RecallMode { case reclaim, complete }

    @State private var walletKey: String = ""
    @State private var status: RecallStatus = .idle
    @State private var errorMessage: String? = nil
    @State private var lastErrorCode: String? = nil
    @State private var startedAt: Date? = nil
    @State private var totalElapsedSecs: Double = 0
    @FocusState private var keyFocused: Bool
    /// Recall does a witnessed self-send + Nabla register — both relay
    /// through Kiddo. Gate it like heal so a dead Kiddo is explicit
    /// before the user commits their key.
    @StateObject private var kiddoGate = KiddoGate()

    enum RecallStatus { case idle, verifying, recalling, done, failed }

    /// Reclaim needs the target payment; complete doesn't (it just redeems the
    /// recall cheque delivered to our own inbox).
    private var canProceed: Bool { mode == .complete || target != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(mode == .complete ? "FINISH RECALL" : "RECALL PAYMENT")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text(mode == .complete ? "Finish the recall" : "Retract a payment")
                .font(DesignTokens.Typography.heading)

            if mode == .complete { completeScopeSummary } else { scopeSummary }

            if mode == .reclaim && target == nil {
                Text("No payment selected. Open a sent payment in Activity and use its Recall button.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusScarredFg)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("WALLET KEY")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                SecureField("Enter your wallet key", text: $walletKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFocused)
                    .onSubmit(runRecall)
                    .disabled(status == .verifying || status == .recalling || status == .done)
            }

            if status == .recalling { recallProgress }
            if status == .done { reclaimedSummary }
            if let errorMessage { failureBlock(message: errorMessage) }

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button(status == .done ? "Done" : "Cancel",
                       action: status == .done ? onCompletion : onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                if status != .done {
                    Button(actionLabel) {
                        let email = session.activeWallet?.email() ?? ""
                        kiddoGate.check(email: email) { runRecall() }
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignTokens.brandPrimary)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(walletKey.isEmpty || !canProceed
                                  || status == .verifying || status == .recalling)
                }
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 480)
        .kiddoGateAlert(kiddoGate)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { keyFocused = true }
        }
    }

    // MARK: - Scope summary

    private var scopeSummary: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            if let target {
                Text(target.summary)
                    .font(DesignTokens.Typography.labelStrong)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Text("This payment completed and debited your balance, but it has sat unclaimed long enough that the cheque likely never reached the receiver. Recalling retracts it and returns the money to you:")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
            Text("• First a reservation opens at the network — the receiver KEEPS PRIORITY: if they redeem while the recall is in progress, the payment stands and the recall aborts.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
            Text("• When the recall commits, the receiver's unredeemed cheque is permanently cancelled network-wide, and a recall cheque for exactly the payment's amount is issued back to you.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
            Text("A payment the receiver already redeemed can never be recalled — first-wins is final. If they still expect the money after a recall, just send again.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .padding(.top, 2)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    // MARK: - Progress / result

    @ViewBuilder
    private var recallProgress: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text(mode == .complete ? "Finishing the recall" : "Recalling the payment")
                    .font(DesignTokens.Typography.labelStrong)
                Spacer()
                TimelineView(.periodic(from: startedAt ?? Date(), by: 0.25)) { context in
                    let elapsed = startedAt.map { context.date.timeIntervalSince($0) } ?? 0
                    Text(String(format: "%.1f s", elapsed))
                        .font(DesignTokens.Typography.mono)
                        .foregroundStyle(DesignTokens.textPrimary)
                        .monospacedDigit()
                }
            }
            Text(mode == .complete
                 ? "Redeeming the recall cheque — this credits the recovered amount and clears the hibernation lock."
                 : "Opening the reservation at the network, then witnessing the recall. The cheque stays redeemable until the recall commits; after that the wallet hibernates while the retract converges — finish the recall afterwards to recover the amount.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.brandPrimarySoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    @ViewBuilder
    private var reclaimedSummary: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Text(mode == .complete ? "✓ Recall finished — amount recovered" : "✓ Recall committed")
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusCleanFg)
                Spacer()
                Text(String(format: "%.1f s", totalElapsedSecs))
                    .font(DesignTokens.Typography.mono)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .monospacedDigit()
            }
            Text(mode == .complete
                 ? "The recall cheque was redeemed — your balance now includes the recovered amount and the wallet is out of hibernation."
                 : "The receiver's unredeemed cheque is permanently cancelled network-wide. Your wallet hibernates while the retract converges — run \"Finish recall\" after the convergence window to redeem the recall cheque and recover the amount.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusCleanBg)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    @ViewBuilder
    private func failureBlock(message: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Text("✗ Recall not performed")
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                Spacer()
                if totalElapsedSecs > 0 {
                    Text(String(format: "%.1f s", totalElapsedSecs))
                        .font(DesignTokens.Typography.monoSmall)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .monospacedDigit()
                }
            }
            Text(recallHumanError(fallback: message))
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusRejectedBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    private var actionLabel: String {
        switch status {
        case .idle:      return mode == .complete ? "Finish recall" : "Recall this payment"
        case .verifying: return "Verifying…"
        case .recalling: return mode == .complete ? "Finishing…" : "Recalling…"
        case .done:      return mode == .complete ? "Finished" : "Recalled"
        case .failed:    return "Try again"
        }
    }

    /// Step-2 explainer — completion is the redeem of the recall cheque.
    private var completeScopeSummary: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("Your recall committed and left the wallet hibernating while the retract converges across the network. Finishing redeems the recall cheque (exactly the retracted payment's amount, delivered back to this wallet), which credits the recovered amount and clears the hibernation lock.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
            Text("This is the same completion HAL uses — one shared self-cheque redeem. Run it after the convergence window (the wallet shows 'hibernating' until then). If the network looks unhealthy the finish is refused and simply retried later — never lost.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .padding(.top, 2)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    // MARK: - Recall driver

    private func runRecall() {
        guard let wallet = session.activeWallet else { return }
        if mode == .reclaim && target == nil { return }
        errorMessage = nil
        lastErrorCode = nil
        status = .verifying

        let ok = wallet.verifyWalletKey(walletKey: walletKey)
        if !ok {
            status = .failed
            errorMessage = "Wrong wallet key."
            return
        }

        startedAt = Date()
        status = .recalling

        Task.detached {
            do {
                // Both FFI calls return a Bool: recall() → did the witnessed
                // commit actually land; recallComplete() → did the recall
                // cheque actually redeem. HONOR IT — a `false` means the op
                // did NOT complete (reservation opened but the commit dropped,
                // or the cheque wasn't redeemable yet). Ignoring it (the old
                // `_ = try …`) reported "✓ committed/finished" on a dropped
                // finalize — the false-success the button then contradicted.
                let succeeded: Bool
                if mode == .complete {
                    succeeded = try wallet.recallComplete()
                } else if let txCbor = target?.txCbor {
                    succeeded = try wallet.recall(sendTxCbor: txCbor)
                } else {
                    succeeded = false
                }
                let totalElapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
                await MainActor.run {
                    totalElapsedSecs = totalElapsed
                    // Recall hibernates the wallet (like HAL) — refresh so
                    // the UI reflects the lock immediately.
                    session.refreshHibernation()
                    if succeeded {
                        status = .done
                    } else {
                        status = .failed
                        errorMessage = mode == .complete
                            ? "The recall didn't finish — the recall cheque wasn't redeemable yet (the convergence window may not have passed, or the network hasn't settled). Nothing was lost; try Finish again in a moment."
                            : "The recall didn't commit — the reservation opened but the witnessed commit didn't complete (usually a slow or flaky network). Nothing was retracted; try Recall again."
                    }
                }
            } catch {
                let totalElapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
                let parts = extractFfiErrorParts(error)
                // Too-early refusal (the protocol's completion-tick gate hadn't
                // opened): tell the caller so it re-greys with a corrected
                // countdown from this fresh moment, instead of the stale
                // send-time estimate.
                let tooEarly = (parts.code ?? "").uppercased().contains("TOO_EARLY")
                    || parts.message.lowercased().contains("too early")
                await MainActor.run {
                    status = .failed
                    lastErrorCode = parts.code
                    errorMessage = parts.message
                    totalElapsedSecs = totalElapsed
                    if tooEarly, mode == .reclaim { onTooEarly?() }
                }
            }
        }
    }
}

// MARK: - Legible error mapping (YPX-022 §2 "legible errors")

/// Map the SDK/Nabla recall + recovery refusals to human copy — no raw
/// codes in dialogs. `register_recall` refusals arrive as an FFI error
/// whose message carries the server's legible sentence verbatim
/// ("register_recall refused (STATUS): <sentence>"); the SDK's pre-enquiry
/// and the commit-phase abort produce their own sentences; the shared
/// hibernation-exit redeem (HAL + RECALL completion) can hit the §2.2.2
/// OODS gate (E_OODS_UNHEALTHY_RETRY — retryable, liveness-only). Every
/// branch here means "nothing was retracted/lost", not a bug.
func recallHumanError(fallback: String) -> String {
    let m = fallback.lowercased()
    // Commit-phase abort — the reservation was open and the receiver's
    // redeem finalized first. Fail-closed, first-wins, payment stands.
    if m.contains("redeemed while the recall was in progress") {
        return "Recall aborted: the receiver redeemed this payment while the recall was in progress — the payment stands. Nothing was retracted, and your wallet recovers on its own (first-wins is final)."
    }
    if m.contains("already been redeemed") || m.contains("(redeemed)") {
        return "The receiver has already redeemed this payment — it was delivered after all, so there is nothing to recall. First-wins is final."
    }
    if m.contains("already been recalled") || m.contains("retract is committed") || m.contains("already_recalled") {
        return "This payment was already recalled — the retract is committed and final. If the recall cheque hasn't been redeemed yet, run \"Finish recall\"."
    }
    if m.contains("nothing to recall") || m.contains("no completed send") || m.contains("not_registered") {
        return "No completed payment was found for this transaction — there is nothing to recall. (A send that never completed debited nothing.)"
    }
    if m.contains("too early") {
        return "Too early to recall — the receiver's protected redeem window is still open. The cheque may still arrive and be redeemed; try again once the payment ages into the recall window."
    }
    if m.contains("too late") {
        return "Too late to recall — this payment has aged past the recall window and the affordance is closed."
    }
    if m.contains("recalled by a different key") || m.contains("conflict") {
        return "A conflicting recall for this payment already exists — nothing was changed."
    }
    if m.contains("e_oods_unhealthy_retry") || m.contains("oods") && m.contains("unhealthy") {
        return "The network looks unhealthy from here (possible partition), so the recall step was refused for safety. Nothing is lost — retry later when the network view recovers."
    }
    return fallback
}
