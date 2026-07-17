import SwiftUI
import AxiomSdk

// =================================================================
// MainAppView — the unlocked-wallet shell.
//
// macOS Golden Gate layout: full-height sidebar (edge-to-edge, all
// navigation + pair switching + utilities) and a detail column per
// selected pane. Resizable window; the old fixed 650×760 single-
// stack with pair tabs was replaced 2026-06-11.
//
//   ┌────────────┬──────────────────────────────────────┐
//   │ AXIØM      │ [dev / update / seed banners]        │
//   │ brand      │ [send / redeem / claim progress]     │
//   │            │ [pane context bar (non-Overview)]    │
//   │ Overview   │                                      │
//   │ Send       │   Active pane                        │
//   │ Receive    │   (Overview / Send / Receive /       │
//   │ Activity   │    Activity / Contacts)              │
//   │ Contacts   │                                      │
//   │            │                                      │
//   │ PAIRS      │                                      │
//   │ Personal   │                                      │
//   │ Treasury   │                                      │
//   │ + Add pair │                                      │
//   │ ────────── │                                      │
//   │ Wallets    │                                      │
//   │ Settings   │                                      │
//   │ Lock       │                                      │
//   └────────────┴──────────────────────────────────────┘
//
// The active pair determines which wallets the panes render.
// Switching pairs swaps the entire wallet context.
//
// Per the integration rule: every cell of data shown here came from
// the FFI. No URLSession, no direct TCP. Most cells are zero/empty
// for a fresh wallet — that's correct, not a stub.
// =================================================================

struct MainAppView: View {
    @EnvironmentObject private var session: AppSession
    /// Launch seed-fetch status — drives the "running on fallback" notice.
    @EnvironmentObject private var sdk: SdkBootstrap
    /// macOS 14+'s environment action that opens whatever `Settings`
    /// scene is registered at the App level. Same action the system's
    /// Cmd+, shortcut fires — keeping both paths on one mechanism
    /// avoids a custom window-management layer.
    @Environment(\.openSettings) private var openSettings
    /// In-flight background send — drives the top progress bar.
    @EnvironmentObject private var sendCoordinator: SendCoordinator
    /// In-flight background redeem — observed for finalize (pick tally).
    @EnvironmentObject private var redeemCoordinator: RedeemCoordinator
    /// In-flight background genesis claim — drives the claim chrome.
    @EnvironmentObject private var claimCoordinator: ClaimCoordinator
    /// Process-global SDK-version-skew observer.
    @EnvironmentObject private var versionSkew: VersionSkewWatcher
    @EnvironmentObject private var releaseUpdate: ReleaseUpdateWatcher
    @EnvironmentObject private var digitVersion: DigitVersionWatcher
    @State private var showAddPair: Bool = false
    /// The recovery/hibernation sheets (HAL re-anchor, HAL finish, RECALL
    /// finish) are driven by ONE `.sheet(item:)` instead of three chained
    /// `.sheet(isPresented:)` modifiers. Multiple `.sheet` modifiers on the
    /// same view is a macOS SwiftUI bug — only some present reliably, which
    /// is why "Finish recall…" (the outermost of the three) silently ignored
    /// the click while HAL's finish worked. One item-driven sheet presents
    /// every case reliably. YPX-020 (HAL) + YPX-022 (RECALL); the recall +
    /// HAL-complete paths share the same self-cheque redeem, only copy differs.
    private enum RecoverySheet: Int, Identifiable {
        case halReAnchor      // HAL re-anchor (from the dead-overlap banner)
        case halComplete      // HAL "Finish recovery" (redeem the distress cheque)
        case recallComplete   // RECALL "Finish recall" (redeem the recall cheque)
        var id: Int { rawValue }
    }
    @State private var recoverySheet: RecoverySheet? = nil
    /// Drives the brand-block popover — total balance across every
    /// wallet in the collection.
    @State private var showCollectionBalance: Bool = false
    /// User dismissed the seed-fallback notice for this session.
    @State private var seedNoticeDismissed: Bool = false
    /// Drives a periodic refresh of the sidebar "Receive" badge — the count of
    /// COMPLETE (fully-witnessed, redeemable) incoming cheques. Bumped by a
    /// light timer (catches arrivals) and on redeem outcomes (count drops).
    @State private var incomingBadgeTick: Int = 0
    /// Last optional-update version the user dismissed the banner for.
    /// Per-version: dismissing 2.16.1 won't re-nag for 2.16.1, but a
    /// newer 2.16.2 shows the banner again. Persisted across launches.
    @AppStorage("axiom.update.optionalDismissedVersion")
    private var optionalUpdateDismissedVersion: String = ""
    /// Observed so the sidebar's ChromeSurface re-renders the moment
    /// the user moves the translucency picker in Settings —
    /// ChromeSurface itself reads UserDefaults non-reactively.
    @AppStorage(ChromeTranslucency.storageKey)
    private var chromeTranslucencyRaw: Int = ChromeTranslucency.low.rawValue

    /// Hard cap on wallet pairs per Mac install. Each pair holds two
    /// wallets (Normal + Ark), so 5 pairs = 10 underlying wallets —
    /// roughly the upper bound where the sidebar pair list stays
    /// readable and per-pair maildir scans stay cheap.
    static let MAX_PAIRS: Int = 5

    var body: some View {
        // Plain HStack split, NOT NavigationSplitView (2026-06-11).
        // NavigationSplitView on the test Mac persistently laid its
        // columns out at the SCREEN's visible height (~1139pt) inside
        // a 720pt window — content spilled above the window top and
        // the saved "NSSplitView Subview Frames" defaults re-poisoned
        // every launch even after a state cleanse. A minimal repro
        // harness with the identical structure laid out correctly,
        // so the trigger is environmental; an HStack is deterministic
        // and gives the same Golden Gate full-height-sidebar look.
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
            Divider()
            detailColumn
        }
        .sheet(isPresented: $showAddPair) {
            AddPairView(onClose: { showAddPair = false })
        }
        // dv-change launch notice — same DvChangeCard as the pre-send gate,
        // worked against 1 AXC. Attached HERE (post-login) rather than at
        // the app root so it can never overlap the bio-auth prompt shown
        // before unlock. onAppear fires the once-per-launch tick after the
        // user reaches the main app; the guard makes idle-lock re-unlocks
        // a no-op within the same process.
        .onAppear { digitVersion.tickLaunchWarning() }
        .sheet(isPresented: $digitVersion.showLaunchWarning) {
            dvLaunchNoticeSheet()
        }
        // Push the active wallet's carrier preferences into the SDK
        // runtime on first appear (post-login) and on every pair / mode
        // switch. Without this, sets configured in a previous session
        // would sit in UserDefaults but the SDK would run on its
        // email-only default until the user happened to open Settings.
        .task {
            CarrierPreferences.pushActiveToSdk(session)
            IncomingCheckPreference.pushActiveToSdk(session)   // KI#34 WI2/WI5 baseline
        }
        .onChange(of: session.activePairIndex) { _ in
            CarrierPreferences.pushActiveToSdk(session)
            IncomingCheckPreference.pushActiveToSdk(session)
        }
        .onChange(of: session.activeMode) { _ in
            CarrierPreferences.pushActiveToSdk(session)
            IncomingCheckPreference.pushActiveToSdk(session)
        }
        // Refresh `versionSkew` whenever a background send resolves
        // successfully — that's the only path where SendCoordinator
        // owns the wallet handle for us, so the watcher itself can't
        // pull. Redeem refreshes inline in its own view.
        .onReceive(sendCoordinator.$lastOutcome) { outcome in
            if case .sent = outcome, let w = session.activeWallet {
                versionSkew.refresh(from: w)
                // Count this send's k witnesses into the per-validator
                // pick tally at finalize (idempotent per wallet_seq).
                ValidatorPickCounter.record(wallet: w)
                // A send's post-TX register touches a Nabla — fold the
                // picker's last-success deltas into the per-Nabla tally.
                NablaPickCounter.record(wallet: w)
            }
        }
        // Same for a background genesis claim — the claim now hands off
        // to ClaimCoordinator and dismisses, so the version-skew refresh
        // that used to run inline in GenesisClaimSheet moves here.
        .onReceive(redeemCoordinator.$lastOutcome) { outcome in
            if case .redeemed = outcome, let w = session.activeWallet {
                versionSkew.refresh(from: w)
                // A redeem is also a witnessed wallet TX — count its
                // witnesses at finalize (the inline refresh at redeem
                // START fires before wallet_seq advances).
                ValidatorPickCounter.record(wallet: w)
                // Redeem is the incoming-payment check — it consults Nabla
                // for §4.6 verify + register. Fold the per-Nabla tally.
                NablaPickCounter.record(wallet: w)
                // A redeem consumed an incoming cheque — drop the Receive badge.
                incomingBadgeTick &+= 1
            }
        }
        .onReceive(claimCoordinator.$lastOutcome) { outcome in
            if case .claimed = outcome, let w = session.activeWallet {
                versionSkew.refresh(from: w)
                ValidatorPickCounter.record(wallet: w)
                NablaPickCounter.record(wallet: w)
            }
        }
        // Keep the sidebar "Receive" badge live: a light poll catches cheques
        // that land while the user is on another pane; redeems bump it inline
        // above. Cheap — list_pending_cheque_bundles is a cached, local FFI read.
        .onReceive(Timer.publish(every: 4, on: .main, in: .common).autoconnect()) { _ in
            incomingBadgeTick &+= 1
        }
        // One-shot blocking alert the first time we detect the mesh's
        // min-client floor has overtaken our baked client version.
        // `alertPending` flips to false when the user dismisses; the
        // persistent banner above + the disabled broadcast buttons
        // keep the state visible afterwards.
        .alert("Update Required",
               isPresented: $versionSkew.alertPending) {
            Button("OK") { versionSkew.alertPending = false }
        } message: {
            Text("Your AXIOM wallet is out of date and may misinterpret responses from the network. Please update before your next transaction. (server v\(versionSkew.serverProtocolVersion), your client v\(versionSkew.clientProtocolVersion))")
        }
        // One-shot blocking alert when the release feed reports a build
        // on a DIFFERENT CoreID — the network's canonical Core rotated,
        // so this client is rejected at the CoreID gate and must update
        // before it can transact. Distinct from the protocol-version
        // alert above. The Settings "Software updates" card carries the
        // Download button and persists the state after dismissal.
        .alert("Update Required",
               isPresented: $releaseUpdate.mandatoryAlertPending) {
            if releaseUpdate.verdict.releaseInfo?.url != nil {
                Button("Download") {
                    releaseUpdate.mandatoryAlertPending = false
                    Task { await releaseUpdate.downloadAndReveal() }
                }
            }
            Button("Later", role: .cancel) { releaseUpdate.mandatoryAlertPending = false }
        } message: {
            if case .mandatory(let info) = releaseUpdate.verdict {
                Text("The AXIOM network has upgraded its Core (new CoreID \(String(info.coreId.prefix(8)))…). Core upgrades are rare in production, but when one happens it is mandatory: this wallet runs an older Core, and transacting against a Core the validators no longer run would make your wallet's computed state diverge from the network's — which can permanently damage this wallet. Send, Redeem, and Claim are locked until you install \(info.version). (Yellow Paper §23.10 — Core Upgrade as State Transition; §16.8.3 — client and validators must run the same Core.)")
            } else {
                Text("A required update is available. Open Settings → About → Software updates to download.")
            }
        }
        // (L$ digit_version change is surfaced as a pre-send confirmation
        // gate in SendView — see DigitVersionWatcher.needsSendWarning —
        // not as a post-transaction alert.)
    }

    // MARK: - Sidebar

    /// Single-flight wallet rule (YP §32): true while ANY wallet TX —
    /// send, redeem, or genesis claim — is in flight. Drives the sidebar's
    /// Send/Receive nav greying; the panes' own action buttons carry the
    /// same gate (canSign / BundleDetail redeem / Claim CTA).
    private var txInFlight: Bool {
        sendCoordinator.isSending
            || redeemCoordinator.isRedeeming
            || claimCoordinator.isClaiming
    }

    /// Tooltip naming WHICH operation is holding the wallet.
    private var inFlightHint: String {
        if sendCoordinator.isSending { return "A send is in progress — one wallet transaction at a time" }
        if redeemCoordinator.isRedeeming { return "A redeem is in progress — one wallet transaction at a time" }
        if claimCoordinator.isClaiming { return "The genesis claim is in progress — one wallet transaction at a time" }
        return ""
    }

    /// List selection wants an Optional binding; the session keeps a
    /// non-optional NavItem (there is always an active pane). Ignore
    /// the nil writes List emits on deselection.
    /// Belt-and-braces on the single-flight grey-out: refuse a Send /
    /// Receive selection while a TX is in flight (`selectionDisabled`
    /// already blocks the row; this catches any programmatic path).
    private var navSelection: Binding<NavItem?> {
        Binding(
            get: { session.selectedNav },
            set: { if let v = $0 {
                if txInFlight && (v == .send || v == .receive) { return }
                session.selectedNav = v
            } }
        )
    }

    /// Launch-time dv-change notice. Same visual as the pre-send gate
    /// (DvChangeCard) but worked against 1 AXC so the user sees the new
    /// L$ scale on a familiar round amount. One [Got it] button counts
    /// the launch (1/3 … 3/3); after the 3rd it stops appearing. Shown
    /// post-login (attached in body) so it never overlaps bio-auth.
    @ViewBuilder
    private func dvLaunchNoticeSheet() -> some View {
        // 1 AXC = 10^10 atoms (ATOMS_PER_AXC). Worked example amount.
        let oneAxcAtoms: UInt64 = 10_000_000_000
        VStack(spacing: DesignTokens.Spacing.lg) {
            DvChangeCard(
                atoms: oneAxcAtoms,
                fromDV: digitVersion.fromDV,
                counter: digitVersion.launchWarningCounter,
                topLabel: "EXAMPLE: 1 AXC",
                date: digitVersion.effectiveDate
            )
            Button("Got it") {
                digitVersion.consumeLaunchWarning()
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignTokens.brandPrimary)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 460)
    }

    /// Count of COMPLETE, redeemable incoming cheques for the active wallet —
    /// drives the sidebar "Receive" badge. "Redeemable" means: it has reached its
    /// required k witness signatures (NOT partial), AND it isn't REJECTED (a Nabla
    /// double-spend flag — money you can't actually take). Partial and rejected
    /// bundles are excluded so the badge only ever means "you have N to receive."
    /// Reads `incomingBadgeTick` so the timer/redeem bump re-evaluates it.
    private var incomingReadyCount: Int {
        _ = incomingBadgeTick
        return (session.activeWallet?.listPendingChequeBundles() ?? [])
            .filter { $0.signatureCount >= $0.requiredK && $0.displayStatus != "rejected" }
            .count
    }

    private var sidebar: some View {
        // Read the preference so this view re-renders on change.
        let _ = chromeTranslucencyRaw
        return VStack(spacing: 0) {
            brandBlock
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.xs)

            activeWalletCard
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.bottom, DesignTokens.Spacing.sm)

            List(selection: navSelection) {
                Section {
                    ForEach(NavItem.allCases, id: \.self) { item in
                        // Single-flight wallet rule (YP §32): while a send /
                        // redeem / genesis claim is in flight, the Send and
                        // Receive panes can't start anything anyway (their
                        // action buttons are gated) — grey the NAV ROWS too
                        // so the sidebar doesn't advertise actions the wallet
                        // can't take right now. Read-only panes (Overview /
                        // Activity / Contacts) stay live.
                        let busyGated = txInFlight && (item == .send || item == .receive)
                        HStack(spacing: 0) {
                            Label(item.title, systemImage: item.symbol)
                            if busyGated {
                                Spacer(minLength: 4)
                                ProgressView().controlSize(.mini)
                            }
                        }
                            .tag(item)
                            // Receive shows a count of COMPLETE (redeemable)
                            // incoming cheques. `.badge(0)` renders nothing, so
                            // every other row (and an empty inbox) stays clean.
                            .badge(item == .receive && !busyGated ? incomingReadyCount : 0)
                            // Opacity, not foregroundStyle — preserves the
                            // List's own selected/unselected label styling.
                            .opacity(busyGated ? 0.4 : 1)
                            .selectionDisabled(busyGated)
                            .help(busyGated ? inFlightHint : "")
                    }
                }
                Section("Wallet sets") {
                    ForEach(Array(session.pairs.enumerated()), id: \.offset) { index, pair in
                        pairRow(index: index, pair: pair)
                    }
                    addPairRow
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            sidebarFooter
        }
        // Sidebar is chrome — the ONE place material is allowed, and
        // only through the translucency gate (user preference, LOW by
        // default; OS Reduce Transparency wins unconditionally).
        .background(ChromeSurface())
    }

    /// Prominent active-wallet card — pinned at the TOP of the sidebar, above
    /// the Send/Receive/Activity actions, so it's unmistakable which wallet an
    /// action will draw from. The pair switcher stays below; this is the
    /// at-a-glance indicator.
    private var activeWalletCard: some View {
        Group {
            if let pair = session.activePair {
                let isArk = session.activeMode == .ark
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("ACTIVE WALLET")
                            .font(DesignTokens.Typography.sectionLabel)
                            .tracking(0.6)
                            .foregroundStyle(DesignTokens.statusCleanAccent)
                        Spacer()
                        Text(isArk ? "ARK" : "NORMAL")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: "wallet.pass.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignTokens.statusCleanAccent)
                        Text(pair.name)
                            .font(DesignTokens.Typography.heading)
                            .foregroundStyle(DesignTokens.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: DesignTokens.Spacing.xs)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        // L$ (display unit, scales with digit_version)
                        Text(isArk
                             ? formatBalanceArk(session.activeWallet?.balance() ?? 0)
                             : formatBalance(session.activeWallet?.balance() ?? 0))
                            .font(DesignTokens.Typography.amountCaption)
                            .foregroundStyle(DesignTokens.textSecondary)
                        // AXC (protocol unit, invariant)
                        Text(formatAxcOnly(session.activeWallet?.balance() ?? 0))
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                }
                .padding(DesignTokens.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.statusCleanBgSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                        .strokeBorder(DesignTokens.statusCleanAccent.opacity(0.35), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
            }
        }
    }

    /// One wallet pair in the sidebar — name + compact balance.
    /// Tapping switches the active pair (and resets to Normal mode,
    /// same semantics as the old pair tabs).
    private func pairRow(index: Int, pair: LoadedPair) -> some View {
        let isActive = index == session.activePairIndex
        return Button {
            session.activePairIndex = index
            session.activeMode = .normal
        } label: {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: isActive ? "circle.inset.filled" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(isActive
                        ? DesignTokens.statusCleanAccent
                        : DesignTokens.textTertiary)
                Text(pair.name)
                    .font(isActive
                        ? DesignTokens.Typography.labelStrong
                        : DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.Spacing.xs)
                Text(formatBalance(pair.normal.balance()))
                    .font(DesignTokens.Typography.amountCaption)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isActive
            ? "Active wallet set"
            : "Switch to the \(pair.name) wallet set")
        .accessibilityLabel("\(pair.name) wallet set\(isActive ? ", active" : "")")
    }

    private var addPairRow: some View {
        Button { showAddPair = true } label: {
            Label("Add wallet set…", systemImage: "plus")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(session.pairs.count >= Self.MAX_PAIRS
                    ? DesignTokens.textTertiary
                    : DesignTokens.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(session.pairs.count >= Self.MAX_PAIRS)
        .help(session.pairs.count >= Self.MAX_PAIRS
            ? "Maximum of \(Self.MAX_PAIRS) wallet sets per Mac — remove one from Wallets to add another"
            : "Create or load another wallet set")
    }

    /// Pinned utility rows at the bottom of the sidebar — Settings
    /// (native Preferences window) and Lock. Wallet-pair management
    /// lives on the Overview balance card ("Wallets", next to
    /// Address) since 2026-06-11 — it belongs with the wallet it
    /// manages, not with app chrome.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            sidebarFooterButton("Settings…", symbol: "gearshape",
                                help: "Preferences (⌘,)") {
                openSettings()
            }
            sidebarFooterButton("Lock", symbol: "lock.fill",
                                help: "Lock the app — wipes in-memory keys, returns to login") {
                session.lock()
            }
        }
        .padding(DesignTokens.Spacing.xs)
    }

    private func sidebarFooterButton(_ title: String,
                                     symbol: String,
                                     help: String,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(DesignTokens.textSecondary)
                Text(LocalizedStringKey(title))
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Spacing.xs)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(LocalizedStringKey(help))
    }

    /// Brand strip at the top of the sidebar — seal + wordmark +
    /// version. Tapping it opens a popover with the total balance
    /// across every wallet in the collection.
    private var brandBlock: some View {
        Button(action: { showCollectionBalance.toggle() }) {
            HStack(spacing: 10) {
                AxiomSeal(color: DesignTokens.axiomBlack, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    AxiomWordmark(size: 13, color: DesignTokens.axiomBlack)
                    Text(AxiomVersion.app)
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.3)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Total balance across every wallet in your collection")
        .popover(isPresented: $showCollectionBalance, arrowEdge: .bottom) {
            collectionBalanceContent
        }
    }

    /// Popover content for the brand block — the collection's total
    /// balance with a per-pair breakdown. Every pair contributes its
    /// Normal wallet plus its Ark companion when one exists.
    @ViewBuilder
    private var collectionBalanceContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("COLLECTION TOTAL")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                BalanceText(
                    atoms: collectionTotalAtoms,
                    primaryFont: .system(size: 20, weight: .semibold, design: .monospaced),
                    secondaryFont: .system(size: 11, design: .monospaced)
                )
                Text(collectionCountLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(session.pairs.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(pair.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DesignTokens.textPrimary)
                        Spacer(minLength: 0)
                        BalanceText(
                            atoms: pairTotalAtoms(pair),
                            primaryFont: .system(size: 12, design: .monospaced),
                            secondaryFont: .system(size: 9, design: .monospaced),
                            alignment: .trailing
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minWidth: 264, alignment: .leading)
    }

    /// Atoms held by one pair — Normal wallet plus its Ark companion
    /// when present.
    private func pairTotalAtoms(_ pair: LoadedPair) -> UInt64 {
        pair.normal.balance() + (pair.ark?.balance() ?? 0)
    }

    /// Atoms summed across every wallet in the collection.
    private var collectionTotalAtoms: UInt64 {
        session.pairs.reduce(UInt64(0)) { $0 + pairTotalAtoms($1) }
    }

    /// "3 wallet sets · 5 wallets" — sets, plus the Ark companions that exist.
    private var collectionCountLabel: String {
        let pairCount = session.pairs.count
        let walletCount = session.pairs.reduce(0) { $0 + 1 + ($1.ark != nil ? 1 : 0) }
        let pairWord = pairCount == 1 ? "wallet set" : "wallet sets"
        let walletWord = walletCount == 1 ? "wallet" : "wallets"
        return "\(pairCount) \(pairWord) · \(walletCount) \(walletWord)"
    }

    // MARK: - Detail column

    private var detailColumn: some View {
        VStack(spacing: 0) {
            if isActiveWalletDev {
                devClassBanner
            }
            if versionSkew.isSdkTooOld {
                sdkTooOldBanner
            }
            if releaseUpdate.verdict.isMandatory {
                coreUpgradeBanner
            }
            // YPX-020: hibernation status (after a HAL re-anchor) +
            // the dead-overlap recovery offer. Both wrapped so the
            // countdown ticks / the window clears itself live.
            hibernationBanner
            halRecoveryBanner
            // Optional (same-Core) update — a recommended, non-blocking
            // banner so a bugfix release is visible up front instead of
            // only in Settings. Dismissible per-version (won't re-nag for
            // the same version, but a newer one shows again).
            if case .optional(let info) = releaseUpdate.verdict,
               info.version != optionalUpdateDismissedVersion {
                optionalUpdateBanner(info)
            }
            if sdk.seedFetchDegraded && !seedNoticeDismissed {
                seedFallbackBanner
            }
            #if DEBUG
            // Tester fault-injection state — renders nothing unless a
            // fault is armed; impossible-to-miss when one is. DEBUG-only
            // (compiled out of the release build).
            ActiveFaultsBanner()
            #endif
            // Background-send chrome — both render nothing when idle.
            SendProgressBar()
            SendOutcomeBanner()
            // Background-redeem chrome — same pattern, parallel
            // ownership in AxiomWalletApp's @StateObject. Pre-fix
            // redeem ran in BundleDetailView's Task.detached and
            // died when the sheet closed; now it lives at the app
            // level and survives sheet dismissal.
            RedeemProgressBanner()
            RedeemOutcomeBanner()
            // Background genesis-claim chrome — same pattern as send /
            // redeem. The claim sheet hands off to ClaimCoordinator and
            // dismisses; the 5-stage progress + tappable success detail
            // live here so the witness round survives sheet dismissal
            // and never freezes the UI.
            ClaimProgressBanner()
            ClaimOutcomeBanner()
            // Uniform context bar on every non-Overview pane: which
            // pair/mode is active + its balance, on a SOLID surface
            // (money never sits on material). Overview carries the
            // full balance hero itself.
            if session.selectedNav != .overview {
                paneContextBar
            }
            routedPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignTokens.bgPrimary)
        // YPX-020 — keep the hibernation gate fresh. `refreshHibernation()`
        // is otherwise written only on pair/mode switch + HAL commit, so a
        // wallet that enters (or persists) hibernation by any other path
        // could leave Send/Redeem reading a stale `isHibernating=false` and
        // wrongly enabled. Re-read on every tab navigation (cheap — one
        // cached FFI read) so landing on Send/Receive always reflects the
        // wallet's current on-disk flag.
        .onChange(of: session.selectedNav) { _ in session.refreshHibernation() }
        .onAppear { session.refreshHibernation() }
        // Uniform toolbar: the detail column's title is the active
        // pane, on every view.
        .navigationTitle(session.selectedNav.title)
        .sheet(item: $recoverySheet) { which in
            switch which {
            case .halReAnchor:
                HalRecoverySheet(
                    mode: .reAnchor,
                    onCancel: { recoverySheet = nil },
                    onCompletion: {
                        // Re-anchor finished — the offer is resolved
                        // regardless of commit/retry; clear both coordinators'
                        // sticky flags so the dead-overlap banner drops. If it
                        // committed, the wallet is now hibernating and the
                        // hibernationBanner takes over (Finish recovery).
                        recoverySheet = nil
                        sendCoordinator.clearReanchorOffer()
                        redeemCoordinator.clearReanchorOffer()
                    }
                )
                .environmentObject(session)
            case .halComplete:
                HalRecoverySheet(
                    mode: .complete,
                    onCancel: { recoverySheet = nil },
                    onCompletion: { recoverySheet = nil },
                    onRestart: {
                        // Dead-new-quorum edge (§7 case 4): re-enter HAL with
                        // a fresh validator set via another re-anchor. Dismiss
                        // first, then re-present next runloop tick so the
                        // item-sheet swap is clean.
                        recoverySheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            recoverySheet = .halReAnchor
                        }
                    }
                )
                .environmentObject(session)
            case .recallComplete:
                RecallConfirmSheet(
                    onCancel: { recoverySheet = nil },
                    onCompletion: { recoverySheet = nil },
                    mode: .complete
                )
                .environmentObject(session)
            }
        }
    }

    // MARK: - YPX-020 HAL banners

    /// Shown while the active wallet is HIBERNATING (binary flag, after a
    /// HAL re-anchor OR a committed RECALL — same mechanism, YPX-022 reuses
    /// the HAL hibernation lock with its own window). Presence is gated on
    /// the binary flag (does NOT auto-clear — only the completion redeem
    /// clears it); the inner TimelineView only ticks an ESTIMATE of the
    /// convergence window so the user knows roughly when to attempt the
    /// finish (it's an upper bound — see
    /// AppSession.hibernationConvergenceEstimateSecs). A pending recall
    /// record flips the copy + routes the finish to the recall sheet — the
    /// underlying completion is the same shared self-cheque redeem.
    @ViewBuilder
    private var hibernationBanner: some View {
        if session.isHibernating {
            let recalling = session.hasPendingRecall
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let est = session.hibernationConvergenceEstimateSecs()
                let window = est > 0
                    ? "est. convergence window \(HalRecovery.estimateLabel(est)) remaining"
                    : (recalling
                       ? "convergence window passed — likely ready, finish the recall now"
                       : "convergence window passed — likely ready, finish recovery now")
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.statusScarredFg)
                    Text(recalling ? "WALLET HIBERNATING — RECALL CONVERGING" : "WALLET HIBERNATING")
                        .font(DesignTokens.Typography.chip)
                        .tracking(0.6)
                        .foregroundStyle(DesignTokens.statusScarredFg)
                    Text(recalling
                         ? "· \(window). The retract is settling network-wide; send/redeem paused until you finish the recall — that redeem credits the recovered amount."
                         : "· \(window). Send/redeem paused until you finish recovery — clears only on completion, not a timer.")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(recalling ? "Finish recall…" : "Finish recovery…") {
                        recoverySheet = recalling ? .recallComplete : .halComplete
                    }
                        .controlSize(.small)
                }
                .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .background(DesignTokens.statusScarredBgSoft)
                .overlay(
                    Rectangle()
                        .fill(DesignTokens.statusScarredFg.opacity(0.35))
                        .frame(height: DesignTokens.hairline),
                    alignment: .bottom
                )
            }
        }
    }

    /// Shown when the last send/redeem failed with dead-overlap — the
    /// wallet's prior validators are gone and heal() can't recover it.
    /// Offers the HAL re-anchor. Sticky (the coordinators hold the flag)
    /// so it survives the transient outcome banner; dismissable.
    @ViewBuilder
    private var halRecoveryBanner: some View {
        if (sendCoordinator.deadOverlapNeedsReanchor
            || redeemCoordinator.deadOverlapNeedsReanchor)
            && !session.isHibernating {
            HStack(spacing: 8) {
                Image(systemName: "lifepreserver.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Text("WALLET STUCK — RE-ANCHOR NEEDED")
                    .font(DesignTokens.Typography.chip)
                    .tracking(0.6)
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Text("· this wallet's prior validators are gone, so it can't meet the overlap on a normal send. Heal can't fix this — re-anchor (HAL) to recover.")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Re-anchor wallet (HAL)…") { recoverySheet = .halReAnchor }
                    .controlSize(.small)
                Button {
                    sendCoordinator.clearReanchorOffer()
                    redeemCoordinator.clearReanchorOffer()
                } label: {
                    Image(systemName: "xmark").font(DesignTokens.Typography.chip)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .background(DesignTokens.statusScarredBgSoft)
            .overlay(
                Rectangle()
                    .fill(DesignTokens.statusScarredFg.opacity(0.35))
                    .frame(height: DesignTokens.hairline),
                alignment: .bottom
            )
        }
    }

    @ViewBuilder
    private var routedPane: some View {
        switch session.selectedNav {
        case .overview: OverviewView()
        case .send:     SendView()
        case .receive:  ReceiveView()
        case .activity: ActivityView()
        case .contacts: ContactsView()
        }
    }

    /// Compact identity + balance strip above Send / Receive /
    /// Activity / Contacts so the user never loses sight of which
    /// wallet they're operating and what it holds.
    private var paneContextBar: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text((session.activePair?.name ?? "—").uppercased())
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(session.activePair?.normal.email() ?? "—")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DesignTokens.Spacing.md)
            BalanceText(
                atoms: session.activeWallet?.balance() ?? 0,
                alignment: .trailing,
                ark: session.activeMode == .ark
            )
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(DesignTokens.bgSecondary)
        .overlay(
            Rectangle()
                .fill(DesignTokens.borderTertiary)
                .frame(height: DesignTokens.hairline),
            alignment: .bottom
        )
    }

    // MARK: - Banners

    /// "Update required" strip pinned to the top of the wallet shell
    /// whenever `is_sdk_too_old()` has fired. Non-dismissible — the
    /// state is consequential (broadcasts are unsafe) and the user
    /// must remain aware until they reinstall a newer build.
    /// Visual weight matches `devClassBanner` (also non-dismissible).
    private var sdkTooOldBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.statusRejectedFg)
            Text("UPDATE REQUIRED")
                .font(DesignTokens.Typography.chip)
                .tracking(0.6)
                .foregroundStyle(DesignTokens.statusRejectedFg)
            Text("· network is on protocol v\(versionSkew.serverProtocolVersion); this wallet is v\(versionSkew.clientProtocolVersion). Send, Redeem, and Claim are disabled until you install a newer build.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .background(DesignTokens.statusRejectedBgSoft)
        .overlay(
            Rectangle()
                .fill(DesignTokens.statusRejectedFg.opacity(0.35))
                .frame(height: DesignTokens.hairline),
            alignment: .bottom
        )
    }

    /// Pinned, non-dismissible banner when the release feed reports a
    /// build on a DIFFERENT CoreID — the network has upgraded its Core.
    /// Send, Redeem, and Claim are hard-disabled (see canSign / the
    /// redeem + claim gates). Core upgrades are rare in production, but
    /// mandatory: transacting against a Core the validators no longer run
    /// would make this wallet's computed state diverge from the network's
    /// and can permanently damage the wallet (YP §23.10 Core Upgrade as
    /// State Transition; §16.8.3 client + validators run the same Core).
    private var coreUpgradeBanner: some View {
        let target = releaseUpdate.verdict.releaseInfo?.version ?? "the latest build"
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.statusRejectedFg)
            Text("CORE UPGRADE REQUIRED")
                .font(DesignTokens.Typography.chip)
                .tracking(0.6)
                .foregroundStyle(DesignTokens.statusRejectedFg)
            Text("· the network upgraded its Core. Send, Redeem, and Claim are locked — transacting on a mismatched Core would diverge this wallet from the network and can damage it (Yellow Paper §23.10). Install \(target) to continue.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Update…") {
                Task { await releaseUpdate.downloadAndReveal() }
            }
            .controlSize(.small)
            .disabled(releaseUpdate.downloading || releaseUpdate.verdict.releaseInfo?.url == nil)
        }
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .background(DesignTokens.statusRejectedBgSoft)
        .overlay(
            Rectangle()
                .fill(DesignTokens.statusRejectedFg.opacity(0.35))
                .frame(height: DesignTokens.hairline),
            alignment: .bottom
        )
    }

    /// Dismissible banner for an OPTIONAL (same-Core) update — a newer
    /// build is available and recommended, but the network still accepts
    /// this one, so nothing is blocked. Surfaces the update up front
    /// instead of only in Settings → About → Software updates. Amber
    /// (advisory), with Update + dismiss-for-this-version controls.
    private func optionalUpdateBanner(_ info: ReleaseInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.statusScarredFg)
            Text("UPDATE AVAILABLE")
                .font(DesignTokens.Typography.chip)
                .tracking(0.6)
                .foregroundStyle(DesignTokens.statusScarredFg)
            Text("· version \(info.version) is available (same Core) — recommended. Open it from here or Settings → About → Software updates.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(releaseUpdate.downloading ? "Downloading…" : "Update…") {
                Task { await releaseUpdate.downloadAndReveal() }
            }
            .controlSize(.small)
            .disabled(releaseUpdate.downloading || info.url == nil)
            Button {
                optionalUpdateDismissedVersion = info.version
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.textTertiary)
            .help("Dismiss until the next version")
        }
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .background(DesignTokens.statusScarredBgSoft)
        .overlay(
            Rectangle()
                .fill(DesignTokens.statusScarredFg.opacity(0.35))
                .frame(height: DesignTokens.hairline),
            alignment: .bottom
        )
    }

    /// Whether the active wallet is a developer (@axiom.internal)
    /// wallet. Drives the DEV banner — see `AXIOM_DESIGN_FactClassIsolation.md`.
    private var isActiveWalletDev: Bool {
        guard let email = session.activeWallet?.email() else { return false }
        return walletClass(ofEmail: email) == .devClass
    }

    /// DEV banner — pinned to the top of the wallet view whenever
    /// the active wallet is `@axiom.internal` class. Not dismissible:
    /// the user must always know they're operating on a developer
    /// test wallet, not real production AXC. Same visual weight
    /// pattern as `seedFallbackBanner` below.
    private var devClassBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.statusScarredFg)
            Text("DEVELOPER WALLET")
                .font(DesignTokens.Typography.chip)
                .tracking(0.6)
                .foregroundStyle(DesignTokens.statusScarredFg)
            Text("· @axiom.internal class — dev-AXC sandbox, isolated from public production supply. Not real AXC.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .background(DesignTokens.statusScarredBgSoft)
        .overlay(
            Rectangle()
                .fill(DesignTokens.statusScarredFg.opacity(0.35))
                .frame(height: DesignTokens.hairline),
            alignment: .bottom
        )
    }

    /// Non-fatal notice strip — shown when the launch seed-fetch
    /// couldn't reach axiom-dist and the wallet is on the bundled
    /// fallback list. Dismissible: the wallet still transacts (Plain
    /// envelopes; witness authenticity is VBC-anchored, not seed-key
    /// based) and self-enriches as discovery + the VBC cross-check
    /// refill the list.
    private var seedFallbackBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.statusScarredFg)
            Text("Couldn't fetch the latest validator / Nabla seed list — running on the built-in fallback. Refresh anytime in Settings → Network.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: { seedNoticeDismissed = true }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.bgSecondary)
        .overlay(
            Rectangle().fill(DesignTokens.borderSecondary).frame(height: DesignTokens.hairline),
            alignment: .bottom
        )
    }
}

// MARK: - Sidebar nav identity

enum NavItem: CaseIterable, Hashable {
    case overview, send, receive, activity, contacts
    // Wallets is intentionally NOT here — wallet-pair management
    // opens as a sheet from the sidebar footer, not a routed pane
    // (the routed-pane version had no return path).
    // Settings is intentionally NOT here either — it lives in its
    // own native Preferences window (Cmd+, / sidebar footer →
    // Settings…). Open the Settings scene via
    // `@Environment(\.openSettings)`.

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .send: return "Send"
        case .receive: return "Receive"
        case .activity: return "Activity"
        case .contacts: return "Contacts"
        }
    }

    /// Sidebar SF Symbol — outline weights, consistent family.
    var symbol: String {
        switch self {
        case .overview: return "rectangle.grid.2x2"
        case .send: return "arrow.up.circle"
        case .receive: return "tray.and.arrow.down"
        case .activity: return "clock"
        case .contacts: return "person.2"
        }
    }
}

// MARK: - Format helpers (UI-only — no protocol semantics)

/// Process-wide L$ digit_version (YP §2.3, White Paper §J.14-J.18).
/// `1 AXC = 10^N L$` where N = `current`. AXC itself is always
/// `10^10` atoms regardless of digit_version — only the L$
/// display scale changes.
///
/// Default `0` matches Lambda's `management_db::get_digit_version`
/// default (`Ok(0)` on missing row), which is the live network's
/// current state since no Console proposal has fired yet. The
/// value is mutable so a future FFI call can update it:
///
///   ```swift
///   DigitVersionState.current = wallet.digitVersion()   // TODO
///   ```
///
/// That FFI doesn't exist yet — the SDK has no Lambda-admin
/// channel. Adding `axiom_sdk::wallet::digit_version()` (which
/// would itself need Lambda → Nabla → SDK plumbing on the Linux
/// side) is a separate task. Until then this stays at 0 and the
/// formatter behaves exactly as it did before parameterisation.
///
/// Accessed only from the main thread (SwiftUI body builders),
/// so plain `static var` is safe — no isolation needed.
enum DigitVersionState {
    static var current: UInt8 = 0
}

/// `10^n` as `UInt64` — avoids Foundation `pow` precision loss on
/// big magnitudes. Returns 1 when `n <= 0`.
private func pow10u(_ n: Int) -> UInt64 {
    if n <= 0 { return 1 }
    var r: UInt64 = 1
    for _ in 0..<n { r *= 10 }
    return r
}

// =================================================================
// AXC / L$ / atom formatters — Swift adapters around the canonical
// Rust formatters in `axiom-denomination` (exposed via SDK FFI as
// `formatAxc(atoms:)` and `formatLdollar(atoms:dv:)`).
//
// Before 2026-05-26 these functions did the arithmetic in Swift,
// drifted from the Rust formatters, and shipped a `String(format:
// "%010d", UInt64(8_420_000_000))` underflow that rendered 0.842
// AXC as "0.-169934592 AXC" (tester report on johnny@axiom.internal).
// Now they are one-line delegations — single source of truth lives
// in Rust, no chance of language-boundary drift.
//
// Kept as Swift functions (rather than inlined `formatAxc(atoms:)`
// at every call site) for two reasons: (a) call sites stay short,
// (b) the Ark variants below add the `⟠ ` visual prefix per YP §22
// — a Mac-specific UX cue that doesn't belong in the Rust crate.
// =================================================================

/// L$ display, scaled to the current `DigitVersionState.current`.
/// Single-source: routes through the SDK FFI to `axiom_denomination`.
/// L$-only — for prose strings ("Send 100.00 L$ to Bob") and tight
/// inline contexts. For standalone balance displays prefer
/// `BalanceText(atoms:)`.
func formatBalance(_ atoms: UInt64) -> String {
    // Money-style L$ — max 2 decimals (the exact value is shown as AXC).
    formatLdollarShort(atoms: atoms, dv: UInt32(DigitVersionState.current))
}

/// AXC display. Single-source: routes through the SDK FFI to
/// `axiom_denomination`. 1 AXC = 10^10 atoms (YP §6.1, invariant).
func formatAxcOnly(_ atoms: UInt64) -> String {
    formatAxc(atoms: atoms)
}

/// `atoms per L$` at the current digit_version. Used ONLY by the
/// SendView amount parser ("user typed N L$ → N * lDollarAtoms
/// atoms"). Parsing isn't covered by the Rust formatters; this
/// stays as the Swift-side utility.
func lDollarAtoms() -> UInt64 {
    let dv = Int(DigitVersionState.current)
    return pow10u(max(0, 10 - dv))
}

/// Ark-mode L$ display. YP §22 (line 4366) specifies the `⟠ `
/// prefix (U+27E0 LOZENGE DIVIDED BY HORIZONTAL RULE) for
/// Ark-sourced units. No protocol meaning — purely a visual cue.
func formatBalanceArk(_ atoms: UInt64) -> String {
    "⟠ " + formatBalance(atoms)
}

/// Ark-mode AXC display. Same Ark prefix rationale as
/// `formatBalanceArk`.
func formatAxcOnlyArk(_ atoms: UInt64) -> String {
    "⟠ " + formatAxcOnly(atoms)
}

/// Alias kept for call-sites using the L$-only name.
func formatLDollarOnly(_ atoms: UInt64) -> String { formatBalance(atoms) }

// =================================================================
// BalanceText — two-line balance display.
//
// Use anywhere a payment-anchoring amount is shown standalone
// (Overview balance, Wallets list, sidebar pair rows, transaction
// amounts, bundle detail header). Top line: L$ (operator-display
// unit per digit_version). Bottom line: AXC (protocol unit). Both
// visible at once is the "wrong payment" safety check the user
// asked for.
//
// For prose strings ("Sign and send X to Y") use `formatBalance`
// inline — those keep L$ only and rely on a nearby BalanceText for
// the AXC cross-reference.
// =================================================================
struct BalanceText: View {
    let atoms: UInt64

    var primaryFont: Font = .system(size: 13, weight: .medium, design: .monospaced)
    var secondaryFont: Font = .system(size: 10, design: .monospaced)
    var alignment: HorizontalAlignment = .leading
    var primaryColor: Color = DesignTokens.textPrimary
    var secondaryColor: Color = DesignTokens.textTertiary
    /// When `true`, BOTH lines (L$ and AXC) get the Ark `⟠ `
    /// prefix per YP §22, so every unit displayed under an Ark
    /// wallet visually marks its place. The atom counts are
    /// protocol-equivalent — the glyph is the visual safety cue.
    var ark: Bool = false

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(ark ? formatBalanceArk(atoms) : formatBalance(atoms))
                .font(primaryFont)
                .foregroundStyle(primaryColor)
            Text(ark ? formatAxcOnlyArk(atoms) : formatAxcOnly(atoms))
                .font(secondaryFont)
                .foregroundStyle(secondaryColor)
        }
    }
}
