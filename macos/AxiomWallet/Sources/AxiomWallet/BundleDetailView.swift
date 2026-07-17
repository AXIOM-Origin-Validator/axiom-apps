import SwiftUI
import AxiomSdk

// =================================================================
// BundleDetailView — modal sheet shown when a row in Receive is
// tapped. Mirrors views/04_bundle_detail.html: header (status chip
// + tier pill + amount + sender + timestamp), why-scarred copy
// (when scarred), reference + txid summary, action row.
//
// Per-validator cheque list (Dilithium ✓) and Nabla check details
// (3-of-3 nodes responding, etc.) need deeper FFI surface to expose
// the cheque bundle's nested CBOR. Shown as a one-line note in this
// commit; expansion lands when the SDK exposes those fields.
//
// Three actions on the bundle:
//   - Redeem: pre-flight + sign modal + stubbed broadcast
//             (Mac dev has no validator transport path — same
//             story as Send. Pre-flight is real, broadcast is
//             honest about not-wired.)
//   - Wait — re-check Nabla: dismisses sheet for now (the SDK's
//             §4.6 verify pass needs network, deferred).
//   - Discard: confirm step → wallet.discardCheque via FFI →
//             sheet closes → row vanishes from Receive list.
//             FUNCTIONAL in this commit.
//
// "Burn" is intentionally NOT here. Burn destroys an already-
// redeemed scarred FACT link (post-redeem, from Activity); not
// a pre-redeem cheque action. The user's distinction:
//   discard → "I don't want this cheque, don't redeem"
//   burn    → "I redeemed a scarred bundle and now want to
//              destroy the resulting FACT link"
// =================================================================

struct BundleDetailView: View {
    @EnvironmentObject private var session: AppSession
    /// Single-flight wallet rule (YP §32): refuse to start a redeem
    /// while a send or another redeem is in flight. Without these
    /// gates the user could fire a parallel TX from this sheet, which
    /// Nabla would detect as a wallet fork and ban.
    @EnvironmentObject private var sendCoordinator: SendCoordinator
    @EnvironmentObject private var redeemCoordinator: RedeemCoordinator
    /// A genesis claim is also a wallet TX (YP §32) — refuse to start a
    /// redeem while one is in flight.
    @EnvironmentObject private var claimCoordinator: ClaimCoordinator
    /// Held to RE-INJECT into the nested RedeemConfirmSheet (a macOS
    /// sheet is a separate window — see ReceiveView's note).
    @EnvironmentObject private var versionSkew: VersionSkewWatcher
    /// Release-feed checker. When the network's Core has rotated
    /// (`mustUpgradeCore`), Redeem is locked (Discard stays allowed —
    /// it's a local action, not a broadcast).
    @EnvironmentObject private var releaseUpdate: ReleaseUpdateWatcher
    let bundle: ChequeBundleRow
    let onClose: () -> Void

    @State private var showSignSheet: Bool = false
    @State private var showDiscardConfirm: Bool = false
    /// Airdrop-forfeit warning. Fires when a brand-new wallet (still
    /// eligible for the one-time free AXC airdrop) taps Redeem — the
    /// redeem is a first-TX that consumes that eligibility. See
    /// `canStillClaimAirdrop`.
    @State private var showAirdropWarning: Bool = false
    @State private var actionError: String? = nil
    /// Kiddo pre-flight gate. Redeem reads cheques from maildir + writes
    /// the redeem TX to outbox/, both of which depend on Kiddo as the
    /// SMTP/POP3 relay. If Kiddo quit mid-session, the redeem hangs
    /// silently waiting for the §4.6 confirm round. The gate makes
    /// that explicit before the user types their wallet key.
    @StateObject private var kiddoGate = KiddoGate()
    /// YPX-022 (repurposed) — live retract status for THIS cheque's txid,
    /// enquired once on appear (query-txid, off-main). `RETRACT_PENDING`
    /// means the sender opened a recall reservation: the cheque is STILL
    /// redeemable and a redeem that finalizes now WINS — surface "redeem
    /// now or it will be recalled". `RETRACTED` means the recall committed:
    /// the cheque is permanently dead.
    @State private var retractStatus: TxidStatusRow? = nil

    /// The cheque's txid hex — `cheque_id` is `"txid_hex:sender_wallet_id"`
    /// (`sdk-core redeem.rs::txid_from_cheque_id`).
    private var txidHex: String? {
        bundle.chequeId.split(separator: ":").first.map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            header
            statusBlock
            retractNotice
            referenceAndTxid
            chequesNote
            nablaCheckNote
            if let err = actionError {
                Text(err)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }
            actionRow
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 540)
        .onAppear {
            guard let txid = txidHex, let wallet = session.activeWallet else { return }
            Task.detached {
                let s = wallet.txidStatus(txidHex: txid)
                await MainActor.run { retractStatus = s }
            }
        }
        .sheet(isPresented: $showSignSheet) {
            RedeemConfirmSheet(
                bundle: bundle,
                onCancel: { showSignSheet = false },
                onCompletion: {
                    showSignSheet = false
                    onClose()
                }
            )
            // Re-inject — nested macOS sheet, separate window.
            .environmentObject(session)
            .environmentObject(versionSkew)
            .environmentObject(redeemCoordinator)
        }
        .kiddoGateAlert(kiddoGate)
        .alert(discardAlertTitle, isPresented: $showDiscardConfirm) {
            Button("Cancel", role: .cancel) {}
            Button(discardConfirmButtonLabel, role: .destructive) { performDiscard() }
        } message: {
            // Two cases with very different value-at-stake:
            //
            // (1) Partial bundle (< k cheques): the receiver can't
            //     redeem this regardless — the protocol's CL5 redeem
            //     requires the full k-quorum. The sender's
            //     partial-commit loss (if any) is already booked at
            //     the protocol layer (`project_partial_commit_sender_loss`).
            //     Discarding from the receiver side is a clean local
            //     cleanup: removes the cheque file, frees the txid
            //     from the inbox list, doesn't destroy any value the
            //     receiver could have collected anyway. Soft language.
            //
            // (2) Complete bundle (k cheques, but Nabla-unconfirmed
            //     or simply unread): the receiver CAN redeem this
            //     into balance. Discarding throws away real, spendable
            //     value. Per YP §17.9.5 the cashier's-cheque rule:
            //     once a validator witnessed, the sender's funds have
            //     already left their wallet — no clawback. So if you
            //     discard a complete bundle, the sender is out the
            //     money AND the receiver gets nothing. KnownIssue #16
            //     describes the cross-evidence-exchange proposal that
            //     would make this non-destructive eventually.
            //     Hard language with the §17.9.5 framing.
            Text(discardAlertMessage)
        }
        .alert("Claim your free AXC airdrop first?", isPresented: $showAirdropWarning) {
            Button("Claim airdrop first") { onClose() }
            Button("Redeem anyway", role: .destructive) { proceedToRedeem() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(airdropWarningMessage)
        }
    }

    /// Title of the discard confirmation alert. Tone matches the
    /// stakes — soft for an unredeemable partial bundle, hard for a
    /// complete-but-unredeemed bundle (where real value is at stake).
    private var discardAlertTitle: String {
        if isPartialBundle {
            return "Discard incomplete bundle?"
        }
        return "Discard this cheque? — funds may be lost"
    }

    private var discardConfirmButtonLabel: String {
        if isPartialBundle {
            return "Discard"
        }
        return "Discard anyway"
    }

    private var discardAlertMessage: String {
        if isPartialBundle {
            let n = Int(bundle.signatureCount)
            let k = Int(bundle.requiredK)
            let missing = max(0, k - n)
            return "This bundle has \(n) of \(k) validator signatures. The protocol (CL5) won't redeem it until all \(k) arrive, so it isn't worth anything to you in its current state.\n\nDiscarding removes the bundle locally. If the missing \(missing) cheque\(missing == 1 ? "" : "s") eventually deliver\(missing == 1 ? "s" : "") via the carrier mesh, the bundle re-appears here and you can redeem it then. Nothing on your side is destroyed by this action.\n\n(Note: if the sender's send hit a partial commit, the sender's wallet may have been debited regardless of whether you discard. That accounting lives in the sender's wallet state and isn't affected by what the receiver does here.)"
        }
        return "AXIOM cheques are like cashier's cheques (Yellow Paper §17.9.5): once a validator witnesses the send, the sender's funds have ALREADY left their wallet. Discarding does NOT return them — there is no clawback.\n\nFrom the receiver side you can't tell whether this bundle is still being assembled (slow carriers can take several minutes) or whether every signature it will ever have is already here. Either way, discarding is destructive — the funds are permanently lost, with no recovery for sender or receiver.\n\nWe suggest: contact the sender first to confirm whether their send actually succeeded, and wait a few minutes in case late cheques are still in transit. Only discard once both are clear. This action has no undo."
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    statusChip
                    if let tier = bundle.tierDisplayName {
                        tierPill(tier)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    // The bundle amount is this sheet's hero figure —
                    // money always renders in the amount* styles.
                    Text(formatBalance(bundle.amount))
                        .font(DesignTokens.Typography.amountHero)
                    Text(formatAxcOnly(bundle.amount))
                        .font(DesignTokens.Typography.amountCaption)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                Text(headerSubtitle)
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var headerSubtitle: String {
        let date = Date(timeIntervalSince1970: TimeInterval(bundle.createdAt))
        let f = DateFormatter()
        f.dateFormat = "MMM dd · HH:mm"
        let local = bundle.sender.split(separator: "@").first.map(String.init) ?? bundle.sender
        return "From \(local) · received \(f.string(from: date))"
    }

    /// All state colors route through `ChequeStatusStyle` — the one
    /// mapping for cheque/FACT states. The status STRINGS and the
    /// switch decision logic are unchanged; only the visual lookup
    /// moved into the shared style.
    @ViewBuilder
    private var statusChip: some View {
        let style = ChequeStatusStyle(statusString: bundle.displayStatus)
        switch bundle.displayStatus {
        case "clean":
            chip("CLEAN", style: style)
        case "scarred":
            chip("SCARRED", style: style)
        case "rejected":
            chip("REJECTED", style: style)
        default:
            chip("— —", style: style)
        }
    }

    private func chip(_ label: String, style: ChequeStatusStyle) -> some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Image(systemName: style.symbol)
                .font(DesignTokens.Typography.micro)
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.chip)
                .tracking(0.3)
        }
        .foregroundStyle(style.fg)
        .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, 3)
        .background(style.bg)
        .clipShape(Capsule())
    }

    private func tierPill(_ name: String) -> some View {
        let (fg, bg) = tierColors(name: name)
        return Text(LocalizedStringKey(name))
            .font(DesignTokens.Typography.chip)
            .tracking(0.3)
            .foregroundStyle(fg)
            .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, 3)
            .background(bg)
            .clipShape(Capsule())
    }

    private func tierColors(name: String) -> (Color, Color) {
        let style = TierStyle(tierLabel: name)
        return (style.fg, style.bg)
    }

    // MARK: - Status block (why-scarred / why-rejected explainer)

    /// State colors route through `ChequeStatusStyle(statusString:)` —
    /// the status strings and the explainer copy decisions are
    /// unchanged; only the color lookup is shared.
    @ViewBuilder
    private var statusBlock: some View {
        let style = ChequeStatusStyle(statusString: bundle.displayStatus)
        switch bundle.displayStatus {
        case "scarred":
            explainerBlock(
                title: "Why is this SCARRED?",
                body: "Nabla detected the sender's wallet has an unresolved scar from a prior partial witness. The cheque cryptography is valid, but Nabla cannot guarantee clean provenance. Redeeming pulls the funds and the scar transfers to your FACT chain. You can heal or burn the resulting link from the Activity view afterwards.",
                style: style
            )
        case "rejected":
            explainerBlock(
                title: "Why is this REJECTED?",
                body: bundle.displayReason ?? "Nabla detected a double-spend conflict on this cheque. Do not redeem — the protocol-side claim has been rejected.",
                style: style
            )
        case "clean":
            explainerBlock(
                title: "Verified, ready to redeem",
                body: "Nabla confirmed the sender has no unresolved scars on this transaction. Maturity window has passed, no double-spend conflict detected.",
                style: style
            )
        default:
            explainerBlock(
                title: "Awaiting verification",
                body: "Inside the gossip-propagation + 5-tick maturity window. Nabla is still gathering responses from peers; status will resolve once the window closes (typically 25 seconds from receipt).",
                style: style
            )
        }
    }

    private func explainerBlock(title: String, body: String, style: ChequeStatusStyle) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(LocalizedStringKey(title))
                .font(DesignTokens.Typography.labelStrong)
                .foregroundStyle(style.fg)
            Text(body)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(style.fg)
                .lineSpacing(2)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            Rectangle()
                .fill(style.fg)
                .frame(width: 3),
            alignment: .leading
        )
        .background(style.bgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    // MARK: - Reference + txid summary

    private var referenceAndTxid: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xl) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("REFERENCE")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(bundle.reference?.isEmpty == false ? bundle.reference! : "—")
                    .font(DesignTokens.Typography.label)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("CHEQUE ID")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(bundle.chequeId.count > 16
                    ? String(bundle.chequeId.prefix(8)) + "…" + String(bundle.chequeId.suffix(8))
                    : bundle.chequeId)
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    // MARK: - Cheques in bundle (signature progress)

    /// True when the bundle has fewer signatures than its tier
    /// requires. The Redeem action is hard-gated on this: the
    /// SDK's CL5 redeem rejects with `ChequeNotReady` ("Need k
    /// cheques, have n") and historically the UI would still
    /// let the user enter their wallet key and broadcast the
    /// attempt, surfacing the rejection only after the network
    /// round-trip. Defense in depth: block at the button level
    /// so the user can't try.
    private var isPartialBundle: Bool {
        bundle.signatureCount < bundle.requiredK
    }

    private var chequesNote: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("CHEQUE SIGNATURES")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            signatureProgress
            Text(signatureProgressDetail)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// k-dot progress strip: filled circles for received signatures,
    /// empty for outstanding. Makes the "1 of 3" / "3 of 3" state
    /// readable at a glance.
    private var signatureProgress: some View {
        let total = Int(bundle.requiredK)
        let filled = min(Int(bundle.signatureCount), total)
        return HStack(spacing: DesignTokens.Spacing.xxs) {
            ForEach(0..<total, id: \.self) { i in
                Circle()
                    .fill(i < filled
                          ? DesignTokens.statusCleanFg
                          : DesignTokens.borderSecondary)
                    .frame(width: 10, height: 10)
            }
            Text("\(filled) of \(total)")
                .font(DesignTokens.Typography.labelStrong)
                .foregroundStyle(isPartialBundle
                                 ? DesignTokens.statusScarredFg
                                 : DesignTokens.statusCleanFg)
                .padding(.leading, DesignTokens.Spacing.xxs)
        }
    }

    private var signatureProgressDetail: String {
        let filled = Int(bundle.signatureCount)
        let total = Int(bundle.requiredK)
        let missing = max(0, total - filled)
        if filled >= total {
            return "Bundle complete. Redeeming will spend it as a single transaction."
        }
        if filled == 0 {
            return "No validator cheques have arrived yet for this txid."
        }
        return "Bundle is incomplete — \(missing) more validator cheque\(missing == 1 ? "" : "s") needed before redemption is possible. Validators may still be delivering; check back in a few minutes. The Redeem button stays disabled until all \(total) arrive."
    }

    // MARK: - Nabla check (placeholder note)

    private var nablaCheckNote: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("NABLA CHECK")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text("Per-node response details (which nodes responded, agreement on sender state, maturity tick) require the §4.6 verify-result snapshot to be exposed via FFI — lands when transport story exists for Mac.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textTertiary)
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("CHOOSE ACTION")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)

            VStack(spacing: DesignTokens.Spacing.xs) {
                // Redeem requires:
                //   - bundle is not REJECTED (Nabla double-spend block)
                //   - bundle has all k validator signatures (otherwise
                //     SDK CL5 rejects with ChequeNotReady and the user
                //     wastes their wallet-key entry + a network round-
                //     trip on a doomed broadcast)
                actionButton(
                    title: redeemTitle,
                    subtitle: redeemSubtitle,
                    color: redeemColor,
                    enabled: bundle.displayStatus != "rejected"
                        && !isPartialBundle
                        // YPX-022: the sender's recall committed — the cheque
                        // is dead network-wide; a redeem is a doomed broadcast.
                        && !isRetracted
                        && !sendCoordinator.isSending
                        && !redeemCoordinator.isRedeeming
                        && !claimCoordinator.isClaiming
                        && !releaseUpdate.mustUpgradeCore   // network Core rotated (YP §23.10)
                        // YPX-020 §2 — Core CL5 hard-rejects a normal redeem
                        // while hibernating (E_WALLET_HIBERNATING). The ONLY
                        // redeem allowed in that state is the re-anchor's
                        // distress cheque, which goes through the dedicated
                        // "Finish recovery" action (HalRecoverySheet → hal_complete),
                        // NOT this generic inbox button. Grey it out so the user
                        // can't fire a doomed broadcast; the subtitle points them
                        // at Finish recovery.
                        && !session.isHibernating
                ) {
                    // If this wallet can still claim the one-time free
                    // airdrop, redeeming a received cheque first consumes
                    // its new-wallet status and forfeits the airdrop
                    // (Core's genesis claim requires the fresh
                    // seq=0/balance=0 first-TX state). Warn before
                    // proceeding; otherwise go straight to the redeem.
                    //
                    // EXCEPTION: the genesis airdrop cheque itself. After CLAIM
                    // de-orchestration (2.17.8) the 2-step flow leaves the
                    // airdrop's own self-cheque PENDING here, and the request
                    // leg already set hasPendingGenesisRegistration() → so
                    // canStillClaimAirdrop is true. But redeeming THIS cheque IS
                    // claiming the airdrop, not forfeiting it — without the
                    // exemption the warning fires, its primary button closes the
                    // sheet (onClose), and the airdrop can never be redeemed
                    // through Receive ("request okay but cheque never received").
                    if canStillClaimAirdrop && !bundle.isGenesisAirdrop {
                        showAirdropWarning = true
                    } else {
                        proceedToRedeem()
                    }
                }

                actionButton(
                    title: "Wait — re-check Nabla",
                    subtitle: "Status may change as gossip propagates. Re-checks the §4.6 verification once transport is wired (no-op for now).",
                    color: DesignTokens.borderSecondary,
                    enabled: false
                ) {}

                actionButton(
                    title: isPartialBundle ? "Discard incomplete bundle" : "Discard cheque",
                    subtitle: discardActionSubtitle,
                    color: DesignTokens.borderSecondary,
                    enabled: true
                ) {
                    showDiscardConfirm = true
                }
            }
        }
    }

    // MARK: - YPX-022 retract notices (receiver side)

    /// True once the enquiry says the sender's recall COMMITTED — the
    /// cheque is permanently dead (query-txid serves it REDEEMED with the
    /// unsigned RETRACTED reason so no CL5 change was needed).
    private var isRetracted: Bool {
        retractStatus.map { $0.status == "REDEEMED" && $0.claimStatus == "RETRACTED" } ?? false
    }

    /// True while the sender's recall RESERVATION is open — informational
    /// urgency only; the cheque is still live and a redeem that finalizes
    /// now wins (§2.2.1).
    private var isRetractPending: Bool {
        retractStatus.map { $0.status != "REDEEMED" && $0.claimStatus == "RETRACT_PENDING" } ?? false
    }

    @ViewBuilder
    private var retractNotice: some View {
        if isRetracted {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                Text("This payment was retracted by the sender. The cheque is permanently cancelled network-wide and can no longer be redeemed — if you still expect the money, ask the sender to send it again.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.statusRejectedBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        } else if isRetractPending {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Text("The sender is retracting this payment — redeem now or it will be recalled. Your redeem keeps priority until the recall commits: if it lands first, the payment stands and the recall aborts.")
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

    private var redeemTitle: String {
        if isRetracted {
            return "Redeem (blocked — payment retracted)"
        }
        if session.isHibernating {
            return "Redeem (paused — wallet hibernating)"
        }
        if isPartialBundle {
            return "Redeem (waiting for \(Int(bundle.requiredK) - Int(bundle.signatureCount)) more cheque\(Int(bundle.requiredK) - Int(bundle.signatureCount) == 1 ? "" : "s"))"
        }
        switch bundle.displayStatus {
        case "scarred": return "Redeem with scar"
        case "rejected": return "Redeem (blocked — REJECTED)"
        default: return "Redeem"
        }
    }

    private var redeemSubtitle: String {
        if isRetracted {
            return "The sender recalled this payment and the retract is committed and final — the network refuses this cheque everywhere. Discard it below."
        }
        if session.isHibernating {
            return "This wallet is hibernating after a HAL re-anchor. Redeem stays paused (Core would reject with E_WALLET_HIBERNATING) until you finish recovery — use “Finish recovery” on the hibernation banner. That step redeems the re-anchor's distress cheque and clears the flag; then this cheque can be redeemed."
        }
        if isPartialBundle {
            return "Bundle has \(Int(bundle.signatureCount)) of \(Int(bundle.requiredK)) validator signatures. The protocol (CL5) requires the full quorum to redeem — wait for more cheques to arrive."
        }
        switch bundle.displayStatus {
        case "clean":
            return "+\(formatBalance(bundle.amount)) to your balance · clean FACT link added to your chain."
        case "scarred":
            return "+\(formatBalance(bundle.amount)) to your balance · scar transfers to your FACT chain (heal/burn from Activity afterwards)."
        case "rejected":
            return "Cannot redeem — Nabla detected a double-spend conflict on this cheque."
        default:
            return "+\(formatBalance(bundle.amount)) — wait for verification to complete before redeeming for best status visibility."
        }
    }

    private var redeemColor: Color {
        if isRetracted { return DesignTokens.statusRejectedFg }
        switch bundle.displayStatus {
        case "scarred": return DesignTokens.statusScarredFg
        case "rejected": return DesignTokens.statusRejectedFg
        default: return DesignTokens.brandPrimary
        }
    }

    /// Subtitle for the Discard action row button. Reads differently
    /// for an incomplete (n < k) bundle versus a complete one because
    /// the value-at-stake is different — incomplete can't be redeemed
    /// regardless, complete throws away real spendable value. The
    /// confirmation alert (above) makes the same distinction.
    private var discardActionSubtitle: String {
        if isPartialBundle {
            return "Bundle can't be redeemed in its current state — discarding removes it locally. Safe to do; if the missing cheques arrive later, the bundle reappears."
        }
        return "Delete locally without claiming. Cashier's-cheque rule (YP §17.9.5) — the sender's funds have already left their wallet, and the receiver can't tell partial-stalled from partial-arriving; tap with care."
    }

    private func actionButton(
        title: String,
        subtitle: String,
        color: Color,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(enabled ? color : DesignTokens.textTertiary)
                Text(subtitle)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(enabled ? DesignTokens.textSecondary : DesignTokens.textTertiary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.sm))
            .background(DesignTokens.bgPrimary)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                    .strokeBorder(enabled ? color : DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Airdrop-eligibility guard

    /// True when the active wallet can still claim the one-time free AXC
    /// airdrop (YP §17.11) — a brand-new Normal-mode wallet that has
    /// never transacted. Redeeming a received cheque is a first-TX that
    /// consumes this eligibility: Core's genesis claim requires the fresh
    /// seq=0 / balance=0 first-TX state, so once any redeem or send lands
    /// the airdrop is gone for this wallet, permanently. Mirrors
    /// `OverviewView.canClaimGenesis` so the warning fires in exactly the
    /// cases where the Overview still shows the "Claim 1 AXC" CTA.
    private var canStillClaimAirdrop: Bool {
        guard let w = session.activeWallet else { return false }
        // Ark wallets don't fund_genesis (k=0, offline-only).
        if session.activeMode == .ark { return false }
        // Airdrop pool exhausted globally (YP §17.11.7.2) — no airdrop
        // to forfeit, so don't warn.
        if PoolExhaustedFlag.isSet { return false }
        // Fresh wallet: never transacted.
        if w.walletSeq() == 0 && w.balance() == 0 { return true }
        // Genesis claim already in flight (recoverable cap rejection).
        if w.hasPendingGenesisRegistration() { return true }
        return false
    }

    private var airdropWarningMessage: String {
        "This wallet hasn't claimed its free AXC airdrop yet. The airdrop (Yellow Paper §17.11) is a one-time grant available ONLY to a brand-new wallet that has never transacted.\n\nRedeeming this cheque counts as this wallet's first transaction. Once it lands, the wallet is no longer new and the free airdrop is gone for good — there is no way to claim it afterward.\n\nIf you want the free AXC, choose \u{201C}Claim airdrop first\u{201D}: this closes the cheque and you tap \u{201C}Claim 1 AXC\u{201D} on the Overview. You can redeem this cheque straight after the airdrop lands."
    }

    /// Shared redeem entry point: Kiddo pre-flight gate, then the sign
    /// sheet. Called directly when the wallet isn't airdrop-eligible, or
    /// from the "Redeem anyway" button on the airdrop warning.
    private func proceedToRedeem() {
        // Hard single-flight guard, independent of the (re-injected)
        // disabled-button state: never start a redeem while any broadcast
        // — send, another redeem, or a genesis claim — is in flight. Two
        // parallel wallet TXs trip Nabla fork detection (YP §32).
        guard !sendCoordinator.isSending
            && !redeemCoordinator.isRedeeming
            && !claimCoordinator.isClaiming else { return }
        let email = session.activeWallet?.email() ?? ""
        kiddoGate.check(email: email) {
            showSignSheet = true
        }
    }

    // MARK: - Discard

    private func performDiscard() {
        guard let wallet = session.activeWallet else { return }
        actionError = nil
        do {
            try wallet.discardCheque(chequeId: bundle.chequeId)
            onClose()
        } catch {
            actionError = "Couldn't discard: \(error.localizedDescription)"
        }
    }
}

// =================================================================
// RedeemConfirmSheet — wallet_key challenge before redeem broadcast.
// Same shape as Send's SignModal: TX summary + SecureField + warning
// + broadcast action that's currently stubbed (Mac dev has no
// validator transport path).
// =================================================================
private struct RedeemConfirmSheet: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var versionSkew: VersionSkewWatcher
    /// App-scoped owner of the background redeem. The sheet hands
    /// off via `start(...)` and dismisses; the witness round runs
    /// to completion regardless of whether the sheet is alive (the
    /// original `Task.detached` died on sheet close, leaving a
    /// half-redeemed cheque with a Nabla claim registered).
    @EnvironmentObject private var redeemCoordinator: RedeemCoordinator
    let bundle: ChequeBundleRow
    let onCancel: () -> Void
    let onCompletion: () -> Void

    @State private var walletKey: String = ""
    @State private var status: SignStatus = .idle
    @State private var errorMessage: String? = nil
    @State private var resultBalance: UInt64 = 0
    @State private var resultFactState: String = ""
    /// Parsed `FfiError` code on failure — drives PartialCommit → heal
    /// routing (mirrors SendView).
    @State private var lastErrorCode: String? = nil
    /// Drives the HealConfirmSheet, opened when a redeem fails with
    /// PartialCommit and the user taps "Heal wallet…".
    @State private var showHealModal: Bool = false
    @FocusState private var keyFocused: Bool

    enum SignStatus { case idle, verifying, broadcasting, sent, failed }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("CONFIRM AND REDEEM")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text(headlineText)
                .font(DesignTokens.Typography.heading)

            summaryCard

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("WALLET KEY")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                SecureField("Enter your wallet key", text: $walletKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFocused)
                    .onSubmit(broadcast)
                    .disabled(status == .verifying || status == .broadcasting || status == .sent)
            }

            if status == .broadcasting {
                broadcastProgress
            }

            if status == .sent {
                redeemedSummary
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }

            scarWarningIfNeeded

            if session.isHibernating {
                hibernationNote
            }

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button(actionLabel) { primaryAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    // YPX-020 — an in-window cheque-claim is refused by
                    // Nabla ("HIBERNATING"); disable rather than let it
                    // round-trip and fail.
                    .disabled(walletKey.isEmpty || status == .verifying || status == .broadcasting || status == .sent || session.isHibernating)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 480)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                keyFocused = true
            }
        }
        .sheet(isPresented: $showHealModal) {
            HealConfirmSheet(
                onCancel: { showHealModal = false },
                onCompletion: {
                    // Heal cleared the divergence — drop the failure
                    // framing so the user can re-tap "Sign and redeem".
                    showHealModal = false
                    status = .idle
                    errorMessage = nil
                    lastErrorCode = nil
                }
            )
            .environmentObject(session)
        }
    }

    /// Action-button dispatch. A redeem that failed with PartialCommit
    /// routes to the heal sheet — the SDK keeps rejecting the same
    /// redeem until heal clears the recorded garbage state. Every other
    /// failure just retries `broadcast()`.
    private func primaryAction() {
        if status == .failed && lastErrorCode == "PartialCommit" {
            showHealModal = true
        } else {
            broadcast()
        }
    }

    private var headlineText: String {
        let local = bundle.sender.split(separator: "@").first.map(String.init) ?? bundle.sender
        return "Redeem \(formatBalance(bundle.amount)) from \(local)"
    }

    private var actionLabel: String {
        switch status {
        case .idle:        return "Sign and redeem"
        case .verifying:   return "Verifying…"
        case .broadcasting: return "Redeeming…"
        case .sent:        return "Redeemed"
        case .failed:
            // PartialCommit → heal sheet (primaryAction dispatches);
            // every other failure re-broadcasts.
            return lastErrorCode == "PartialCommit" ? "Heal wallet…" : "Try again"
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 0) {
            summaryRow("Sender", value: bundle.sender, mono: true)
            Divider()
            summaryRow("Tier", value: bundle.tierDisplayName ?? "—")
            Divider()
            summaryRow("Status", value: bundle.displayStatus.uppercased())
            Divider()
            summaryRow("Amount", value: "\(formatBalance(bundle.amount))\n\(formatAxcOnly(bundle.amount))")
            if let ref = bundle.reference, !ref.isEmpty {
                Divider()
                summaryRow("Reference", value: ref)
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xxs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xxs, trailing: DesignTokens.Spacing.sm))
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private func summaryRow(_ label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textSecondary)
            Spacer()
            Text(value)
                .font(mono ? DesignTokens.Typography.monoSmall : DesignTokens.Typography.labelStrong)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    @ViewBuilder
    private var broadcastProgress: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Redeeming witness round...")
                    .font(DesignTokens.Typography.labelStrong)
            }
            Text("Wallet wrote the redeem UMP to outbox/ and is querying Nabla + blocking on inbox/ for redeem witness cheques (max 60s). Make sure AxiomKiddo is running.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.brandPrimarySoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    /// State colors route through `ChequeStatusStyle(statusString:)` —
    /// `resultFactState` carries the SDK's "clean"/"scarred" string and
    /// the decision logic is unchanged.
    @ViewBuilder
    private var redeemedSummary: some View {
        let style = ChequeStatusStyle(statusString: resultFactState)
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(resultFactState == "scarred" ? "✓ Redeemed (scarred)" : "✓ Redeemed (clean)")
                .font(DesignTokens.Typography.bodyStrong)
                .foregroundStyle(style.fg)
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Text("New balance:")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                Text("\(formatBalance(resultBalance)) · \(formatAxcOnly(resultBalance))")
                    .font(DesignTokens.Typography.amountCaption)
            }
            if resultFactState == "scarred" {
                Text("FACT link is scarred — heal or burn from the Activity view to clear it.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineSpacing(2)
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.bgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    @ViewBuilder
    private var scarWarningIfNeeded: some View {
        if bundle.displayStatus == "scarred" {
            Text("Redeeming a SCARRED bundle inherits the sender's scar to your FACT chain. You can heal or burn the resulting link from Activity afterwards.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.statusScarredFg)
                .lineSpacing(2)
                .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.statusScarredBgSoft)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        }
    }

    /// YPX-020 hibernation note — the wallet is frozen after a HAL
    /// re-anchor (binary flag), so a cheque-claim can't complete. Explain
    /// it instead of letting the disabled button read as a dead end.
    private var hibernationNote: some View {
        Text("Wallet is hibernating after a re-anchor. Redeem is paused until you finish recovery (Complete HAL) from the recovery banner — it does not clear on its own.")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.statusScarredFg)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.statusScarredBgSoft)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    private func broadcast() {
        guard let wallet = session.activeWallet else { return }
        errorMessage = nil
        status = .verifying

        let ok = wallet.verifyWalletKey(walletKey: walletKey)
        if !ok {
            status = .failed
            errorMessage = "Wrong wallet key."
            return
        }

        // Hand off to the app-scoped coordinator so the witness round
        // outlives this sheet. Pre-fix this was a view-scoped
        // Task.detached — when the sheet dismissed (or the user
        // navigated away), the task died mid-flight, but
        // verify_cheque had already registered a Nabla claim. Next
        // retry hit Nabla's REDEEMED gate and the SDK destructively
        // marked the local cheque redeemed without ever crediting
        // balance (redeem.rs:344). See RedeemCoordinator.swift's
        // header for the full failure analysis.
        //
        // The coordinator owns lastErrorCode / errorMessage /
        // resultBalance via its Outcome enum; the sheet just
        // dismisses after starting, and the user watches the
        // background banner in the main app chrome.
        redeemCoordinator.start(
            wallet: wallet,
            chequeId: bundle.chequeId,
            amountAtoms: bundle.amount,
            sender: bundle.sender
        )
        // Refresh the version-skew watcher proactively so that if the
        // redeem succeeds and the mesh has bumped its min-client
        // floor, the alert lights up without waiting for the next
        // unrelated broadcast.
        versionSkew.refresh(from: wallet)
        onCompletion()
    }
}
