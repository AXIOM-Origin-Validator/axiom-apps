import SwiftUI
import AxiomSdk

// =================================================================
// HealConfirmSheet — wallet recovery confirmation modal.
//
// Single sheet used by every heal entry point in the app:
//
//   - OverviewView.healCallout    (advisory / required banner)
//   - ActivityView                (per-scar 'Heal' shortcut)
//   - SettingsView.AdvancedSection (Wallet recovery card)
//   - SendView.SignModal failure  (PartialCommit handoff)
//
// Heal analyses wallet state and runs whichever recovery is
// appropriate:
//
//   - CLARA TX_HEAL when poisoned_committers + garbage_state_ids
//     point at a partial-commit recovery.
//   - Burn of a single scarred FACT link when the chain is otherwise
//     clean (drift state empty).
//   - Pending cheque accounting only — no auto-redeem (Receive view
//     is where the user redeems on their own time).
//
// Wallet writes UMP to outbox/, blocks on inbox/. AxiomKiddo (or the
// dev env's KIDDO daemon) ships SMTP and drops inbound cheques.
// =================================================================

struct HealConfirmSheet: View {
    @EnvironmentObject private var session: AppSession
    let onCancel: () -> Void
    let onCompletion: () -> Void

    @State private var walletKey: String = ""
    @State private var status: HealStatus = .idle
    @State private var errorMessage: String? = nil
    @State private var healStartedAt: Date? = nil
    @State private var totalElapsedSecs: Double = 0
    @State private var resultIssuesFound: UInt32 = 0
    @State private var resultIssuesFixed: UInt32 = 0
    @State private var resultHealthy: Bool = false
    @State private var lastErrorCode: String? = nil
    @FocusState private var keyFocused: Bool
    /// Kiddo pre-flight gate. Heal does a self-send witness round
    /// and CLARA register — both depend on Kiddo as the relay. If
    /// Kiddo quit mid-session, the heal hangs at the cheque-wait step.
    /// The gate makes it explicit before the user types their wallet
    /// key.
    @StateObject private var kiddoGate = KiddoGate()

    enum HealStatus { case idle, verifying, healing, done, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("RUN WALLET HEAL")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text(heroTitle)
                .font(DesignTokens.Typography.heading)

            preHealDiagnostic
            scopeSummary

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("WALLET KEY")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                SecureField("Enter your wallet key", text: $walletKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFocused)
                    .onSubmit(runHeal)
                    .disabled(status == .verifying || status == .healing || status == .done)
            }

            if status == .healing {
                healProgress
            }
            if status == .done {
                healedSummary
            }
            if let errorMessage {
                failureBlock(message: errorMessage)
            }

            // YPX-020 defense-in-depth: heal is a returning tx that Core
            // hard-rejects while hibernating (WalletHibernating). Block it
            // at the UI; only HAL completion/restart are allowed in-window.
            if session.isHibernating {
                Text("Wallet is hibernating after a HAL re-anchor — heal is paused (Core would reject it). Finish recovery (Complete HAL) from the recovery banner first.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusScarredFg)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button(status == .done ? "Done" : "Cancel",
                       action: status == .done ? onCompletion : onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                if status != .done {
                    Button(actionLabel) {
                        let email = session.activeWallet?.email() ?? ""
                        kiddoGate.check(email: email) {
                            runHeal()
                        }
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignTokens.statusScarredFg)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .disabled(walletKey.isEmpty || status == .verifying || status == .healing || session.isHibernating)
                }
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 480)
        .kiddoGateAlert(kiddoGate)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                keyFocused = true
            }
        }
    }

    // MARK: - Header

    /// Title adapts to the underlying wallet state — "Recover from N
    /// scars" when the chain is scarred, "Recover from partial commit"
    /// when there's poisoned state, generic "Run wallet recovery"
    /// otherwise (e.g. entry from Settings → Advanced when wallet is
    /// already healthy).
    private var heroTitle: String {
        let scars = session.activeWallet?.factScarCount() ?? 0
        let garbage = session.activeWallet?.garbageStateIdCount() ?? 0
        if garbage > 0 { return "Recover from partial commit" }
        if scars > 0 {
            return "Recover from \(scars) scarred FACT link\(scars == 1 ? "" : "s")"
        }
        return "Run wallet recovery"
    }

    // MARK: - Pre-heal diagnostic

    /// Snapshot of current wallet state. The scar/garbage counts are
    /// informational; the **"Heal pass" verdict is driven by
    /// `wallet.diagnose()`**, not a raw count threshold — CLAUDE.md
    /// §14 (corrected 2026-05-16): a fixed `scar_count > 4` cutoff
    /// has a plateau gap that leaves wallets permanently diverged.
    @ViewBuilder
    private var preHealDiagnostic: some View {
        let scars = session.activeWallet?.factScarCount() ?? 0
        let garbage = session.activeWallet?.garbageStateIdCount() ?? 0
        let scarredLinks = session.activeWallet?.listScarredLinks() ?? []
        let stuck = scarredLinks.reduce(UInt64(0)) { $0 + $1.amount }
        let actions = (try? session.activeWallet?.diagnose()) ?? []
        let recoveryActions = actions.filter {
            ["heal", "burn", "nabla_register"].contains($0.call)
        }
        VStack(spacing: 0) {
            diagnosticRow("Scarred FACT links",
                          value: "\(scars)",
                          warn: scars > 0,
                          hint: scars > 0 ? "Informational — heal is gated by diagnose(), not a count" : nil)
            Divider()
            diagnosticRow("Stuck in scars",
                          value: stuck > 0 ? formatBalance(stuck) : "—",
                          warn: stuck > 0,
                          hint: stuck > 0 ? "Total AXC locked by unresolved scarred links — released as each link burns or retro-confirms" : nil)
            Divider()
            diagnosticRow("Garbage state IDs",
                          value: "\(garbage)",
                          warn: garbage > 0,
                          hint: garbage > 0 ? "Partial commit recorded — CLARA TX_HEAL will fire" : nil)
            Divider()
            diagnosticRow("Heal pass",
                          value: recoveryActions.isEmpty ? "not needed" : "recommended",
                          warn: !recoveryActions.isEmpty,
                          hint: nil)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xxs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xxs, trailing: DesignTokens.Spacing.sm))
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))

        if !recoveryActions.isEmpty {
            diagnoseActionsList(recoveryActions)
        }
        if !scarredLinks.isEmpty {
            scarredLinksList(scarredLinks)
        }
    }

    /// The recovery actions `wallet.diagnose()` recommends, rendered
    /// as a list. This is the authoritative "what heal will do"
    /// surface — each row is one action with its reason. Drives the
    /// heal decision per CLAUDE.md §14.
    @ViewBuilder
    private func diagnoseActionsList(_ actions: [AppDiagnoseAction]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("DIAGNOSE — RECOMMENDED RECOVERY")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                        Text(a.call)
                            .font(DesignTokens.Typography.monoSmall)
                            .foregroundStyle(a.call == "nabla_register"
                                             ? DesignTokens.statusScarredFg
                                             : DesignTokens.statusRejectedFg)
                            .frame(width: 90, alignment: .leading)
                        Text(a.reason)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusScarredBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    /// Compact list of scarred links surfaced under the diagnostic
    /// tiles. Lets the user see *which* TXs are pinned in scars,
    /// not just the count — useful for the KI#5 burn-treadmill state
    /// where the same wallet keeps accumulating new scars while older
    /// ones don't retro-confirm. Bounded by `MAX_FACT_DEPTH`.
    @ViewBuilder
    private func scarredLinksList(_ links: [ScarLinkRow]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("UNRESOLVED LINKS")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            VStack(spacing: 2) {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Text("#\(link.linkIndex)")
                            .font(DesignTokens.Typography.monoSmall)
                            .foregroundStyle(DesignTokens.textTertiary)
                            .frame(width: 32, alignment: .leading)
                        Text(String(link.txidHex.prefix(12)) + "…")
                            .font(DesignTokens.Typography.monoSmall)
                            .foregroundStyle(DesignTokens.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(formatBalance(link.amount))
                            .font(DesignTokens.Typography.amountCaption)
                            .foregroundStyle(DesignTokens.statusScarredFg)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusScarredBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    private func diagnosticRow(_ label: String, value: String,
                               warn: Bool, hint: String?) -> some View {
        // Warn/ok rows carry an SF Symbol alongside the status color
        // so the state is never color-only. The `warn` boolean logic
        // is owned by the callers and unchanged.
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(label))
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.textSecondary)
                Spacer()
                Image(systemName: warn ? "exclamationmark.triangle" : "checkmark.seal")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(warn ? DesignTokens.statusScarredFg : DesignTokens.statusCleanFg)
                Text(value)
                    .font(DesignTokens.Typography.mono)
                    .foregroundStyle(warn ? DesignTokens.statusScarredFg : DesignTokens.statusCleanFg)
            }
            if let hint {
                Text(hint)
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    // MARK: - Scope summary

    private var scopeSummary: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("Heal will run whichever protocol recovery applies to current state:")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
            Text("• Burn a single scarred link if the chain is otherwise clean.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
            Text("• CLARA TX_HEAL if there's drift indicators (poisoned committers / garbage state ids).")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
            Text("Doesn't auto-redeem pending cheques. Cheques arrive on their own time — redeem yourself from the Receive view when ready.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .padding(.top, 2)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    // MARK: - Mid-heal progress

    // RENDER FIX: chrome renders once, only the live readouts tick, at 0.25 s
    // (was a whole-block 0.1 s TimelineView re-compositing the rounded-rect
    // background 10×/sec for the full round — see HalReanchorSheet's note).
    @ViewBuilder
    private var healProgress: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Healing wallet")
                    .font(DesignTokens.Typography.labelStrong)
                Spacer()
                TimelineView(.periodic(from: healStartedAt ?? Date(), by: 0.25)) { context in
                    let elapsed = healStartedAt.map { context.date.timeIntervalSince($0) } ?? 0
                    Text(String(format: "%.1f s", elapsed))
                        .font(DesignTokens.Typography.mono)
                        .foregroundStyle(DesignTokens.textPrimary)
                        .monospacedDigit()
                }
            }
            TimelineView(.periodic(from: healStartedAt ?? Date(), by: 0.25)) { context in
                let elapsed = healStartedAt.map { context.date.timeIntervalSince($0) } ?? 0
                Text(phaseHint(elapsed: elapsed))
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

    private func phaseHint(elapsed: TimeInterval) -> String {
        if elapsed < 4 {
            return "Selecting recovery path (scar burn or CLARA TX_HEAL) and writing the witness request to outbox/."
        } else if elapsed < 20 {
            return "Awaiting witness signatures, then Nabla register / scar burn confirmation."
        } else {
            return "Taking longer than expected — a witness or Nabla call may be hung. Heal will time out at the SDK level shortly."
        }
    }

    // MARK: - Result blocks

    @ViewBuilder
    private var healedSummary: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Text(resultHealthy ? "✓ Wallet healthy" : "△ Heal partial")
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(resultHealthy
                                     ? DesignTokens.statusCleanFg
                                     : DesignTokens.statusScarredFg)
                Spacer()
                Text(String(format: "%.1f s", totalElapsedSecs))
                    .font(DesignTokens.Typography.mono)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .monospacedDigit()
            }
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("Issues found:")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                Text("\(resultIssuesFound)")
                    .font(DesignTokens.Typography.monoSmall)
                Text("·  Fixed:")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                Text("\(resultIssuesFixed)")
                    .font(DesignTokens.Typography.monoSmall)
            }
            if !resultHealthy {
                Text("Some issues remain. Heal again later — CLARA TX_HEAL may need Nabla gossip to converge first.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusScarredFg)
                    .lineSpacing(2)
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(resultHealthy ? DesignTokens.statusCleanBg : DesignTokens.statusScarredBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    @ViewBuilder
    private func failureBlock(message: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Text("✗ Heal failed")
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
                if totalElapsedSecs > 0 {
                    Text(String(format: "%.1f s", totalElapsedSecs))
                        .font(DesignTokens.Typography.monoSmall)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .monospacedDigit()
                }
            }
            Text(actionableHint(for: lastErrorCode, fallback: message))
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

    private func actionableHint(for code: String?, fallback: String) -> String {
        switch code {
        case "NetworkTimeout":
            return "Witness or Nabla call timed out during heal. Likely the same upstream cause as the underlying scar / partial commit. Try again once the network looks healthy (Settings → Network)."
        case "HealNotNeeded":
            return "Wallet is already healthy — nothing to heal."
        case "HealPartial":
            return "Some issues were fixed this pass; others remain. Run heal again later — CLARA TX_HEAL may need Nabla gossip to converge first."
        case "WalletBusy":
            return "Another operation is in flight on this wallet. Wait a moment and try again."
        case nil:
            return fallback
        default:
            return fallback
        }
    }

    private var actionLabel: String {
        switch status {
        case .idle:      return "Sign and heal"
        case .verifying: return "Verifying…"
        case .healing:   return "Healing…"
        case .done:      return resultHealthy ? "Healed" : "Run again"
        case .failed:    return "Try again"
        }
    }

    // MARK: - Heal driver

    private func runHeal() {
        guard let wallet = session.activeWallet else { return }
        // YPX-020 defense-in-depth: never fire heal() while hibernating
        // (Core rejects WalletHibernating). Guards the SecureField
        // onSubmit path that bypasses the disabled action button.
        if session.isHibernating { return }
        errorMessage = nil
        lastErrorCode = nil
        status = .verifying

        let ok = wallet.verifyWalletKey(walletKey: walletKey)
        if !ok {
            status = .failed
            errorMessage = "Wrong wallet key."
            return
        }

        healStartedAt = Date()
        status = .healing

        Task.detached {
            do {
                let result = try wallet.heal()
                let totalElapsed = healStartedAt.map {
                    Date().timeIntervalSince($0)
                } ?? 0
                await MainActor.run {
                    resultIssuesFound = result.issuesFound
                    resultIssuesFixed = result.issuesFixed
                    resultHealthy = result.healthy
                    totalElapsedSecs = totalElapsed
                    status = .done
                    // Don't auto-dismiss — the user needs time to
                    // read the result. The "Cancel" button flips to
                    // "Done" so the user closes explicitly.
                }
            } catch {
                let totalElapsed = healStartedAt.map {
                    Date().timeIntervalSince($0)
                } ?? 0
                let parts = extractFfiErrorParts(error)
                await MainActor.run {
                    status = .failed
                    lastErrorCode = parts.code
                    errorMessage = parts.message
                    totalElapsedSecs = totalElapsed
                }
            }
        }
    }
}
