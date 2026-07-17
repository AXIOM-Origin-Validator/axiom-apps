import SwiftUI
import AxiomSdk

// =================================================================
// HalRecoverySheet — YPX-020 HAL recovery modal (both phases).
//
// One sheet, two modes (collapsed from the former HalReanchorSheet +
// HalCompleteSheet — §2 made completion a plain redeem, so a separate
// completion sheet earned its keep no longer):
//
//   .reAnchor  — the dead-overlap escape. A wallet whose prior witnesses
//                have all gone away can't meet k-1 S-ABR overlap and is
//                stuck (liveness, never double-spend). hal_reanchor() is a
//                key-proved self-send X→X′ Core CL2 accepts WITHOUT overlap,
//                then HIBERNATES the wallet for the convergence window.
//
//   .complete  — finish recovery. §2: completion is the REDEEM of the
//                re-anchor's distress (dust self-) cheque — hal_complete()
//                does exactly that, and Core's CL5 clears hibernation on the
//                redeem. The normal redeem UI is gated by isHibernating, so
//                this dedicated action is how the distress cheque gets
//                redeemed while the wallet is frozen.
//
// Both are key-proved, validator-witnessed, client-initiated (CLAUDE.md §14)
// and lean on Kiddo as the SMTP relay (same KiddoGate pre-flight). Runs off
// the main thread (DispatchQueue.global — KI#15 beachball fix).
// =================================================================

struct HalRecoverySheet: View {
    enum Mode { case reAnchor, complete }

    @EnvironmentObject private var session: AppSession
    let mode: Mode
    let onCancel: () -> Void
    let onCompletion: () -> Void
    /// .complete only: invoked when a completion round doesn't commit
    /// (Ok(false) / dead-new-quorum) — the host re-opens the re-anchor sheet.
    var onRestart: (() -> Void)? = nil

    @State private var walletKey: String = ""
    @State private var status: HalStatus = .idle
    @State private var errorMessage: String? = nil
    @State private var lastErrorCode: String? = nil
    @State private var startedAt: Date? = nil
    @State private var totalElapsedSecs: Double = 0
    @State private var committed: Bool = false
    @FocusState private var keyFocused: Bool
    @StateObject private var kiddoGate = KiddoGate()

    enum HalStatus { case idle, verifying, running, done, failed }

    private var isComplete: Bool { mode == .complete }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(isComplete ? "FINISH RECOVERY (HAL)" : "RE-ANCHOR WALLET (HAL)")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text(isComplete ? "Finish recovery" : "Recover a stuck wallet")
                .font(DesignTokens.Typography.heading)

            explainer

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("WALLET KEY")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                SecureField("Enter your wallet key", text: $walletKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFocused)
                    .onSubmit(gateThenRun)
                    .disabled(status == .verifying || status == .running || (status == .done && committed))
            }

            if status == .running { progressBlock }
            if status == .done { doneBlock }
            if let errorMessage { failureBlock(message: errorMessage) }

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button((status == .done && committed) ? "Done" : "Cancel",
                       action: (status == .done && committed) ? onCompletion : onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                // Restart escape hatch (.complete only): a completion round that
                // didn't commit (Ok(false)) / errored re-enters HAL via a fresh
                // re-anchor (the dead-new-quorum edge).
                if isComplete, let onRestart,
                   (status == .done && !committed) || status == .failed {
                    Button("Restart…") { onRestart() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
                if !(status == .done && committed) {
                    Button(actionLabel) { gateThenRun() }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignTokens.statusScarredFg)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(walletKey.isEmpty || status == .verifying || status == .running)
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

    // MARK: - Explainer

    @ViewBuilder
    private var explainer: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            if isComplete {
                Text("This wallet is hibernating after a re-anchor. Finishing recovery proves ownership with your key and redeems the re-anchor's distress cheque with a fresh quorum — Core clears the hibernation flag on that redeem and the wallet is live again. It also self-cleans the dust cheque (no dangling bundles).")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Label(
                    "Hibernation does not clear on a timer — this step is what ends it. After it commits, Send and Redeem work again.",
                    systemImage: "checkmark.shield"
                )
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusScarredFg)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                TimelineView(.periodic(from: Date(), by: 1)) { _ in
                    let est = session.hibernationConvergenceEstimateSecs()
                    Text(est > 0
                         ? "Estimated convergence window: \(HalRecovery.estimateLabel(est)) remaining (upper bound — the mesh may converge sooner; you can attempt completion now)."
                         : "Convergence window has passed — completion is likely ready now.")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            } else {
                Text("This wallet's prior validators have gone away, so a normal send can no longer meet the overlap requirement — it's stuck. Re-anchor proves ownership with your key and a fresh validator quorum, without weakening the double-spend protection.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Label(
                    "After re-anchoring, the wallet HIBERNATES. Send and redeem stay paused until you finish recovery — a second, explicit step. It does not clear on its own.",
                    systemImage: "moon.zzz"
                )
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusScarredFg)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    // MARK: - Progress
    //
    // RENDER FIX (YPX-020): the chrome (padding/background/clipShape + static
    // copy) renders ONCE; only the live elapsed readouts sit inside a 0.25 s
    // TimelineView (a whole-block 0.1 s one starved the sheet's top paint).
    @ViewBuilder
    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text(isComplete ? "Finishing recovery" : "Re-anchoring wallet")
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
            TimelineView(.periodic(from: startedAt ?? Date(), by: 0.25)) { context in
                let elapsed = startedAt.map { context.date.timeIntervalSince($0) } ?? 0
                Text(progressHint(elapsed: elapsed))
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.brandPrimarySoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    private func progressHint(elapsed: TimeInterval) -> String {
        if isComplete {
            return elapsed < 6
                ? "Redeeming the re-anchor's distress cheque (the completion) and writing the request to outbox/."
                : "Awaiting fresh validator witnesses; the redeem clears the hibernation flag. Kiddo is relaying via SMTP."
        }
        return elapsed < 6
            ? "Building the key-proved re-anchor (X → X′) and writing the witness request to outbox/."
            : "Awaiting fresh validator witnesses, then Nabla register. Kiddo is relaying via SMTP."
    }

    // MARK: - Done

    @ViewBuilder
    private var doneBlock: some View {
        if committed {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: isComplete ? "checkmark.seal.fill" : "moon.zzz.fill")
                        .foregroundStyle(isComplete ? DesignTokens.statusCleanFg : DesignTokens.statusScarredFg)
                    Text(isComplete ? "Recovery complete — wallet active" : "Re-anchored — wallet hibernating")
                        .font(DesignTokens.Typography.bodyStrong)
                        .foregroundStyle(isComplete ? DesignTokens.statusCleanFg : DesignTokens.statusScarredFg)
                    Spacer()
                    Text(String(format: "%.1f s", totalElapsedSecs))
                        .font(DesignTokens.Typography.monoSmall)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .monospacedDigit()
                }
                if isComplete {
                    Text("The wallet is no longer hibernating. Send and Redeem are enabled again, and the re-anchor's dust cheque self-cleaned — no dangling bundles.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.textPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Send and redeem are paused until you finish recovery. Close this, then use “Finish recovery” on the banner to un-hibernate the wallet — it does not clear on its own.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.textPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    TimelineView(.periodic(from: Date(), by: 1)) { _ in
                        let est = session.hibernationConvergenceEstimateSecs()
                        Text(est > 0
                             ? "Estimated convergence window: \(HalRecovery.estimateLabel(est)) remaining (upper bound)."
                             : "Convergence window passed — likely ready; finish recovery now.")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                }
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isComplete ? DesignTokens.statusCleanBg : DesignTokens.statusScarredBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        } else {
            // Ok(false) — not enough fresh validators witnessed it.
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(isComplete ? "△ Not completed — still hibernating" : "△ Re-anchor not completed")
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Text(isComplete
                     ? "Not enough fresh validators witnessed the completion this round — the wallet is still hibernating, nothing changed. Try again in a moment, or Restart recovery if its new validators are also unreachable (check Settings → Network)."
                     : "Not enough fresh validators witnessed the re-anchor this round. Nothing changed — try again in a moment (check Settings → Network for healthy validators).")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.statusScarredBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        }
    }

    // MARK: - Failure

    @ViewBuilder
    private func failureBlock(message: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Text(isComplete ? "✗ Completion failed" : "✗ Re-anchor failed")
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                if let code = lastErrorCode {
                    Text(code)
                        .font(DesignTokens.Typography.chip)
                        .tracking(0.3)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                        .padding(.horizontal, DesignTokens.Spacing.xxs).padding(.vertical, 1)
                        .background(DesignTokens.statusRejectedBg)
                        .clipShape(Capsule())
                }
                Spacer()
            }
            Text(message)
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
        case .idle:      return isComplete ? "Sign and finish recovery" : "Sign and re-anchor"
        case .verifying: return "Verifying…"
        case .running:   return isComplete ? "Finishing…" : "Re-anchoring…"
        case .done:      return committed ? (isComplete ? "Done" : "Re-anchored") : "Try again"
        case .failed:    return "Try again"
        }
    }

    // MARK: - Driver

    private func gateThenRun() {
        guard !walletKey.isEmpty else { return }
        let email = session.activeWallet?.email() ?? ""
        kiddoGate.check(email: email) { runAction() }
    }

    private func runAction() {
        guard let wallet = session.activeWallet else { return }
        errorMessage = nil
        lastErrorCode = nil
        status = .verifying

        let key = walletKey
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = wallet.verifyWalletKey(walletKey: key)
            if !ok {
                DispatchQueue.main.async {
                    status = .failed
                    errorMessage = "Wrong wallet key."
                }
                return
            }
            DispatchQueue.main.async {
                startedAt = Date()
                status = .running
            }
            do {
                let didCommit = isComplete ? try wallet.halComplete() : try wallet.halReanchor()
                let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
                DispatchQueue.main.async {
                    committed = didCommit
                    totalElapsedSecs = elapsed
                    status = .done
                    // Re-anchor → entered hibernation; complete → cleared it.
                    // Publish either way so every Send/Redeem/Claim/Heal gate
                    // re-evaluates immediately.
                    if didCommit { session.refreshHibernation() }
                }
            } catch {
                let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
                let parts = extractFfiErrorParts(error)
                DispatchQueue.main.async {
                    status = .failed
                    lastErrorCode = parts.code
                    // Re-anchor is exempt from the hibernation gate (restart
                    // hatch), so a hibernation error there is defensive copy.
                    if !isComplete, HalRecovery.isHibernating(code: parts.code, message: parts.message) {
                        errorMessage = HalRecovery.hibernatingMessage()
                    } else {
                        // §2.2.2: the completion redeem shares the OODS
                        // hibernation-exit gate with RECALL — map the
                        // retryable refusal (and any other legible recovery
                        // sentence) to human copy, no raw codes.
                        errorMessage = recallHumanError(fallback: parts.message)
                    }
                    totalElapsedSecs = elapsed
                }
            }
        }
    }
}
