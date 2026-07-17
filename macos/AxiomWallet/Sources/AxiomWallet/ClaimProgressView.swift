import SwiftUI
import AxiomSdk

// =================================================================
// ClaimProgressView — live 5-stage progress panel for a genesis
// claim. Shared by the post-onboarding GenesisClaimSheet and the
// onboarding GenesisStep.
//
// A genesis claim (`wallet.claimGenesisFull`) is a single blocking
// FFI call that runs five stages back-to-back. The SDK publishes a
// coarse phase code (`sdkClaimPhase()`, 0-6) as it moves through
// them, and finer N-of-k progress for the witness stage
// (`wallet.sendProgress()`). This view renders a step list — one row
// per stage, the active row spinning, completed rows checked — plus
// an elapsed-seconds ticker so the screen always shows motion.
//
// Phase codes (mirror `axiom_sdk::send::claim_phase`):
//   0 idle · 1 signing · 2 witnessing · 3 registering ·
//   4 receiving · 5 redeeming · 6 complete
//
// NOTE (genesis de-orchestration, master 45dc832b): the CLAIM REQUEST leg
// (`claim_genesis_full`) now ends at 4 (receiving) → 6 (complete: cheque is
// PENDING). It NO LONGER emits 5 (redeeming) — the SDK doesn't redeem. Stage 5
// below ("Redeeming cheques") is the APP-COMPOSED completion redeem the
// ClaimCoordinator chains after the request leg; its fine-grained progress is the
// redeem's own `sendProgress()`, not a claim phase. (Cosmetic follow-up: drive
// stage 5 off the composed redeem's send_progress for an exact bar.)
// =================================================================
struct ClaimProgressView: View {
    /// Wallet whose `sendProgress()` atomics we poll for the witness
    /// stage's N-of-k counter. Optional so the caller can pass
    /// `session.activeWallet` directly.
    let wallet: AxiomWallet?
    /// Wall-clock instant the broadcast began — drives the ticker.
    let startedAt: Date
    /// k assumed before the SDK's live witness counter latches.
    /// Genesis is standard-tier k=3.
    var fallbackK: UInt32 = 3

    /// One stage of the claim. `phase` is the `sdkClaimPhase()` code
    /// at which this stage is the active one.
    private struct Stage {
        let phase: UInt8
        let title: String
    }
    private let stages: [Stage] = [
        Stage(phase: 1, title: "Signing the transaction"),
        Stage(phase: 2, title: "Collecting validator signatures"),
        Stage(phase: 3, title: "Registering with Nabla"),
        Stage(phase: 4, title: "Receiving validator cheques"),
        Stage(phase: 5, title: "Redeeming cheques"),
    ]

    var body: some View {
        // 10Hz redraw — re-reads the elapsed time, the SDK claim
        // phase, and the witness-round counter. All three are cheap
        // (atomic loads).
        TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            // `sdkClaimPhase()` can momentarily read 0 (idle) in the
            // sliver before the SDK sets stage 1 — clamp so the first
            // row shows as active rather than the whole list pending.
            let phase = max(1, sdkClaimPhase())
            let progress = wallet?.sendProgress()
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                header(elapsed: elapsed)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    ForEach(stages, id: \.phase) { stage in
                        stageRow(stage, currentPhase: phase, progress: progress)
                    }
                }
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.brandPrimarySoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        }
    }

    // MARK: - Header

    private func header(elapsed: TimeInterval) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claiming 1 AXC")
                .font(DesignTokens.Typography.labelStrong)
            Spacer()
            // Elapsed ticker — the primary "it's not frozen" signal.
            // Monospaced digits so it doesn't jitter.
            Text(String(format: "%.1f s", elapsed))
                .font(DesignTokens.Typography.mono)
                .foregroundStyle(DesignTokens.textSecondary)
                .monospacedDigit()
        }
    }

    // MARK: - Stage row

    private enum StageState { case done, active, pending }

    @ViewBuilder
    private func stageRow(
        _ stage: Stage,
        currentPhase: UInt8,
        progress: AppSendProgress?
    ) -> some View {
        let state: StageState =
            currentPhase > stage.phase ? .done
            : currentPhase == stage.phase ? .active
            : .pending

        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
            stageIcon(state)
                .frame(width: 14)

            Text(stage.title)
                .font(state == .active
                      ? DesignTokens.Typography.sectionLabel
                      : DesignTokens.Typography.caption)
                .foregroundStyle(
                    state == .pending
                        ? DesignTokens.textTertiary
                        : DesignTokens.textPrimary
                )

            // The witness stage carries a live N-of-k sub-counter
            // (the only stage with one). Show it + a chip strip
            // while that stage is active.
            if stage.phase == 2, state == .active {
                let k = Int(progress?.expectedK ?? fallbackK)
                let responded = Int(progress?.responded ?? 0)
                Text("\(responded) of \(k)")
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .monospacedDigit()
                witnessChips(responded: responded, k: k)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func stageIcon(_ state: StageState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.statusCleanFg)
        case .active:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .pending:
            Image(systemName: "circle")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textTertiary)
        }
    }

    /// k small pips for the witness round — fill per responded
    /// validator. Pips encode "responded" vs "still waiting" (there
    /// is no per-validator failure signal at this stage), so the
    /// fill routes through statusClean; the pending pip is a hollow
    /// hairline ring so the distinction is shape, not color-only —
    /// the adjacent "N of k" counter carries the same information
    /// as text.
    @ViewBuilder
    private func witnessChips(responded: Int, k: Int) -> some View {
        let kClamped = max(1, k)
        let respClamped = min(max(0, responded), kClamped)
        HStack(spacing: 3) {
            ForEach(0..<kClamped, id: \.self) { i in
                if i < respClamped {
                    Circle()
                        .fill(DesignTokens.statusCleanFg)
                        .frame(width: 5, height: 5)
                } else {
                    Circle()
                        .strokeBorder(DesignTokens.borderSecondary,
                                      lineWidth: DesignTokens.hairline)
                        .frame(width: 5, height: 5)
                }
            }
        }
    }
}
