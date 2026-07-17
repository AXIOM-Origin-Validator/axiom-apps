import SwiftUI
import AppKit
import AxiomSdk

/// Forces foreground activation when launched via `swift run` (no
/// .app bundle). Without this, macOS treats the binary as a
/// background/accessory process and the window can't take keyboard
/// focus — clicks on text fields look ignored. The proper fix is a
/// real .app bundle with Info.plist; this delegate is the
/// development shim.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture stdout/stderr (Rust SDK + NSLog) to the on-disk log + the
        // in-app ring buffer BEFORE anything else runs — a Finder-launched
        // .app would otherwise discard every SDK diagnostic to /dev/null.
        LogStore.shared.start()
        #if DEBUG
        // Re-apply persisted fault-injection switches to the process env
        // BEFORE the SDK sets up — a packaged dev .app then behaves like a
        // shell that exported the chaos vars. No-op when nothing is armed.
        // DEBUG-only: absent from the release build (matches the Rust
        // `chaos` feature being off there).
        FaultInjection.applyPersistedAtLaunch()
        #endif
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Observable holder for the SDK-setup result. Used to be a `static var`
/// on AppDelegate, but SwiftUI doesn't observe `static var` mutations,
/// so the SdkSetupErrorView never rendered — the wallet would silently
/// fall through to onboarding and every broadcast would explode with
/// `SdkNotInitialized`. Now an ObservableObject so the view re-renders
/// when setup completes (success or failure).
@MainActor
final class SdkBootstrap: ObservableObject {
    enum State {
        case pending
        case ready
        case failed(String)
    }
    @Published var state: State = .pending
    /// `true` when the launch seed-fetch couldn't reach axiom-dist and
    /// the wallet dropped to the bundled `.default` floor. Non-fatal —
    /// drives a dismissible notice, never blocks `state`.
    @Published var seedFetchDegraded: Bool = false

    /// Animated 0.0→1.0 progress hint for the JIT-warmup screen. The
    /// underlying Cranelift compile has no natural sub-step progress
    /// to report, so the bar advances on a wall-clock timer toward an
    /// ~8s budget; if the real compile finishes faster we snap to 1.0,
    /// if slower we hold near the end until `sdkIsJitWarm` flips.
    @Published var jitWarmupProgress: Double = 0.0
    @Published var jitWarmDone: Bool = false

    func run() {
        // Background task — keeps the main thread off the FS, ELF
        // load, and the network roundtrip the seed fetcher makes.
        // Task.detached (not DispatchQueue) so we can `await` the
        // async SeedFetcher without trampolining through callbacks.
        Task.detached(priority: .userInitiated) { [weak self] in
            let dir = defaultAppDir()
            exportBundledElfPath()

            // Remote-first: fetch validators.list + nabla-nodes.list
            // from axiom-dist when (a) we don't have local copies, or
            // (b) the remote SEEDS_VERSION is newer than our cached
            // one. Silent on network failure — falls through to the
            // bundled .default below.
            let seedsOk = await SeedFetcher.fetchSeedListsIfStale(appDir: dir)

            // Bundled emergency fallback for anything the fetch
            // couldn't fill (offline-on-first-launch). Tiny (3 lines
            // per file) so users still have a chance of bootstrapping
            // without a network; discovery + a later manual edit fill
            // in the rest.
            seedHintFilesIfMissing(appDir: dir)

            let result: Result<Void, Error> = Result {
                try sdkSetup(appDir: dir)
            }
            await MainActor.run {
                guard let self else { return }
                self.seedFetchDegraded = !seedsOk
                switch result {
                case .success:
                    self.state = .ready
                    self.startJitWarmup()
                case .failure(let e):
                    self.state = .failed(e.localizedDescription)
                }
            }
        }
    }

    /// Kick off the Cranelift JIT warm-up on a background thread. The
    /// 8s `AvmInterpreter::new` cost used to be paid lazily on the
    /// user's first Send (visible as an unexplained spinner mid-flow);
    /// running it eagerly here means the cost lands during the
    /// post-login screen the user is already looking at, and Send is
    /// instant once it's done. `userInitiated` QoS so the system
    /// schedules it ahead of background work but behind UI rendering.
    func startJitWarmup() {
        guard !jitWarmDone else { return }

        // Wall-clock progress hint. The real compile doesn't surface
        // sub-step progress, so we run a 100-tick ramp over an ~8s
        // budget and let `sdkIsJitWarm` snap us to 1.0 when it
        // actually finishes. If the compile is slower, we hold at 0.95
        // until done — the bar never lies about being complete.
        let warmupBudgetSeconds: Double = 8.0
        let tickInterval: Double = 0.08  // 12.5 Hz — smooth enough, cheap
        let totalTicks = Int(warmupBudgetSeconds / tickInterval)
        Task { @MainActor [weak self] in
            for tick in 0..<totalTicks {
                try? await Task.sleep(nanoseconds: UInt64(tickInterval * 1_000_000_000))
                guard let self else { return }
                if self.jitWarmDone { return }
                // Cap the wall-clock estimate at 0.95 — the last 5%
                // is reserved for "actually done" to avoid the bar
                // hitting 100% before the compile finishes.
                self.jitWarmupProgress = min(0.95, Double(tick + 1) / Double(totalTicks))
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let r: Result<Void, Error> = Result { try sdkWarmJit() }
            await MainActor.run {
                guard let self else { return }
                switch r {
                case .success:
                    self.jitWarmupProgress = 1.0
                    self.jitWarmDone = true
                case .failure(let e):
                    // Non-fatal — Send still works, just pays the 8s
                    // lag on first invocation as it used to.
                    NSLog("sdkWarmJit failed (non-fatal): \(e.localizedDescription)")
                    self.jitWarmupProgress = 1.0
                    self.jitWarmDone = true
                }
            }
        }
    }
}

/// Locate a resource shipped with the AxiomWallet target. Both layouts
/// must work:
///
///   1. **Packaged `.app`**: the DMG script flattens SwiftPM's
///      resource sub-bundle's contents directly into
///      `Contents/Resources/`. `Bundle.main.url(forResource:…)` finds
///      them there. Calling `Bundle.module` in this layout
///      `fatalError`s — the SwiftPM accessor expects a sibling
///      `<Target>_<Target>.bundle/` wrapper, which codesign forbids.
///
///   2. **SwiftPM dev (`swift run`)**: resources live in
///      `<binary-dir>/AxiomWallet_AxiomWallet.bundle/`. `Bundle.main`
///      sees the bare executable and returns nil; `Bundle.module`
///      points at the resource sub-bundle and finds them.
///
/// We dispatch on whether `Bundle.main.bundleURL` ends in `.app`. This
/// avoids ever touching `Bundle.module` in the packaged case.
func bundledResource(_ name: String, withExtension ext: String) -> URL? {
    if Bundle.main.bundleURL.pathExtension == "app" {
        return Bundle.main.url(forResource: name, withExtension: ext)
    }
    return Bundle.module.url(forResource: name, withExtension: ext)
}

/// Tell the SDK where the bundled Core ELF lives.
///
/// `axiom_sdk::setup()` searches a list of paths for the Core ELF used
/// by CL1 execution-proof generation. For dev (`swift run`) it finds
/// the ELF under `~/axiom/src/core/avm-guest/target/`. For the packaged
/// `.app`, no such path exists — the ELF needs to ride along inside
/// `Contents/Resources/`. We expose that location via the SDK's
/// highest-priority env-var override (`AXIOM_CORE_ELF`), set before
/// `sdkSetup()` runs.
///
/// If the bundled ELF isn't present (e.g. running from `swift run`),
/// we don't set the env var and the SDK falls through to its dev
/// search paths.
func exportBundledElfPath() {
    // MUST match the filename release-dmg.sh stages into Contents/Resources/
    // (axiom-core.elf). Drift here = packaged .app can't find its ELF, falls
    // back to dev source-tree paths (present on a dev box, absent on a
    // client) → "CL1: Core ELF not found" on every end-user machine.
    if let url = bundledResource("axiom-core", withExtension: "elf") {
        setenv("AXIOM_CORE_ELF", url.path, 1)
    }
}

/// On first launch (or after a wipe that left only the SDK's
/// header-comment stubs), copy bundled defaults from the app bundle
/// into `appDir` so `setup()` doesn't error out on empty hint files.
///
/// We seed when EITHER:
///   - the target file is absent, OR
///   - the target file exists but contains zero data lines (only
///     comments / blank lines, matching the `App::init` stub shape).
///
/// We do NOT seed a file that already has user data — user
/// customisations always win.
///
/// `axiom.conf` is special: its maildir line is per-install and gets
/// stamped at seed time. The smtp_host / pop3_host lines below stay
/// as bundled (they're env defaults that AxiomKiddo picks up).
func seedHintFilesIfMissing(appDir: String) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: appDir, withIntermediateDirectories: true)

    let seeds: [(bundleName: String, ext: String, target: String, rewriteMaildir: Bool)] = [
        ("validators.list", "default", "validators.list", false),
        ("nabla-nodes.list", "default", "nabla-nodes.list", false),
        ("axiom.conf", "default", "axiom.conf", true),
    ]

    for seed in seeds {
        let dest = "\(appDir)/\(seed.target)"
        if !seedFileNeedsReplacement(at: dest, fileName: seed.target) { continue }
        guard let url = bundledResource(seed.bundleName, withExtension: seed.ext),
              var contents = try? String(contentsOf: url, encoding: .utf8) else {
            continue
        }
        if seed.rewriteMaildir {
            // Prepend a maildir line tied to this install's app dir.
            contents = "maildir = \(appDir)/maildir\n" + contents
        }
        try? contents.write(toFile: dest, atomically: true, encoding: .utf8)
        NSLog("%@", "[seedHintFiles] wrote \(seed.target) from bundled .default "
            + "(file was missing or in a stale format for the current SDK)")
    }
}

/// Should `seedHintFilesIfMissing` overwrite this local file with the
/// bundled `.default`?
///
/// True when:
///   - The file is missing or stub-only (`fileHasUsableContent` false), OR
///   - The file is a validators.list / nabla-nodes.list whose body
///     does NOT parse as the SDK's current column count (e.g. an
///     upgraded SDK now expects 6-col validators.list but the
///     installed file is the older 3-col format from a prior install).
///
/// Without this check, an in-place upgrade where the SDK's seed
/// parser tightened would brick `sdk_setup()` because the local file
/// would still have content (so the "missing" branch wouldn't fire)
/// but the parser would reject it. axiom.conf has no strict column
/// schema — skip the format check for it.
func seedFileNeedsReplacement(at path: String, fileName: String) -> Bool {
    if !fileHasUsableContent(at: path) { return true }
    if fileName == "validators.list" || fileName == "nabla-nodes.list" {
        if let body = try? String(contentsOfFile: path, encoding: .utf8) {
            if !SeedFetcher.bodyParsesAsSeedFormat(body, fileName: fileName) {
                return true
            }
        }
    }
    return false
}

/// True if the file exists AND has at least one line that isn't blank
/// or a `#` comment. Used by `seedHintFilesIfMissing` (bundled-default
/// fallback) and `SeedFetcher.fetchSeedListsIfMissing` (remote-first
/// fetch) to distinguish "user has filled it in" from "SDK wrote a
/// header-only stub" or "file doesn't exist yet".
func fileHasUsableContent(at path: String) -> Bool {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        return false
    }
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if !line.isEmpty && !line.hasPrefix("#") {
            return true
        }
    }
    return false
}

/// Canonical app directory — `~/Library/Application Support/Axiom`.
/// Holds `axiom.conf`, `validators.list`, `nabla-nodes.list`, and the
/// `wallets/` subtree. Edit the two list files to point the wallet at
/// your AXIOM env (loopback vs. linux-box vs. mainnet bootstrap).
func defaultAppDir() -> String {
    let fm = FileManager.default
    if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        return appSupport.appendingPathComponent("Axiom").path
    }
    return NSHomeDirectory() + "/Library/Application Support/Axiom"
}

@main
struct AxiomWalletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var session = AppSession()
    @StateObject private var sdk = SdkBootstrap()
    /// App-scoped owner of an in-flight background send — outlives the
    /// SendView/SignModal so the witness round keeps running after the
    /// user returns to the main screen.
    @StateObject private var sendCoordinator = SendCoordinator()
    /// App-scoped owner of an in-flight background redeem — outlives
    /// the BundleDetailView/RedeemConfirmSheet so the witness round
    /// keeps running after the user dismisses the sheet. Without
    /// this, sheet close kills the redeem mid-flight; verify_cheque
    /// has already registered a Nabla claim at that point, so the
    /// next retry hits Nabla's REDEEMED gate and the SDK destructively
    /// marks the local cheque redeemed without ever crediting balance
    /// (redeem.rs:344). See RedeemCoordinator.swift's header for the
    /// full failure-mode write-up.
    @StateObject private var redeemCoordinator = RedeemCoordinator()
    /// App-scoped owner of an in-flight background genesis claim —
    /// outlives the GenesisClaimSheet so the 5-stage claim keeps running
    /// after the sheet dismisses. Pre-fix the claim ran in the sheet's
    /// `Task.detached`, which both beachballed the UI (MainActor
    /// re-pinning) and died on sheet close. Mirrors RedeemCoordinator;
    /// see ClaimCoordinator.swift's header for the full rationale.
    @StateObject private var claimCoordinator = ClaimCoordinator()
    /// App-scoped observer of client/server SDK protocol-version skew.
    /// Refreshed by each broadcast site on the success path; drives
    /// the "Update Required" alert + persistent banner and the Settings
    /// "Update available" chip.
    @StateObject private var versionSkew = VersionSkewWatcher()
    /// App-scoped release-feed update checker. Reads axiom-dist's
    /// releases.json and compares the published build's CoreID against
    /// this build's canonical CoreID: same CoreID → optional update
    /// (Settings chip), different CoreID → mandatory (blocking alert in
    /// MainAppView). Checked once on launch + on demand from Settings.
    @StateObject private var releaseUpdate = ReleaseUpdateWatcher(product: .axiomwallet)
    /// Tracks the Console's suggested L$ digit_version (from worldline.json
    /// via the release check) and drives the per-transaction reminder.
    @StateObject private var digitVersion = DigitVersionWatcher()
    /// App-scoped contacts store — ONE instance shared across
    /// ContactsView (read+write), SendView (read for the recipient
    /// picker), and ReceiveView (read for sender-name resolution).
    /// Previously each view owned its own @StateObject, so adding
    /// a contact in ContactsView never showed up in Send/Receive
    /// (their stale in-memory caches were loaded once at first
    /// appear and never refreshed). One instance fixes both
    /// observed bugs (Send's empty contact picker + perceived
    /// "Add doesn't save").
    @StateObject private var contactsStore = ContactsStore()

    /// Receiver-side scar-consent retention (YPX-001 §1.5.1). App-scoped
    /// for the same reason as ContactsStore: `recvScarConsents()` is
    /// consume-once, so whichever view drains the maildir must hand the
    /// notifications to ONE shared store or they vanish on tab switch.
    @StateObject private var scarConsentStore = ScarConsentStore()

    #if DEBUG
    /// Tester fault-injection switches (dev builds only). App-scoped so the
    /// Dev Tools launch card, the always-on active-faults banner, and the
    /// standalone panel window all read one instance.
    @StateObject private var faultInjection = FaultInjectionModel()
    #endif

    /// One-time first-launch developer-demonstration notice. Once the
    /// user acknowledges `FirstLaunchNoticeView`, this flips true and
    /// the sheet never shows again. Versioned key — bump the suffix
    /// if the notice text materially changes and should re-show.
    @AppStorage("axiom.firstLaunchNoticeAcknowledged.v1")
    private var noticeAcknowledged: Bool = false
    @State private var showFirstLaunchNotice: Bool = false

    var body: some Scene {
        // Fresh scene id (2026-06-11): the sidebar shell ships with a
        // much larger window than the old fixed 650×760 layout, but
        // macOS state restoration re-applied the OLD saved frame to
        // the new content (same bundle id + same scene identity) —
        // the >=920pt content got clipped against a 650pt window and
        // the top of every pane was unreachable. A new id discards
        // the stale saved frame; first launch opens centered at the
        // defaultSize below.
        WindowGroup(id: "axiom-main-sidebar") {
            Group {
                switch sdk.state {
                case .pending:
                    SdkBootstrapView()
                case .failed(let msg):
                    SdkSetupErrorView(message: msg)
                case .ready:
                    RootView()
                        .environmentObject(session)
                        .environmentObject(sdk)
                        .environmentObject(sendCoordinator)
                        .environmentObject(redeemCoordinator)
                        .environmentObject(claimCoordinator)
                        .environmentObject(versionSkew)
                        .environmentObject(releaseUpdate)
                        .environmentObject(digitVersion)
                        .environmentObject(contactsStore)
                        .environmentObject(scarConsentStore)
                        #if DEBUG
                        .environmentObject(faultInjection)
                        #endif
                        // One-shot release-feed check on launch. Static
                        // file fetch; the watcher no-ops on failure.
                        .task { await releaseUpdate.check() }
                        // Mirror this Mac's own wallet addresses into the
                        // address book. Driven off `pairs` (rather than a
                        // one-shot at launch) so it also covers unlocking a
                        // second set, adding a pair, and renaming one — every
                        // path that mutates the list routes through here.
                        // Additive + idempotent, so re-firing is free.
                        .onReceive(session.$pairs) { pairs in
                            contactsStore.syncOwnWallets(ownWalletEntries(from: pairs))
                        }
                        // Apply the Console-suggested digit_version when the
                        // check surfaces one (worldline.json). Adopting it
                        // arms the per-transaction reminder if it changed.
                        .onReceive(releaseUpdate.$suggestedDigitVersion) { dv in
                            if let dv = dv {
                                digitVersion.apply(
                                    suggested: dv,
                                    started: releaseUpdate.digitVersionStarted ?? ""
                                )
                            }
                            // Second warning channel: the dv-change notice on
                            // the next 3 app starts. Only AFTER login — a sheet
                            // shown at launch overlaps the bio-auth prompt. The
                            // tick is once-per-launch and only fires when a
                            // change is armed, so a late feed-apply still pops
                            // (and MainAppView.onAppear covers the persisted
                            // case where the change was detected last launch).
                            if session.isUnlocked {
                                digitVersion.tickLaunchWarning()
                            }
                        }
                        // First-launch developer-demonstration notice.
                        // Shown over RootView the first time the wallet
                        // reaches the ready state; dismissed once.
                        .sheet(isPresented: $showFirstLaunchNotice) {
                            FirstLaunchNoticeView {
                                noticeAcknowledged = true
                                showFirstLaunchNotice = false
                            }
                        }
                        .onAppear {
                            if !noticeAcknowledged {
                                showFirstLaunchNotice = true
                            }
                        }
                }
            }
            // Non-blocking JIT-warmup banner at the bottom of the
            // window while Cranelift compiles the AVM ELF. Disappears
            // once `jitWarmDone` flips. The user can navigate, log in,
            // and even start a Send while this runs; warm_jit just
            // races to be done before Send hits CL1. If it loses the
            // race, Send pays the 8s lazy compile cost once — same
            // as pre-pre-warm behaviour.
            .overlay(alignment: .bottom) {
                VStack(spacing: 6) {
                    // Transient "checking for updates" chip — visible only
                    // while the launch (or manual) release check runs, then
                    // auto-hides. Results surface in Settings → Software
                    // updates (optional) or a blocking alert (mandatory).
                    if releaseUpdate.checking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking for updates…").font(.caption)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .transition(.opacity)
                    }
                    if case .ready = sdk.state, !sdk.jitWarmDone {
                        JitWarmupBar(progress: sdk.jitWarmupProgress)
                            .transition(.opacity)
                    }
                }
                .padding(.bottom, 8)
            }
            .animation(.easeInOut(duration: 0.2), value: sdk.jitWarmDone)
            .animation(.easeInOut(duration: 0.2), value: releaseUpdate.checking)
            .onAppear { sdk.run() }
            // Resizable window with a floor (2026-06-11 shell
                // restructure — sidebar + detail layout). The floor
                // keeps every fixed-width panel (modals 480-540pt,
                // tables ~600pt of columns) usable next to the
                // 200-280pt sidebar; above the floor the detail
                // column reflows.
                .frame(minWidth: 860, minHeight: 600)
                // The DesignTokens palette is light-mode only (white
                // backgrounds, near-black text). Without this, the
                // system's dark mode would resolve every default
                // `.foregroundStyle` to white and render text on the
                // hardcoded white backgrounds — invisible. Dark mode
                // was explicitly descoped from the 2026-06 UI overhaul.
                .preferredColorScheme(.light)
        }
        // Standard window chrome (the old fixed-layout shell used
        // .hiddenTitleBar and managed its own top spacing; under the
        // NavigationSplitView shell that made content underlap the
        // invisible title bar — nothing at the top was visible).
        // The default style gives the unified toolbar + full-height
        // sidebar natively.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1040, height: 720)
        .defaultPosition(.center)

        // Settings lives in its own native Preferences window
        // (Cmd+, opens it; profile chip → Settings calls the same
        // `openSettings` environment action). Decouples the Settings
        // pane's wider content from the 650pt main window — Settings
        // gets 880pt with its inner sidebar intact, the main wallet
        // stays compact.
        Settings {
            // CRITICAL: a SwiftUI `Settings` scene is a SEPARATE window
            // with its OWN environment — the `.environmentObject(...)`
            // chain attached to the WindowGroup above does NOT
            // propagate here. Every @EnvironmentObject SettingsView
            // (or any view it hosts) reads must be re-injected here,
            // or SwiftUI fatals at first access with
            // "No ObservableObject of type … found".
            //
            // Burned by this on 2026-05-27 — AboutSection's
            // `wireProtocolRow` reads `@EnvironmentObject versionSkew`,
            // the Settings scene wasn't injecting it, and clicking
            // Settings → About crashed the app with an
            // EnvironmentObject.error() assert.
            //
            // Keep this list in sync with the WindowGroup branch
            // above — anything injected there that any code path
            // reachable from SettingsView reads, MUST also be here.
            SettingsView()
                .environmentObject(session)
                .environmentObject(sdk)
                .environmentObject(sendCoordinator)
                .environmentObject(versionSkew)
                .environmentObject(releaseUpdate)
                .environmentObject(digitVersion)
                .environmentObject(contactsStore)
                // Dev Tools (hosted in Settings) reads the fault-injection
                // model in DEBUG builds — re-inject per the note above or
                // Dev Tools fatals. Absent from release (gated below).
                #if DEBUG
                .environmentObject(faultInjection)
                #endif
                .frame(width: 880, height: 620)
                .preferredColorScheme(.light)
        }
        .windowResizability(.contentSize)

        #if DEBUG
        // Standalone fault-injection window (dev/tester ONLY — compiled out
        // of the release build). Launched from Dev Tools via openWindow(id:);
        // co-exists with the main wallet window so faults can be armed/cleared
        // WHILE the wallet is driven. Shares the one FaultInjectionModel the
        // main window + banner read, so a toggle here hits the next SDK call.
        Window("Fault Injection", id: faultInjectionWindowID) {
            FaultInjectionPanel()
                .environmentObject(faultInjection)
                .preferredColorScheme(.light)
        }
        .windowResizability(.contentMinSize)
        #endif
    }
}

/// Top-level app session state. Holds every pair the user has
/// unlocked this session, plus the active-tab + active-mode
/// selection. Empty `pairs` array means locked.
final class AppSession: ObservableObject {
    /// Unlocked pairs. Empty ⇒ locked. Mutating this between empty and
    /// non-empty drives the idle-lock watcher on/off — so it covers
    /// every unlock path (login, onboarding) and every lock path.
    @Published var pairs: [LoadedPair] = [] {
        didSet {
            if pairs.isEmpty {
                stopIdleWatch()
            } else if oldValue.isEmpty {
                startIdleWatch()
            }
            refreshHibernation()   // seed the gate when a (possibly hibernating) wallet loads
        }
    }
    @Published var activePairIndex: Int = 0 { didSet { refreshHibernation() } }
    @Published var activeMode: WalletMode = .normal { didSet { refreshHibernation() } }
    /// Which main-pane tab is showing. Lifted out of MainAppView's
    /// local @State so a background-send hand-off can route the user
    /// back to the Overview after the SignModal dismisses.
    @Published var selectedNav: NavItem = .overview

    var isUnlocked: Bool { !pairs.isEmpty }

    var activePair: LoadedPair? {
        guard !pairs.isEmpty, activePairIndex < pairs.count else { return nil }
        return pairs[activePairIndex]
    }

    /// The wallet for the currently-active (tab, mode) selection.
    /// `nil` when locked or when the active pair is missing the
    /// requested mode (e.g. imported pair without an Ark companion).
    var activeWallet: AxiomWallet? {
        guard let pair = activePair else { return nil }
        switch activeMode {
        case .normal: return pair.normal
        case .ark: return pair.ark
        }
    }

    func lock() {
        pairs = []   // didSet tears down the idle watcher
        activePairIndex = 0
        activeMode = .normal
    }

    // ── YPX-020 hibernation (BINARY model, AXIOM_YPX-020_HAL.md §7) ──
    // After a HAL re-anchor the active wallet is HIBERNATING. This is a
    // BINARY flag, NOT a clock: `hibernation_until() != 0` means
    // hibernating, full stop. Core hard-rejects every tx while it's set
    // except `hal_complete` (which clears it) and a restart
    // `hal_reanchor`. It does NOT auto-clear on a timer — the wallet
    // stays frozen until the user finishes recovery (hal_complete
    // commits → hibernation_until → 0). So NEVER gate on a time
    // comparison; gate on the flag.

    /// The active wallet's hibernation flag value (0 = not hibernating).
    /// The numeric value is reference-only in the binary model; only
    /// zero vs non-zero is meaningful.
    func hibernationUntil() -> UInt64 {
        activeWallet?.hibernationUntil() ?? 0
    }

    /// True while the active wallet is hibernating — binary flag, cleared
    /// only by a committed `hal_complete` (or restart `hal_reanchor`),
    /// never by a clock.
    ///
    /// STORED + `@Published`, NOT computed. Entering/leaving hibernation must
    /// publish an `objectWillChange` so every `.disabled(session.isHibernating)`
    /// gate re-evaluates. As a computed property it read the FFI fresh on each
    /// render but emitted no change, so Send/Redeem only greyed out when some
    /// UNRELATED state happened to re-render the view — i.e. usually never right
    /// after a HAL re-anchor. `refreshHibernation()` is the single writer; it
    /// runs on wallet load/switch (the didSets above) and after every HAL commit.
    @Published private(set) var isHibernating: Bool = false

    /// Re-read the active wallet's binary hibernation flag and publish it if it
    /// changed. Cheap (one cached FFI read). Main-thread only — mutates
    /// `@Published` state.
    func refreshHibernation() {
        let h = (activeWallet?.hibernationUntil() ?? 0) != 0
        if isHibernating != h { isHibernating = h }
    }

    /// YPX-022 — true while this wallet has a committed recall that hasn't been
    /// FINISHED (the recall cheque redeemed via `recallComplete`, which clears
    /// hibernation). Read alongside `isHibernating` to flip the hibernation
    /// banner into its recall framing ("Finish recall" → `recallComplete`)
    /// vs the HAL framing ("Finish recovery" → `halComplete`).
    ///
    /// MUST NOT use the record's `completed` flag: that flips true at COMMIT
    /// (the FFI sets `completed = recall_cheque_id.is_some()`, i.e. the cheque
    /// was ISSUED), not at finish. Keying on `!completed` made the banner drop
    /// out of recall framing the instant the recall committed, so "Finish
    /// recall" (→ recallComplete) became unreachable and the user was stuck at
    /// "Recall committed". Key on the wallet still hibernating with a recall
    /// record instead — that IS the committed-but-not-finished window; it
    /// clears when `recallComplete` un-hibernates the wallet.
    /// `recall_records()` is the KI#15 try_lock + cache read.
    var hasPendingRecall: Bool {
        isHibernating && !(activeWallet?.recallRecords() ?? []).isEmpty
    }

    /// ESTIMATE ONLY (UX, never a gate): seconds until the convergence
    /// window elapses. `hibernation_until` is the Core-stamped deadline
    /// already projected onto unix-seconds (`epoch + HIBERNATION_WINDOW *
    /// TICK_INTERVAL_SECS`, a conservative ≤5 s/tick UPPER bound — real
    /// ticks may run faster, so convergence can finish sooner). Returns 0
    /// when not hibernating or the estimate has elapsed. This does NOT
    /// clear the lock — only `hal_complete` does (see `isHibernating`);
    /// it just tells the user roughly when to attempt Finish recovery.
    func hibernationConvergenceEstimateSecs() -> UInt64 {
        let until = hibernationUntil()
        if until == 0 { return 0 }
        let now = UInt64(max(0, Date().timeIntervalSince1970))
        return until > now ? until - now : 0
    }

    // ── Idle auto-lock ─────────────────────────────────────────────
    // While unlocked, a local event monitor rearms a one-shot timer on
    // every mouse/keyboard event. If the timer ever fires (no activity
    // for `idleLockSeconds`), the session locks back to the login
    // screen. Off by default; configured in Settings → Security.

    private var idleTimer: Timer?
    private var activityMonitor: Any?

    /// Idle-lock timeout in seconds; `0` = off. Persisted in
    /// UserDefaults — the Settings picker and this setter are the only
    /// writers. Setting it rearms the timer immediately.
    var idleLockSeconds: Int {
        get { UserDefaults.standard.integer(forKey: "axiom.idleLockSeconds") }
        set {
            UserDefaults.standard.set(newValue, forKey: "axiom.idleLockSeconds")
            rearmIdleTimer()
        }
    }

    private func startIdleWatch() {
        guard activityMonitor == nil else { return }
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown,
                       .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.rearmIdleTimer()
            return event
        }
        rearmIdleTimer()
    }

    private func stopIdleWatch() {
        idleTimer?.invalidate()
        idleTimer = nil
        if let monitor = activityMonitor {
            NSEvent.removeMonitor(monitor)
            activityMonitor = nil
        }
    }

    private func rearmIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
        let seconds = idleLockSeconds
        guard seconds > 0, isUnlocked else { return }
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(seconds), repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.lock() }
        }
    }
}

/// One unlocked pair held in the session. Both wallets are open
/// (lock acquired, state hydrated). The Ark companion may be `nil`
/// for partial pairs (e.g. imported a Normal-only wallet via
/// "Load wallet from backup file" without generating an Ark
/// companion afterward).
struct LoadedPair {
    let name: String
    let normal: AxiomWallet
    let ark: AxiomWallet?
}

/// Flatten unlocked pairs into the address-book rows for this Mac's OWN wallets.
///
/// This resolves the addresses; `ownWalletRows` (ContactsStore.swift) owns the
/// RULE for what shape they take — one row for a single-keypair pair, two for a
/// legacy one. Split that way so the rule is unit-testable without the SDK, and
/// so it exists in exactly one place.
///
/// A wallet whose `address()` throws is skipped rather than added under a
/// placeholder: a wrong address in the address book is worse than a missing one,
/// because the user would paste it into a send.
func ownWalletEntries(from pairs: [LoadedPair]) -> [OwnWalletEntry] {
    pairs.flatMap { pair in
        ownWalletRows(
            pairName: pair.name,
            normalAddress: try? pair.normal.address(),
            arkAddress: pair.ark.flatMap { try? $0.address() }
        )
    }
}

/// Routes between three states:
///   - no wallets on disk → onboarding
///   - wallets exist, none unlocked → login
///   - wallet unlocked → main app (placeholder for now)
struct RootView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        if session.isUnlocked {
            MainAppView()
        } else if walletsDirIsEmpty() {
            OnboardingView()
        } else {
            LoginView()
        }
    }
}

/// Canonical wallets directory — `~/Library/Application Support/Axiom/wallets`.
/// Used by Login (find existing), Onboarding (create new), and the
/// routing check for empty-state detection.
func defaultWalletDir() -> String {
    let fm = FileManager.default
    if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        return appSupport.appendingPathComponent("Axiom/wallets").path
    }
    return NSHomeDirectory() + "/Library/Application Support/Axiom/wallets"
}

/// Pure on-disk check — does the wallets parent directory contain
/// any wallet.axiom file? Triggers onboarding routing on a fresh
/// install. No network calls.
func walletsDirIsEmpty() -> Bool {
    let parent = defaultWalletDir()
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: parent) else {
        return true
    }
    return !entries.contains { name in
        fm.fileExists(atPath: "\(parent)/\(name)/wallet.axiom")
    }
}

// =================================================================
// SdkSetupErrorView — startup-blocking error UI.
//
// Shown instead of RootView when `sdkSetup()` failed at app launch.
// Without setup, every broadcast op would error mid-flight with a
// misleading "missing execution proof" Lambda rejection; better to
// refuse to open the wallet at all and tell the user exactly what's
// wrong (typically: Core ELF not found at any expected path).
// =================================================================

/// Brief "starting up" screen shown for the few hundred ms it takes
/// `sdkSetup` to load the Core ELF + parse hint files. Without this,
/// the window flashes empty before the first real view renders.
struct SdkBootstrapView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading AXIOM…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Thin non-blocking strip at the bottom of the window during the
/// post-setup JIT warm-up. Lets the user keep using the wallet (the
/// warmup just races first-Send) but tells them why a small amount of
/// CPU is being burned in the background. Vanishes when warmup
/// completes — typical wall-clock is ~8s on M-series.
struct JitWarmupBar: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 10) {
            Text("Preparing wallet…")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }
}

struct SdkSetupErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text("AXIOM SDK couldn't start")
                .font(.title2.weight(.semibold))
            Text("The wallet refuses to open without a functional SDK runtime — broadcast operations would fail mid-flight otherwise.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 60)
            ScrollView {
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
            }
            .frame(maxHeight: 220)
            .padding(.horizontal, 40)
            HStack(spacing: 8) {
                Button("Copy details") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(message, forType: .string)
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut(.return)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }
}
