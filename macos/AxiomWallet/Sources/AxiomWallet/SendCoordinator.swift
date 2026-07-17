import SwiftUI
import Foundation
import AxiomSdk

// =================================================================
// SendCoordinator — app-scoped owner of a background send.
//
// The witness round is one blocking FFI call (`wallet.send()`). The
// SignModal used to own that call, so closing the sheet killed the
// view tracking it. The coordinator lifts ownership to the app: the
// SignModal verifies the wallet key, hands off via `start(...)`, and
// dismisses. The round then runs on a detached Task; the user is
// back on the main screen watching `SendProgressBar`.
//
// Progress is read lock-free from the wallet's `sendProgress()`.
// Cancel routes through the lock-free `requestSendCancel()` — honored
// by the SDK only before the final witness hop.
//
// Single-flight: one send per app at a time (the SDK also enforces
// this; `start` just no-ops a second call). Quitting mid-send aborts
// the round — a partial commit recoverable via Heal on next launch;
// there is no on-disk resume (that would need the durable rewrite).
// =================================================================

@MainActor
final class SendCoordinator: ObservableObject {

    /// The send currently in flight.
    struct ActiveSend {
        let wallet: AxiomWallet
        let recipient: String
        let amountAtoms: UInt64
        let startedAt: Date
    }

    /// How a finished send resolved — drives the transient banner.
    enum Outcome {
        case sent(txid: String, newBalance: UInt64)
        case cancelled
        case failed(code: String?, message: String)
    }

    /// Non-nil while a send is in flight. Drives `SendProgressBar`.
    @Published private(set) var active: ActiveSend? = nil
    /// Set when a send resolves; cleared after a few seconds or when
    /// the user dismisses the banner.
    @Published var lastOutcome: Outcome? = nil
    /// True once the user pressed Cancel for the current send — greys
    /// the button and flips the label to "Cancelling…".
    @Published private(set) var cancelRequested: Bool = false

    /// YPX-020 — set when the last send failed with dead-overlap
    /// (`SABRInsufficientOverlap`). Sticky (unlike `lastOutcome`, which
    /// auto-clears in 7s) so the HAL recovery banner stays up until the
    /// user re-anchors or dismisses it. Cleared on the next `start()`,
    /// on a successful re-anchor, or via `clearReanchorOffer()`.
    @Published var deadOverlapNeedsReanchor: Bool = false

    var isSending: Bool { active != nil }

    /// Dismiss the HAL recovery offer (the user declined, or it was
    /// resolved by a re-anchor elsewhere).
    func clearReanchorOffer() { deadOverlapNeedsReanchor = false }

    /// Begin a background send. No-op if one is already running.
    ///
    /// Uses `DispatchQueue.global` instead of `Task.detached` to run
    /// `wallet.send()` truly off the main thread. Swift's
    /// MainActor-isolation inheritance can re-pin a `Task.detached`
    /// closure to the main actor when the enclosing method is itself
    /// `@MainActor` (every `ObservableObject` view-model is in
    /// practice). That manifested here as a beachball for the
    /// **entire** 5-30s witness round: `wallet.send` would land on
    /// main, hold `inner.lock()`, and freeze every click. GCD is
    /// unambiguous — the closure runs on the `.userInitiated` global
    /// queue regardless of caller context, so `wallet.send`'s
    /// blocking lock acquisition + witness round happens off-main
    /// and the UI stays responsive.
    func start(wallet: AxiomWallet,
               recipient: String,
               amountAtoms: UInt64,
               reference: String,
               deliveryEmailOverride: String?) {
        guard active == nil else { return }
        active = ActiveSend(wallet: wallet, recipient: recipient,
                            amountAtoms: amountAtoms, startedAt: Date())
        lastOutcome = nil
        cancelRequested = false
        deadOverlapNeedsReanchor = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Outcome
            var deadOverlap = false
            do {
                // Bank-grade send: same protocol path as send(), but binds the
                // reference as the payment message (SWIFT-MT103 / memo channel)
                // and eagerly retains a verifiable Send Proof to
                // send_proofs/{txid}.cbor the instant the money leaves. The
                // certificate/receipt is then available from the bundle detail.
                let r = try wallet.sendWithProof(
                    to: recipient,
                    amountAtoms: amountAtoms,
                    reference: reference,
                    message: reference.isEmpty ? nil : Data(reference.utf8),
                    deliveryEmailOverride: deliveryEmailOverride
                )
                outcome = .sent(txid: r.txid, newBalance: r.newBalance)
            } catch {
                let parts = extractFfiErrorParts(error)
                // The SDK reports a no-funds-moved cancel as
                // SendCancelled; a cancel after a validator witnessed
                // surfaces as PartialCommit (a real recoverable state).
                deadOverlap = HalRecovery.isDeadOverlap(code: parts.code, message: parts.message)
                outcome = (parts.code == "SendCancelled")
                    ? .cancelled
                    : .failed(code: parts.code, message: parts.message)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.active = nil
                self.cancelRequested = false
                self.lastOutcome = outcome
                // YPX-020: a dead-overlap failure means the wallet is
                // stuck and heal() can't help — offer HAL re-anchor via
                // a sticky banner that outlives the transient outcome.
                if deadOverlap { self.deadOverlapNeedsReanchor = true }
                self.scheduleOutcomeClear(outcome)
            }
        }
    }

    /// Resume an interrupted send round (late-response salvage, 2026-07-07).
    /// A per-hop timeout only means the client stopped waiting — witnessing
    /// has no protocol expiry, so the SDK persisted the round and this
    /// re-enters it: sweep the inbox for responses that arrived late, then
    /// continue the remaining witnesses with the SAME transaction. Same
    /// background/GCD shape as `start` (one blocking FFI call off-main).
    /// Latest-wins: starting a NEW send abandons the saved round instead.
    func resume(wallet: AxiomWallet, resumable: ResumableSendRow) {
        guard active == nil else { return }
        active = ActiveSend(wallet: wallet, recipient: resumable.to,
                            amountAtoms: resumable.amount, startedAt: Date())
        lastOutcome = nil
        cancelRequested = false
        deadOverlapNeedsReanchor = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Outcome
            var deadOverlap = false
            do {
                let r = try wallet.resumeSend()
                outcome = .sent(txid: r.txid, newBalance: r.newBalance)
            } catch {
                let parts = extractFfiErrorParts(error)
                deadOverlap = HalRecovery.isDeadOverlap(code: parts.code, message: parts.message)
                outcome = (parts.code == "SendCancelled")
                    ? .cancelled
                    : .failed(code: parts.code, message: parts.message)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.active = nil
                self.cancelRequested = false
                self.lastOutcome = outcome
                if deadOverlap { self.deadOverlapNeedsReanchor = true }
                self.scheduleOutcomeClear(outcome)
            }
        }
    }

    /// YPX-001 §1.5.1 — re-initiate a scar-consent-paused send with the
    /// receiver's passcode. Same background/GCD shape as `start` (one
    /// blocking FFI call off-main, progress bar via `active`). The
    /// persisted pending record supplies to/amount/reference — NEVER user
    /// input; this call carries only the 6-digit code the receiver shared
    /// out-of-band (entering it IS the documented consent hand-off).
    ///
    /// Outcomes the SendView keys on:
    /// - `.sent` — consent verified, payment completed, record cleared.
    /// - `.failed(ScarConsentRequired, "…rejected by validator…")` — wrong
    ///   passcode; record + stored passcode survive, user re-enters.
    /// - `.failed(ScarConsentRequired, "…not selectable…")` — transient;
    ///   retry shortly, nothing lost.
    /// - `.failed(WalletStateStale, …)` — wallet moved since the pause;
    ///   record discarded, start a fresh send (it re-pauses, new code).
    func completeScarConsent(wallet: AxiomWallet,
                             pending: PendingScarSendRow,
                             passcode: UInt32,
                             ledger: ScarConsentStore? = nil) {
        guard active == nil else { return }
        active = ActiveSend(wallet: wallet, recipient: pending.to,
                            amountAtoms: pending.amount, startedAt: Date())
        lastOutcome = nil
        cancelRequested = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Outcome
            do {
                let r = try wallet.sendWithScarPasscode(passcode: passcode)
                outcome = .sent(txid: r.txid, newBalance: r.newBalance)
            } catch {
                let parts = extractFfiErrorParts(error)
                outcome = .failed(code: parts.code, message: parts.message)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.active = nil
                self.cancelRequested = false
                self.lastOutcome = outcome
                // Permanent Activity-log record: this send row is a
                // consent-gated (scarred-provenance) payment completed
                // with the receiver's passcode. Written on success only —
                // a rejected passcode leaves the pending record up and
                // nothing in history.
                if case .sent(let txid, _) = outcome {
                    ledger?.recordSenderCompletion(
                        txidHex: txid,
                        passcode: passcode,
                        counterparty: pending.to
                    )
                }
                self.scheduleOutcomeClear(outcome)
            }
        }
    }

    /// Ask the SDK to cancel. Honored only before the final witness
    /// request goes out; the client greys the button past that point.
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
            // Only clear if it's still the same banner.
            if case .some = self.lastOutcome { self.lastOutcome = nil }
            _ = shown
        }
    }
}

// =================================================================
// SendProgressBar — the strip shown in the app chrome during a send.
//
// Phases, in order:
//   • Preparing — `sendProgress()` is nil because the SDK hasn't
//     reached the witness round yet (it's building the payload and
//     running the local CL1 Core proof, which can take a few seconds
//     on the first send / a slower Mac). An indeterminate sweep runs
//     across the segments so the bar reads as working rather than
//     stuck at "0 of k" — the gap that prompted this view.
//   • Witnessing — k segments, one lit per validator that returned.
//   • Registering — after all k witnesses returned (Nabla register).
//
// A Cancel button is live through Preparing and the whole Witnessing
// round (including the final hop — the SDK now honors a final-hop cancel
// after a short grace), and greys only once all k witnesses are in and
// the round is registering.
// =================================================================

struct SendProgressBar: View {
    @EnvironmentObject private var coordinator: SendCoordinator

    var body: some View {
        if let active = coordinator.active {
            // Repaint a few times a second so the segments track the
            // lock-free `sendProgress()` snapshot and the Preparing
            // sweep animates.
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                content(active: active, now: context.date)
            }
        }
    }

    @ViewBuilder
    private func content(active: SendCoordinator.ActiveSend,
                         now: Date) -> some View {
        let progress = active.wallet.sendProgress()
        // nil progress = the witness round hasn't opened yet: the SDK
        // is still building + CL1-validating the TX locally.
        let preparing = (progress == nil) && !coordinator.cancelRequested
        let k = max(1, Int(progress?.expectedK ?? 3))
        let responded = min(Int(progress?.responded ?? 0), k)
        let registering = responded >= k
        // Cancel is valid through Preparing and the entire witness round,
        // including the final hop (the SDK honors a final-hop cancel after
        // a short grace). Greyed only once all k are in and we're
        // registering, where there's nothing left to cancel.
        let cancelAllowed = (preparing || responded < k)
            && !coordinator.cancelRequested

        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: 3) {
                    ForEach(0..<k, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(segmentColor(index: i, responded: responded,
                                               k: k, preparing: preparing,
                                               now: now))
                            .frame(height: 4)
                    }
                }
                Text(statusLabel(responded: responded, k: k,
                                 registering: registering,
                                 preparing: preparing))
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(coordinator.cancelRequested ? "Cancelling…" : "Cancel") {
                coordinator.requestCancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!cancelAllowed)
            .help(cancelAllowed
                  ? "Cancel this send. If a validator already witnessed, the wallet will need a Heal afterwards."
                  : "All witnesses are in — the send is registering and can no longer be cancelled.")
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(DesignTokens.brandPrimarySoft)
        .overlay(
            Rectangle().fill(DesignTokens.borderSecondary).frame(height: DesignTokens.hairline),
            alignment: .bottom
        )
    }

    /// Color for one bar segment. During Preparing the witness round
    /// hasn't started, so instead of leaving every segment dim (which
    /// reads as "0 of k, stuck") a single highlighted segment sweeps
    /// left→right to signal the wallet is actively working.
    private func segmentColor(index: Int, responded: Int, k: Int,
                              preparing: Bool, now: Date) -> Color {
        if preparing {
            // ~0.5s per step; %k keeps the sweep within the bar width.
            let step = Int(now.timeIntervalSinceReferenceDate / 0.5) % k
            return index == step
                ? DesignTokens.statusCleanFg.opacity(0.55)
                : DesignTokens.borderTertiary
        }
        return index < responded
            ? DesignTokens.statusCleanFg
            : DesignTokens.borderTertiary
    }

    private func statusLabel(responded: Int, k: Int,
                             registering: Bool,
                             preparing: Bool) -> String {
        if coordinator.cancelRequested {
            return "Cancelling send…"
        }
        if preparing {
            return "Preparing to send — validating transaction…"
        }
        if registering {
            return "All \(k) witnesses in — registering with Nabla…"
        }
        return "Sending — \(responded) of \(k) validators witnessed"
    }
}

// =================================================================
// SendOutcomeBanner — transient strip shown after a send resolves.
// =================================================================

struct SendOutcomeBanner: View {
    @EnvironmentObject private var coordinator: SendCoordinator

    var body: some View {
        if let outcome = coordinator.lastOutcome {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: icon(outcome))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(tint(outcome))
                Text(message(outcome))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DesignTokens.Spacing.xs)
                Button(action: { coordinator.clearOutcome() }) {
                    Image(systemName: "xmark")
                        .font(DesignTokens.Typography.chip)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .frame(maxWidth: .infinity)
            .background(bg(outcome))
            .overlay(
                Rectangle().fill(DesignTokens.borderSecondary).frame(height: DesignTokens.hairline),
                alignment: .bottom
            )
        }
    }

    private func icon(_ o: SendCoordinator.Outcome) -> String {
        switch o {
        case .sent:      return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ o: SendCoordinator.Outcome) -> Color {
        switch o {
        case .sent:      return DesignTokens.statusCleanFg
        case .cancelled: return DesignTokens.textSecondary
        case .failed:    return DesignTokens.statusRejectedFg
        }
    }

    private func bg(_ o: SendCoordinator.Outcome) -> Color {
        switch o {
        case .sent:      return DesignTokens.statusCleanBg
        case .cancelled: return DesignTokens.bgSecondary
        case .failed:    return DesignTokens.statusRejectedBgSoft
        }
    }

    private func message(_ o: SendCoordinator.Outcome) -> String {
        switch o {
        case .sent(_, let bal):
            return "Sent. New balance \(formatBalance(bal))."
        case .cancelled:
            return "Send cancelled — no funds moved."
        case .failed(let code, let msg):
            if code == FactChainCorruption.code {
                return FactChainCorruption.body
            }
            // YPX-001 §1.5.1 scar-consent flavors — the SendView's pending
            // card + passcode sheet carry the full flow; this banner gives
            // the one-line verdict.
            if ScarConsent.isScarConsent(code: code) {
                if ScarConsent.isTransientHop(message: msg) {
                    return "The validator holding the consent passcode wasn't reachable this round — nothing was lost. Retry in a moment."
                }
                if ScarConsent.isWrongPasscode(message: msg) {
                    return "Passcode rejected by the validator — wrong or expired code. Confirm the 6 digits with the receiver and enter it again."
                }
                return "Payment paused — receiver consent required. The receiver has been notified with a passcode; enter it from the card on the Send pane when they share it."
            }
            if code == "WalletStateStale" {
                return "The wallet changed since this payment was prepared — start a fresh send. Nothing was committed."
            }
            if HalRecovery.isHibernating(code: code, message: msg) {
                return HalRecovery.hibernatingMessage()
            }
            if HalRecovery.isDeadOverlap(code: code, message: msg) {
                return "Send can't meet the validator overlap — this wallet's prior validators are gone. Re-anchor (HAL) to recover; see the recovery banner above."
            }
            if code == "PartialCommit" {
                return "Send interrupted after a partial commit — run Heal to recover the wallet."
            }
            return "Send failed: \(msg)"
        }
    }
}
