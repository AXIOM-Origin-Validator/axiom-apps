import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import AxiomSdk

// =================================================================
// OverviewView — landing pane after login.
//
// Mirrors views/01_overview.html with the pair-tabs revision: the
// header shows the active pair name + Normal/Ark mode toggle, the
// hero card shows balance + AXC equivalent + FACT chain depth, the
// status row shows three at-a-glance cards (Incoming / FACT status /
// Ark companion balance), and the bottom section will eventually
// show recent activity (placeholder until Activity view lands).
//
// All data flows through the FFI. No URLSession. No direct TCP.
// =================================================================

struct OverviewView: View {
    @EnvironmentObject private var session: AppSession
    /// Observed so the Overview re-reads balance / diagnose the moment
    /// a background send starts or finishes (its values change behind
    /// the FFI handle, which SwiftUI can't see on its own).
    @EnvironmentObject private var sendCoordinator: SendCoordinator
    /// Sister to sendCoordinator — drives Send + Receive button
    /// greying while a redeem witness round is in flight. Redeem is
    /// also a wallet TX (YP §32), so the same one-TX-at-a-time
    /// guarantee applies; firing Send during a redeem (or opening
    /// Receive to fire another redeem) triggers the same fork-
    /// detection ban risk.
    @EnvironmentObject private var redeemCoordinator: RedeemCoordinator
    /// Sister to send/redeem — a genesis claim is also a wallet TX
    /// (YP §32), so the Claim CTA and the Send / Receive action buttons
    /// all grey out while a background claim is in flight, and the claim
    /// itself is blocked while a send/redeem runs.
    @EnvironmentObject private var claimCoordinator: ClaimCoordinator
    /// SDK protocol-version skew. When `isSdkTooOld` is true we
    /// disable every broadcast initiator (Send / Redeem / Claim / Heal)
    /// — the wallet binary can no longer reliably interpret responses,
    /// so initiating new wire activity is unsafe.
    @EnvironmentObject private var versionSkew: VersionSkewWatcher
    /// Release-feed checker. When the network's Core has rotated
    /// (`mustUpgradeCore`), Claim is locked alongside Send/Redeem.
    @EnvironmentObject private var releaseUpdate: ReleaseUpdateWatcher
    @State private var showHealSheet: Bool = false
    @State private var showGenesisSheet: Bool = false
    /// Show-address sheet — driven by the Overview's "Show address"
    /// action. Lists all 7 tier addresses with per-row copy buttons
    /// (Ark / Standard / A+ / Secure / Secure+ / AAA / AAA+).
    @State private var showAddressesSheet: Bool = false
    /// Disclosure state for the "Show address" sheet's other-tiers
    /// section. Closed by default — most users want their Standard
    /// address, the other 6 tiers are a niche browse-and-copy.
    @State private var showOtherTiers: Bool = false
    /// Wallet-pair management sheet — opened from the "Wallets"
    /// button on the balance card (next to Address; both are
    /// about this wallet collection). Settings / Lock live in the
    /// sidebar footer.
    @State private var showWalletsSheet: Bool = false
    /// Bump on heal/genesis sheet dismissal so SwiftUI re-evaluates
    /// `healUrgency` and `canClaimGenesis`. The underlying wallet
    /// state lives behind the FFI handle — SwiftUI can't observe
    /// changes to it on its own, so when we mutate state via the
    /// heal flow the view caches stale scar counts until something
    /// in the body's observed state changes. This @State tick is
    /// that "something".
    @State private var refreshTick: Int = 0

    /// True when the active wallet hasn't yet broadcast any TX (no
    /// genesis claim, no send, no redeem) OR has a saved pending
    /// genesis registration (recoverable cap rejection — YP §17.11.7).
    /// Genesis claim is a YP §17.11 self-send with `wallet_seq=1` —
    /// Core's CL5 rejects it once wallet_seq advances past 1. Surface
    /// a one-click claim CTA on the Overview so users who skipped
    /// onboarding's Step 5 can still claim from anywhere; the same
    /// CTA also serves the "resume after cap reset" flow.
    private var canClaimGenesis: Bool {
        guard let w = session.activeWallet else { return false }
        // Ark wallets aren't supposed to fund_genesis (their k=0 design
        // makes them offline-only); the Mac UI only offers the CTA on
        // Normal mode active wallets.
        if session.activeMode == .ark { return false }
        // YP §17.11.7.2 — once the Airdrop pool is exhausted globally,
        // suppress the CTA on every wallet on this Mac, including new
        // ones. The flag persists outside the app bundle so a
        // reinstall doesn't reset it. See PoolExhaustedFlag.
        if PoolExhaustedFlag.isSet { return false }
        // Fresh-wallet case: seq=0, balance=0.
        if w.walletSeq() == 0 && w.balance() == 0 { return true }
        // Resume case: seq=1, balance=0, witness round cached as a
        // pending genesis registration. claim_genesis_full will
        // detect the entry and resume via complete_registration.
        if w.hasPendingGenesisRegistration() { return true }
        return false
    }

    enum HealUrgency { case none, advisory, required }

    /// Heal trigger — driven off `wallet.diagnose()`, never a raw
    /// `scar_count` threshold (CLAUDE.md §14, corrected 2026-05-16).
    ///
    /// A fixed `scar_count > 4` cutoff has a plateau gap: a wallet
    /// whose later registers succeed sits at 1–4 scars forever,
    /// never crosses the line, never prompts heal, and eventually
    /// wedges at FACT-depth max (soak s2r96563 — 3/50 wallets stuck
    /// at scar_count=4). `diagnose()` has no such gap — it returns a
    /// recovery action for *any* unresolved scar.
    ///
    ///   * `.required` — diagnose returns a `heal` or `burn` action
    ///     (poisoned committers, garbage states, FACT-depth-max, or
    ///     >2 scars). The wallet is wedged or close to it.
    ///   * `.advisory` — diagnose returns only `nabla_register`
    ///     (1–2 scars; a supplemental register may clear them).
    ///   * `.none` — no `heal`/`burn`/`nabla_register` action.
    private var healUrgency: HealUrgency {
        let actions = healActions
        if actions.isEmpty { return .none }
        let hasUrgent = actions.contains { $0.call == "heal" || $0.call == "burn" }
        return hasUrgent ? .required : .advisory
    }

    /// The subset of `wallet.diagnose()` actions that drive the heal
    /// prompt: `heal`, `burn`, `nabla_register`. Other actions
    /// (`redeem` for pending cheques, `wait`, …) are not recovery
    /// triggers and are filtered out. Empty when the wallet is
    /// healthy or has no active wallet.
    private var healActions: [AppDiagnoseAction] {
        guard let w = session.activeWallet,
              let actions = try? w.diagnose() else { return [] }
        let triggers: Set<String> = ["heal", "burn", "nabla_register"]
        return actions.filter { triggers.contains($0.call) }
    }

    /// The `fact_chain_broken` diagnose action, if any — the Tier 1
    /// structural-corruption signal. Deliberately NOT in `healActions`
    /// (its `call` is "(no recovery available — PR2)"): a continuity
    /// break is not heal/burn-recoverable, so it gets its own banner
    /// with no recovery affordance. `nil` when the chain is intact.
    private var factChainBrokenAction: AppDiagnoseAction? {
        guard let w = session.activeWallet,
              let actions = try? w.diagnose() else { return nil }
        return actions.first { $0.action == FactChainCorruption.diagnoseAction }
    }

    /// YPX-001 §1.5.1a — the `inherited_scar_wait` diagnose action, if any.
    /// This wallet REDEEMED money whose sender carried an unresolved scar, so
    /// the redeem link inherited the taint. It is NOT counted by
    /// `factScarCount()` (that's own-scars only, the burn targets) and is NOT
    /// user-fixable — it clears automatically when the sender's origin txid
    /// heals/burns (the send pre-flight sweep checks every send). Without
    /// this banner the wallet looked "clean" while actually carrying taint —
    /// the gap that made scar inheritance look broken. `call` is "none".
    private var inheritedScarAction: AppDiagnoseAction? {
        guard let w = session.activeWallet,
              let actions = try? w.diagnose() else { return nil }
        return actions.first { $0.action == "inherited_scar_wait" }
    }

    var body: some View {
        // Read refreshTick so SwiftUI tracks it as a body dependency.
        // Sheet `onCompletion` callbacks bump this to force a fresh
        // evaluation of healUrgency / canClaimGenesis after the
        // underlying wallet state changed.
        let _ = refreshTick
        // Re-render when a background send starts or resolves so the
        // balance / heal banner reflect the post-send wallet state.
        let _ = sendCoordinator.isSending
        let _ = sendCoordinator.lastOutcome
        let _ = redeemCoordinator.isRedeeming
        let _ = redeemCoordinator.lastOutcome
        // Same for a background genesis claim — re-render so the Claim
        // CTA + balance/heal banner reflect the in-flight / resolved
        // claim state.
        let _ = claimCoordinator.isClaiming
        let _ = claimCoordinator.lastOutcome
        // Navigation moved to the sidebar (2026-06-11 shell
        // restructure) — this pane is now purely the wallet
        // overview: identity header, balance hero, status row,
        // callouts, and the recent-activity preview.
        return ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                pairHeader
                balanceHero
                statusRow
                if let broken = factChainBrokenAction {
                    corruptionCallout(broken)
                }
                if let inherited = inheritedScarAction {
                    inheritedScarCallout(inherited)
                }
                if canClaimGenesis {
                    genesisCallout
                }
                if healUrgency != .none {
                    healCallout
                }
                activityPreview
            }
            .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bgPrimary)
        .sheet(isPresented: $showHealSheet) {
            HealConfirmSheet(
                onCancel: { showHealSheet = false },
                onCompletion: {
                    showHealSheet = false
                    refreshTick &+= 1   // re-read wallet state
                }
            )
            .environmentObject(session)
        }
        .sheet(isPresented: $showGenesisSheet) {
            GenesisClaimSheet(
                onCancel: { showGenesisSheet = false },
                onCompletion: {
                    showGenesisSheet = false
                    refreshTick &+= 1   // re-read wallet state
                }
            )
            .environmentObject(session)
        }
        .sheet(isPresented: $showAddressesSheet) {
            allTierAddressesSheet
        }
        .sheet(isPresented: $showWalletsSheet) {
            walletsManagementSheet
        }
        .onAppear {
            // Bug B fix — when the user lands on Overview with an
            // active wallet, ping AxiomKiddo so it learns about the
            // wallet and starts FATMAMA-registering its address. Without
            // this, a wallet that skipped Onboarding's Kiddo step (or
            // any non-@axiom.internal wallet that was never auto-
            // provisioned) gets no XAXIOM-REGISTER → FATMAMA drops every
            // inbound cheque at RCPT TO → Receive view stays empty
            // even when a sender claims the send succeeded.
            //
            // Gated: only fires if (a) Kiddo has no existing account
            // for this wallet's email and (b) axiom.conf's smtp_host
            // points at a FATMAMA-style dev host (loopback, mooo.com,
            // *.internal, …). Real-ISP SMTP hosts fall through —
            // provisioning a stub `.axiomDev` account for those would
            // create a broken account that couldn't poll, which is
            // worse than the no-account state.
            //
            // Kiddo's `provisionAccount` is idempotent — re-firing on
            // every Overview appear is a no-op when the account already
            // exists. No throttling needed.
            pingKiddoIfNeeded()
        }
    }

    /// Bug B handler invoked from `.onAppear`. Mirrors
    /// `OnboardingView.maybeAutoProvision` but for wallets that already
    /// exist post-onboarding.
    private func pingKiddoIfNeeded() {
        guard let pair = session.activePair,
              let wallet = session.activeWallet else { return }
        let email = wallet.email()
        guard !email.isEmpty else { return }
        // Only act on the "Kiddo's missing an account for me" state.
        // .ready / .notInstalled / .notRunning are not our problem
        // here — KiddoPreflightWatcher elsewhere prompts the user
        // through those.
        guard case .noAccountForEmail = KiddoPreflight.checkNow(walletEmail: email) else {
            return
        }
        guard KiddoPreflight.smtpHostIsDevSafe(appDir: defaultAppDir()) else {
            // Real-ISP SMTP — auto-provision would create a broken
            // stub. Leave it to the user to configure in Kiddo
            // Settings → +.
            return
        }
        // Wallet dir mirrors OnboardingView's construction:
        // `<defaultWalletDir()>/<pairName>-normal`. The `-normal`
        // suffix is the Normal-wallet half of every pair (the Ark
        // half is `-ark`, not what we want here).
        let walletDir = "\(defaultWalletDir())/\(pair.name)-normal"
        KiddoPreflight.provisionKiddo(
            walletEmail: email,
            walletDir: walletDir,
            label: pair.name
        )
    }

    // MARK: - Show address sheet

    /// Pops on Overview's "Show address" tap. Default view is the
    /// Standard tier address with an inline QR code + Copy button —
    /// covers the ~95% case ("give someone my address"). A
    /// disclosure below expands to show the other 6 tiers as
    /// copy-only rows (Ark / A+ / Secure / Secure+ / AAA / AAA+)
    /// for the rare browse-and-pick case.
    @ViewBuilder
    private var allTierAddressesSheet: some View {
        let tiers = (try? session.activeWallet?.allAddresses()) ?? []
        let standard = tiers.first { $0.displayName == "Standard" }
        let others = tiers.filter { $0.displayName != "Standard" }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(DesignTokens.brandPrimary)
                    Text("Receive address")
                        .font(DesignTokens.Typography.bodyStrong)
                }
                Text("Share this address to receive payments. The Standard tier is the everyday default; higher-security tiers are below if you need them.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let std = standard {
                    standardAddressBlock(std)
                } else {
                    Text("No active wallet.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.textTertiary)
                }

                if !others.isEmpty {
                    DisclosureGroup(isExpanded: $showOtherTiers) {
                        VStack(spacing: 6) {
                            ForEach(others, id: \.address) { tier in
                                addressRow(
                                    label: tier.displayName,
                                    sublabel: tierSublabel(k: tier.k, proofType: tier.proofType),
                                    address: tier.address,
                                )
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Show other security tiers (\(others.count))")
                            .font(DesignTokens.Typography.sectionLabel)
                            .foregroundStyle(DesignTokens.brandPrimary)
                    }
                }

                HStack {
                    Spacer()
                    Button("Close") { showAddressesSheet = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(EdgeInsets(top: 22, leading: 26, bottom: 22, trailing: 26))
        }
        .frame(width: 480, height: 540)
    }

    /// The default Standard-tier block at the top of the Show
    /// address sheet — QR code rendered inline (Core Image), the
    /// address text below in mono, Copy button.
    @ViewBuilder
    private func standardAddressBlock(_ std: TierAddress) -> some View {
        VStack(alignment: .center, spacing: 12) {
            HStack(spacing: 6) {
                Text("Standard")
                    .font(DesignTokens.Typography.labelStrong)
                Text("k=3 · DMAP")
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let qr = generateQRImage(from: std.address) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text(std.address)
                .font(DesignTokens.Typography.monoSmall)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .textSelection(.enabled)
                .padding(.horizontal, DesignTokens.Spacing.xs)

            HStack(spacing: 8) {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(std.address, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(DesignTokens.Typography.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    /// Render an AXIOM address as a QR-code `NSImage`. Core Image's
    /// `CIQRCodeGenerator` with error correction `H` (~30% damage
    /// tolerance) — same settings as the standalone
    /// `AddressQRSheet`. Nearest-neighbour upscale for crisp pixels.
    private func generateQRImage(from text: String) -> NSImage? {
        let data = Data(text.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "H"
        guard let outputImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = outputImage.transformed(by: transform)
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    /// "k=3 · DMAP" / "k=5 · ZKP" / "Ark" — short shape label for
    /// each tier row.
    private func tierSublabel(k: UInt32, proofType: UInt32) -> String {
        if k == 0 { return "Offline transfer" }
        let proof: String
        switch proofType {
        case 0: proof = "ZKP"
        case 1: proof = "DMAP"
        case 2: proof = "Ark"
        default: proof = "?"
        }
        return "k=\(k) · \(proof)"
    }

    /// One address row used by both sheets — mono-spaced address +
    /// optional sublabel + Copy button.
    @ViewBuilder
    private func addressRow(label: String, sublabel: String? = nil, address: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(label))
                        .font(DesignTokens.Typography.sectionLabel)
                    if let s = sublabel {
                        Text(s)
                            .font(DesignTokens.Typography.monoSmall)
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                }
                Text(address)
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(address, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(DesignTokens.Typography.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Copy this address to clipboard")
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    // ── Genesis-claim callout — shown when wallet hasn't claimed yet.
    //
    // Genesis claim is YP §17.11: a self-send at wallet_seq=1/balance=0.
    // Onboarding offers a "Skip — claim later" path; this banner is
    // the "later". Once wallet_seq advances past 1 (any TX), Core
    // rejects further genesis claims and the banner disappears.
    private var genesisCallout: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("Claim your 1 AXC")
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.brandPrimary)
                Text("New wallets get 1 AXC from the genesis pool — one-time self-send witnessed by the validator set. You skipped this during onboarding, or your first attempt failed. Try now.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
            }
            Spacer()
            Button(claimCoordinator.isClaiming ? "Claiming…" : "Claim 1 AXC") {
                showGenesisSheet = true
            }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandPrimary)
                .controlSize(.regular)
                .disabled(versionSkew.isSdkTooOld
                          || releaseUpdate.mustUpgradeCore
                          || claimCoordinator.isClaiming
                          || sendCoordinator.isSending
                          || redeemCoordinator.isRedeeming)
                .help(releaseUpdate.mustUpgradeCore
                      ? "Claim disabled — the network upgraded its Core. Claiming on a mismatched Core would diverge your wallet from the network and can damage it (YP §23.10). Update the wallet first."
                      : versionSkew.isSdkTooOld
                      ? "Claim disabled — wallet build is older than the network's minimum protocol version (mesh v\(versionSkew.serverProtocolVersion), wallet v\(versionSkew.clientProtocolVersion)). Update first."
                      : (claimCoordinator.isClaiming
                         ? "A genesis claim is already in flight — watch its progress in the banner above."
                         : ((sendCoordinator.isSending || redeemCoordinator.isRedeeming)
                            ? "A transaction is in flight. The genesis claim is also a wallet TX — running it in parallel risks a Nabla fork-detection ban (YP §32). Wait for the current transaction to finish."
                            : "")))
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.md, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.md))
        .background(DesignTokens.brandPrimaryWash)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
    }

    // ── Heal callout — required (red) when garbage_state_ids != 0
    //                  or scars > 4; advisory (yellow) for 1-4 scars.
    //
    // Per CLAUDE.md §14: SDK never triggers heal autonomously — the
    // client app decides. The Mac wallet's policy is to surface this
    // banner whenever `wallet.diagnose()` returns a recovery action
    // (advisory style for a supplemental-register hint, required
    // style for a burn / CLARA heal). No raw scar-count threshold —
    // diagnose() has no plateau gap.
    // Tier 1 structural-corruption banner. Shown when diagnose()
    // reports `fact_chain_broken` — a FACT-chain continuity break.
    // Deliberately has NO action button: a continuity break is not
    // heal/burn-recoverable (those re-ship the broken chain and Core
    // rejects), and the keypair is fine (no wipe / new-keypair). The
    // honest state + a link to community support (GitHub) is the only
    // correct UX until the PR2 recovery path lands — AXIOM has no
    // operator/support desk.
    // YPX-001 §1.5.1a — inherited-taint banner. Informational (no action
    // button): the taint is not this wallet's to fix — it clears when the
    // sender's origin scar heals/burns, checked on every send. This is the
    // signal the scar DID carry over (it's on the redeem link) even though
    // the own-scar count reads 0. Amber (scarred) palette, not red — the
    // money is fine, its provenance is just still pending.
    private func inheritedScarCallout(_ action: AppDiagnoseAction) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(DesignTokens.statusScarredFg)
            VStack(alignment: .leading, spacing: 6) {
                Text("Inherited provenance — pending")
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Text(action.reason)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.md, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.md))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusScarredBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
    }

    private func corruptionCallout(_ action: AppDiagnoseAction) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 16))
                .foregroundStyle(DesignTokens.statusRejectedFg)
            VStack(alignment: .leading, spacing: 6) {
                Text(FactChainCorruption.title)
                    .font(DesignTokens.Typography.bodyStrong)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                Text(FactChainCorruption.body)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: CommunitySupport.url) {
                    Label(CommunitySupport.label, systemImage: "arrow.up.forward.square")
                        .font(DesignTokens.Typography.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.md, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.md))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusRejectedBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
    }

    private var healCallout: some View {
        let isRequired = healUrgency == .required
        let scars = session.activeWallet?.factScarCount() ?? 0
        let stuck = stuckAmount(session.activeWallet)
        // diagnose() is priority-ordered — first action is the most
        // urgent, and its `reason` is already UI-displayable.
        let primary = healActions.first

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(isRequired ? "Heal required" : "Heal recommended")
                        .font(DesignTokens.Typography.bodyStrong)
                        .foregroundStyle(isRequired
                            ? DesignTokens.statusRejectedFg
                            : DesignTokens.statusScarredFg)
                    if scars > 0 {
                        scarCountChip(scars: scars, required: isRequired)
                    }
                }
                Text(primary?.reason ?? "Wallet needs a recovery pass.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                if stuck > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignTokens.textTertiary)
                        Text("\(formatBalance(stuck)) stuck in scarred links")
                            .font(DesignTokens.Typography.amountCaption)
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                }
            }
            Spacer()
            Button(isRequired ? "Heal now" : "Run heal") { showHealSheet = true }
                .buttonStyle(.borderedProminent)
                .tint(isRequired
                    ? DesignTokens.statusRejectedFg
                    : DesignTokens.statusScarredFg)
                .controlSize(.regular)
                // YPX-020: heal is rejected while hibernating — grey it out.
                .disabled(session.isHibernating)
                .help(session.isHibernating
                      ? "Paused — wallet is hibernating (finish HAL recovery first)"
                      : "")
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.md, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.md))
        .background(isRequired
            ? DesignTokens.statusRejectedBgSoft
            : DesignTokens.statusScarredBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
    }

    /// "N unresolved" chip — informational scar count, coloured by
    /// the diagnose-derived urgency (red when `.required`, amber when
    /// `.advisory`). The count itself doesn't gate anything; it's a
    /// burn-treadmill visibility signal (KI #5). `diagnose()` decides
    /// urgency — the chip just mirrors it.
    private func scarCountChip(scars: UInt32, required: Bool) -> some View {
        let fg = required ? DesignTokens.statusRejectedFg : DesignTokens.statusScarredFg
        let bg = required
            ? DesignTokens.statusRejectedBg
            : DesignTokens.statusScarredBg
        return Text("\(scars) unresolved")
            .font(DesignTokens.Typography.chip)
            .tracking(0.3)
            .foregroundStyle(fg)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(bg)
            .clipShape(Capsule())
    }

    /// Sum of `amount` across the wallet's currently-scarred FACT
    /// links. Returns 0 when the wallet has no scars or the FFI call
    /// is unavailable. Read once per heal-callout body computation —
    /// cheap (the underlying call walks a bounded chain at most
    /// `MAX_FACT_DEPTH` deep).
    private func stuckAmount(_ wallet: AxiomWallet?) -> UInt64 {
        guard let wallet else { return 0 }
        return wallet.listScarredLinks().reduce(UInt64(0)) { $0 + $1.amount }
    }

    // MARK: - Pair header

    private var pairHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text((session.activePair?.name ?? "—").uppercased())
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(session.activePair?.normal.email() ?? "—")
                    .font(DesignTokens.Typography.heading)
            }
            modeToggle
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                nablaTickIndicator
                oodsIndicator
                tardisDepthIndicator
            }
        }
    }

    // OODS reading stamped on the wallet's LAST receipt (YPX-021 §8.2) — the
    // network-size + health the network recorded during the last tx. Read from
    // the wallet's own receipt, NOT a live Nabla query. ALWAYS visible: shows
    // "OODS —" until the last receipt carries a flag (fresh wallet / no tx yet /
    // one register behind by design), so the row is never invisible.
    private var oodsIndicator: some View {
        let f = session.activeWallet?.lastReceiptOodsFlag()
        let dot: Color = f == nil
            ? DesignTokens.textTertiary
            : ((f?.healthy ?? true) ? DesignTokens.statusCleanFg : Color.orange)
        let label = f.map { "Nabla size \($0.oodsSize)\($0.healthy ? "" : " · may be out of sync")" }
            ?? "Nabla size —"
        // Educational tooltip — AxiomWallet is a demonstrator, so explain what
        // this is and cite the spec (YPX-021). Shown on hover over the capsule.
        let about = "Nabla size — the network's own estimate of how many nodes it can see (OODS-gossip, the forgery-resistant network-size estimate), used to detect eclipse / partition attacks: a healthy reading means your transaction was witnessed by a well-connected view of the network, not an isolated pocket. It is stamped onto your receipt during a transaction and read off the wallet here — never a live query.\n\nReference: AXIOM Yellow Paper Extension YPX-021 §6.2 (docs/AXIOM_YPX-021_OODS.md). AxiomWallet is a demonstrator."
        let help = f.map {
            "\(about)\n\nThis reading: ~\($0.oodsSize) nodes (network size), at TARDIS tick \($0.tick). \($0.healthy ? "The witnessing view was healthy." : "The witnessing view may have been out of sync (possible eclipse / partition).")"
        } ?? "\(about)\n\nNo reading yet — it appears from your NEXT transaction's receipt: the signed attestation rides the register response, so it lands one step behind your latest send/redeem."
        return HStack(spacing: 6) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
            Text(label)
                .font(DesignTokens.Typography.sectionLabel)
                .foregroundStyle(f == nil ? DesignTokens.textTertiary : DesignTokens.textSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(DesignTokens.bgTertiary)
        .clipShape(Capsule())
        .help(help)
    }

    // Writers ~N — a rough ESTIMATE of the active tick-producing nodes
    // (writers), as seen from this node. Backed by `lastTardisDepth()` (the
    // accessor keeps its historical name), but NOT a "depth": the live TARDIS
    // topology is a closed RING (no root), so the accumulator counts the
    // writers a tick circulated through — a noisy, per-node, UNDERCOUNTING
    // estimate (env: reads 2–4 against 5 real writers). Hence the "~"
    // qualifier + tooltip, which stop it reading as an exact network-wide
    // total. Distinct from "Nabla size" above (the network node count).
    // Transient: 0 until the first register on this run (or while a send holds
    // the wallet lock) → "—" (n/a). Informational only — NEVER a gate (a
    // hostile Nabla could lie about it). Re-reads on the periodic tick.
    // (YPX-021 §6.2 is being corrected Linux-side from "depth" to this
    // ring-aware writer-estimate framing.)
    private var tardisDepthIndicator: some View {
        TimelineView(.periodic(from: .now, by: 2.0)) { _ in
            let writers = session.activeWallet?.lastTardisDepth() ?? 0
            let na = writers == 0
            let help = "Rough estimate of active tick-producing nodes (writers), as seen from this node. Approximate and varies per node — not an exact count.\n\nReference: AXIOM Yellow Paper Extension YPX-021 §6.2. AxiomWallet is a demonstrator."
            return HStack(spacing: 6) {
                Circle()
                    .fill(na ? DesignTokens.textTertiary : DesignTokens.statusCleanFg)
                    .frame(width: 6, height: 6)
                Text(na ? "Writers —" : "Writers ~\(writers)")
                    .font(DesignTokens.Typography.sectionLabel)
                    .foregroundStyle(na ? DesignTokens.textTertiary : DesignTokens.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(DesignTokens.bgTertiary)
            .clipShape(Capsule())
            .help(help)
        }
    }

    // Last-Nabla-tick indicator. PASSIVE: shows the most recent
    // TARDIS tick the wallet observed from a Nabla response — captured
    // by the SDK on every register (genesis claim, send, heal). NO
    // active probing; clients connect to Nabla only in short bursts
    // per YPX-002. The `TimelineView` re-reads every 2s so the value
    // and the relative "seen N ago" stay current without the
    // surrounding view having to observe SDK state.
    private var nablaTickIndicator: some View {
        TimelineView(.periodic(from: .now, by: 2.0)) { context in
            // Merge SDK in-process observation with the
            // UserDefaults-persisted one — whichever has the more
            // recent `seenAt` wins. The SDK statics reset to 0 on
            // process relaunch; without the persisted fallback the
            // indicator would always show "TARDIS —" until the next
            // register op, even if a tick was observed minutes ago
            // in the previous session. See LastNablaTickStore.swift.
            let (tick, seenAt) = LastNablaTickStore.effective(
                sdkTick: sdkLastNablaTick(),
                sdkSeenAt: sdkLastNablaSeenAt(),
            )
            let live = tick != 0
            HStack(spacing: 6) {
                Circle()
                    .fill(live ? DesignTokens.statusCleanFg : DesignTokens.textTertiary)
                    .frame(width: 6, height: 6)
                Text(nablaTickLabel(tick: tick, seenAt: seenAt, now: context.date))
                    .font(DesignTokens.Typography.sectionLabel)
                    .foregroundStyle(live ? DesignTokens.textSecondary : DesignTokens.textTertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(DesignTokens.bgTertiary)
            .clipShape(Capsule())
            .help("The most recent Nabla TARDIS tick this wallet observed. Captured on register ops (genesis claim, send, heal) — the wallet does not poll Nabla continuously (YPX-002). The +<time> suffix counts wall-clock seconds since that observation; it persists across app relaunches via UserDefaults.")
        }
    }

    private func nablaTickLabel(tick: UInt64, seenAt: UInt64, now: Date) -> String {
        guard tick != 0 else { return "TARDIS —" }
        guard seenAt != 0 else { return "TARDIS \(tick)" }
        // "TARDIS <tick> + <N> <unit>" — the tick is the protocol-clock
        // base, the `+` increment is wall-clock seconds since we last
        // observed a Nabla response. Reads as "the network clock was
        // here, and this much time has passed since I heard from it."
        // The seenAt persists via LastNablaTickStore, so the elapsed
        // counter survives app relaunches — dev sessions that span
        // days will see "+ 3 day" rather than the timer resetting.
        let age = max(0, Int(now.timeIntervalSince1970) - Int(seenAt))
        let plus: String
        if age < 60 { plus = "+ \(age) sec" }
        else if age < 3600 { plus = "+ \(age / 60) min" }
        else if age < 86400 { plus = "+ \(age / 3600) hr" }
        else { plus = "+ \(age / 86400) day" }
        return "TARDIS \(tick) \(plus)"
    }

    private var modeToggle: some View {
        HStack(spacing: 2) {
            ForEach([WalletMode.normal, WalletMode.ark], id: \.self) { mode in
                let isActive = session.activeMode == mode
                let isAvailable = (mode == .normal) ||
                    (mode == .ark && session.activePair?.ark != nil)
                Button(action: {
                    if isAvailable { session.activeMode = mode }
                }) {
                    Text(modeLabel(mode))
                        .font(DesignTokens.Typography.sectionLabel)
                        .foregroundStyle(
                            !isAvailable ? DesignTokens.textTertiary :
                            isActive ? DesignTokens.textPrimary :
                                DesignTokens.textSecondary
                        )
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.vertical, 4)
                        .background(isActive ? DesignTokens.bgPrimary : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.chip))
                }
                .buttonStyle(.plain)
                .disabled(!isAvailable)
                .help(!isAvailable ? "Ark companion not generated for this wallet set." : "")
            }
        }
        .padding(2)
        .background(DesignTokens.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    private func modeLabel(_ m: WalletMode) -> String {
        switch m { case .normal: return "Normal"; case .ark: return "Ark" }
    }

    // MARK: - Balance hero

    private var balanceHero: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row: label on the left, inline icons (Settings /
            // Lock / Wallets) on the right. Replaces the old
            // top-bar profile chip + wallets icon.
            HStack(alignment: .top) {
                Text("TOTAL BALANCE · \(modeLabel(session.activeMode).uppercased()) MODE")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Spacer()
                balanceCardActions
            }
            VStack(alignment: .leading, spacing: 2) {
                let bal = session.activeWallet?.balance() ?? 0
                let isArk = session.activeMode == .ark
                Text(isArk ? formatBalanceArk(bal) : formatBalance(bal))
                    .font(DesignTokens.Typography.amountHero)
                Text(isArk ? formatAxcOnlyArk(bal) : formatAxcOnly(bal))
                    .font(DesignTokens.Typography.amount)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            Text(factChainSubtitle)
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
    }

    /// Right-side affordances on the balance card — "Address" (the
    /// receive-address sheet with QR + per-tier copy rows) and
    /// "Wallets" (pair management). Both sit next to the balance
    /// because both are about THIS wallet collection; navigation
    /// lives in the sidebar, Settings / Lock in the sidebar footer.
    private var balanceCardActions: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Button {
                showAddressesSheet = true
            } label: {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 12))
                    Text("Address")
                        .font(DesignTokens.Typography.label)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Copy this wallet's receive address / show QR")
            .disabled(session.activeWallet == nil)

            Button {
                showWalletsSheet = true
            } label: {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                    Text("Wallets")
                        .font(DesignTokens.Typography.label)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Wallet sets you have access to on this Mac — rename, export, change key")
        }
    }

    /// Wallets-management sheet — wraps WalletsView with a header bar
    /// and a Close button so the user has an unambiguous return path.
    @ViewBuilder
    private var walletsManagementSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Wallet sets")
                    .font(DesignTokens.Typography.bodyStrong)
                Spacer()
                Button("Close") { showWalletsSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 14))
            Divider()
            WalletsView()
                .environmentObject(session)
        }
        .frame(width: 720, height: 600)
    }

    private var factChainSubtitle: String {
        guard let wallet = session.activeWallet else { return "—" }
        let depth = wallet.factLinkCount()
        let scars = wallet.factScarCount()
        let inherited = wallet.inheritedScarCount()
        var parts = ""
        if scars > 0 { parts += " · \(scars) scar(s)" }
        // YPX-001 §1.5.1a: surface inherited taint so an inherited-tainted
        // wallet doesn't read as clean (own scar count is 0 for it).
        if inherited > 0 { parts += " · \(inherited) inherited" }
        // FACT_MAX_DEPTH=8 per YP §17.13.
        return "FACT chain \(depth) of 8 link(s)\(parts)"
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack(spacing: 10) {
            statusCard(
                label: "INCOMING",
                value: "\(session.activeWallet?.pendingChequeCount() ?? 0)",
                detail: "bundle(s) pending"
            )
            statusCard(
                label: "FACT STATUS",
                value: factStatusValue,
                valueColor: factStatusColor,
                detail: factStatusDetail
            )
            statusCard(
                label: companionCardLabel,
                value: companionBalanceValue,
                detail: companionBalanceDetail
            )
        }
    }

    private func statusCard(
        label: String,
        value: String,
        valueColor: Color = DesignTokens.textPrimary,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(label)
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text(value)
                .font(DesignTokens.Typography.heading)
                .foregroundStyle(valueColor)
            Text(detail)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private var factStatusValue: String {
        let scars = session.activeWallet?.factScarCount() ?? 0
        return scars == 0 ? "VERIFIED" : "ATTENTION"
    }

    private var factStatusColor: Color {
        let scars = session.activeWallet?.factScarCount() ?? 0
        return scars == 0 ? DesignTokens.statusCleanAccent : DesignTokens.statusScarredFg
    }

    private var factStatusDetail: String {
        let scars = session.activeWallet?.factScarCount() ?? 0
        let depth = session.activeWallet?.factLinkCount() ?? 0
        if scars == 0 {
            return "No scars · \(depth) of 8 chain links"
        } else {
            return "\(scars) scar(s) · resolve via Activity"
        }
    }

    // MARK: - Companion (other-side) card
    //
    // The third status card always shows the OTHER side of the
    // active pair. In Normal mode that's the Ark wallet; in Ark
    // mode that's the Normal wallet. Same atoms, just the wallet
    // the user isn't currently driving — at-a-glance visibility
    // into what's parked on the side they're not active on.

    /// Card label flips with `activeMode` — "ARK COMPANION" while
    /// the user is in Normal mode, "NORMAL COMPANION" in Ark.
    private var companionCardLabel: String {
        session.activeMode == .ark ? "NORMAL COMPANION" : "ARK COMPANION"
    }

    /// Formatted balance of the companion wallet. Em-dash when the
    /// companion isn't reachable (Ark not generated for this pair,
    /// or no active pair at all). The Ark variant adds the `⟠`
    /// glyph so the user can tell at a glance which side they're
    /// peeking at.
    private var companionBalanceValue: String {
        guard let pair = session.activePair else { return "—" }
        switch session.activeMode {
        case .normal:
            guard let ark = pair.ark else { return "—" }
            return formatBalanceArk(ark.balance())
        case .ark:
            return formatBalance(pair.normal.balance())
        }
    }

    /// One-line detail under the companion balance.
    private var companionBalanceDetail: String {
        guard let pair = session.activePair else { return "" }
        switch session.activeMode {
        case .normal:
            if pair.ark == nil { return "Companion not generated" }
            let bal = pair.ark?.balance() ?? 0
            return bal == 0 ? "Empty · for emergency use" : "Offline reserve"
        case .ark:
            let bal = pair.normal.balance()
            return bal == 0 ? "Empty · online side" : "Online side"
        }
    }

    // MARK: - Recent activity card

    /// Compact transaction history on the Overview — last 5 entries
    /// from `wallet.history()`. "See all" jumps to the full Activity
    /// tab (the table-with-search-and-CSV-export view). Empty state
    /// is a single-line note so the card stays present (gives the
    /// user a visual anchor for "yes this wallet is alive, just no
    /// traffic yet").
    private var activityPreview: some View {
        // KnownIssue #15 fix shipped: `wallet.history()` now uses
        // `try_lock + Vec cache` in the SDK FFI (same pattern as
        // `balance` / `factLinkCount` / etc), so calling it during
        // an in-flight `send()` returns the prior snapshot rather
        // than blocking the UI thread. The `sendCoordinator.isSending`
        // gate that wrapped this view is gone.
        let rows: [TxHistoryRow] = session.activeWallet
            .map { $0.history(limit: 5) } ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent activity")
                    .font(DesignTokens.Typography.bodyStrong)
                Spacer()
                Button {
                    session.selectedNav = .activity
                } label: {
                    HStack(spacing: 4) {
                        Text("See all")
                            .font(DesignTokens.Typography.caption)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(DesignTokens.brandPrimary)
                }
                .buttonStyle(.plain)
                .help("Open the full Activity tab — search, scars, CSV export")
            }
            if rows.isEmpty {
                VStack(spacing: 0) {
                    Text("No transactions yet.")
                        .font(DesignTokens.Typography.label)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.sm))
                }
                .background(DesignTokens.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        recentActivityRow(row)
                    }
                }
                .background(DesignTokens.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
            }
        }
    }

    /// One row in the Overview's recent-activity preview. Tighter
    /// than ActivityView's row (no tier pill, no fact-status chip,
    /// no monospaced amount-with-fact-state) — those details live
    /// in the full Activity tab.
    @ViewBuilder
    private func recentActivityRow(_ row: TxHistoryRow) -> some View {
        HStack(spacing: 12) {
            // Direction glyph — ↓ for inbound, ↑ for outbound, ✚ for heal.
            ZStack {
                Circle().fill(rowIconBg(row))
                    .frame(width: 22, height: 22)
                Text(rowIconGlyph(row))
                    .font(DesignTokens.Typography.labelStrong)
                    .foregroundStyle(rowIconFg(row))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(rowHeadline(row))
                    .font(DesignTokens.Typography.labelStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(rowRelativeTime(row))
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(rowAmountDisplay(row))
                .font(DesignTokens.Typography.amount)
                .foregroundStyle(rowAmountColor(row))
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
    }

    /// Per-row amount text. Heals are wallet-internal recovery
    /// self-sends with no counterparty value transfer, so showing
    /// "0.00 L$" reads as "zero money moved" which is misleading
    /// (the heal's job is state re-anchoring, not value). Display
    /// an em dash instead for clarity.
    private func rowAmountDisplay(_ row: TxHistoryRow) -> String {
        if row.txType == "heal" { return "—" }
        let isArk = session.activeMode == .ark
        let l = isArk ? formatBalanceArk(row.amount) : formatBalance(row.amount)
        return "\(rowAmountSign(row))\(l)"
    }

    private func rowIconGlyph(_ row: TxHistoryRow) -> String {
        switch row.txType {
        case "receive", "redeem": return "↓"
        case "send":              return "↑"
        case "heal":              return "✚"
        case "burn":              return "🔥"
        case "genesis":           return "★"
        default:                  return "·"
        }
    }

    private func rowIconBg(_ row: TxHistoryRow) -> Color {
        switch row.txType {
        case "receive", "redeem", "genesis": return DesignTokens.statusCleanBg
        case "burn":                          return DesignTokens.statusRejectedBg
        case "heal":                          return DesignTokens.statusScarredBg
        default:                              return DesignTokens.bgTertiary
        }
    }

    private func rowIconFg(_ row: TxHistoryRow) -> Color {
        switch row.txType {
        case "receive", "redeem", "genesis": return DesignTokens.statusCleanFg
        case "burn":                          return DesignTokens.statusRejectedFg
        case "heal":                          return DesignTokens.statusScarredFg
        default:                              return DesignTokens.textSecondary
        }
    }

    // Delegates to the shared `TxHistoryRow.displayHeadline` (defined in
    // ActivityView.swift) so this Overview preview mirrors the Activity list's
    // labelling exactly — including the "Airdrop" label for the genesis redeem.
    private func rowHeadline(_ row: TxHistoryRow) -> String { row.displayHeadline }

    private func rowAmountSign(_ row: TxHistoryRow) -> String {
        switch row.txType {
        case "send", "burn": return "−"
        case "receive", "redeem", "genesis": return "+"
        default: return ""
        }
    }

    private func rowAmountColor(_ row: TxHistoryRow) -> Color {
        switch row.txType {
        case "receive", "redeem", "genesis": return DesignTokens.statusCleanFg
        case "send", "burn":                  return DesignTokens.textPrimary
        default:                              return DesignTokens.textSecondary
        }
    }

    private func rowRelativeTime(_ row: TxHistoryRow) -> String {
        let now = UInt64(Date().timeIntervalSince1970)
        let age = now > row.timestamp ? now - row.timestamp : 0
        if age < 60       { return "just now" }
        if age < 3600     { return "\(age / 60) min ago" }
        if age < 86_400   { return "\(age / 3600) hr ago" }
        if age < 2_592_000 { return "\(age / 86_400) d ago" }
        return "\(age / 2_592_000) mo ago"
    }
}
