import SwiftUI
import AppKit
import Combine

// =================================================================
// AxiomKiddoApp — menu-bar app entry point.
//
// LSUIElement-equivalent: we set NSApplication's activation policy to
// .accessory on launch so the app shows up as a menu-bar item only
// (no Dock icon, no main menu). SwiftUI's MenuBarExtra gives us the
// dropdown content; opening Settings activates the regular window-shaped
// detail UI.
//
// Architecture:
//   - AccountStore  (persisted JSON of KiddoAccount[])
//   - WorkerRegistry (live AccountWorker per account)
//   - AppDelegate   (sets .accessory + starts workers on launch)
//   - MenuBarExtra  (status summary + open-settings button)
//   - SettingsScene (master/detail account editor)
// =================================================================

@main
struct AxiomKiddoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Kiddo", systemImage: appDelegate.menuIcon) {
            MenuBarView(
                store: appDelegate.store,
                workers: appDelegate.workers,
                appDelegate: appDelegate
            )
        }
        .menuBarExtraStyle(.window)

        // NO `Settings { … }` or `Window { … }` scene for the
        // Settings UI. The Settings window is owned by AppDelegate
        // via an NSWindowController + NSHostingController instead.
        //
        // Why: this app is LSUIElement (.accessory activation
        // policy). That means:
        //   • There is no app menu bar — `NSApp.mainMenu` is
        //     effectively empty, so `.commands` modifiers don't
        //     install anywhere reachable from outside SwiftUI.
        //   • Cmd+, doesn't fire because there's no menu item to
        //     fire it from.
        //   • The SwiftUI `Settings { … }` scene on macOS 14+ can
        //     only be opened via SettingsLink or `@Environment(\.openSettings)`
        //     (both view-body-only); the `showSettingsWindow:`
        //     selector triggers a "Please use SettingsLink"
        //     runtime fault and does nothing visible.
        //   • A SwiftUI `Window { … }` scene is reachable in
        //     theory but its lazy-init from non-SwiftUI code
        //     requires the menu-driven path that doesn't exist
        //     in LSUIElement apps.
        //
        // The NSWindowController route gives us a single Settings
        // window UI that opens reliably from both the menu-bar
        // dropdown's "Open Settings…" button and the Wallet's
        // axiomkiddo://settings URL handler — same call site.
    }
}

// =================================================================
// AppDelegate — handles launch-state plumbing that SwiftUI scenes
// can't do on their own:
//   - Sets activation policy to `.accessory` (no Dock icon) BEFORE
//     any window appears.
//   - Starts workers for the configured accounts as soon as the
//     store is bound by the App's scene init.
// =================================================================

/// Owns the AccountStore + WorkerRegistry as singletons, because
/// `@StateObject` on the App struct is not safely accessible from
/// `App.init` (the wrapped value isn't realised yet) and MenuBarExtra
/// only constructs its body on first menu-icon click. Putting them on
/// the delegate gives a single instance that exists from
/// `applicationDidFinishLaunching` onward, observable by SwiftUI via
/// `@ObservedObject`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = AccountStore()
    let workers = WorkerRegistry()
    private var didStartWorkers = false
    /// Keeps the live worker set in step with `store.accounts`. Any
    /// mutation — user edit in Settings, `AccountStore.reconcileWalletDirs`
    /// re-pointing walletDir after a wallet reset, etc. — flows through
    /// here and `Worker.update` re-snapshots with the new paths. Without
    /// this, workers ran on the snap captured at startup forever; a
    /// wallet reset left the POP3 timer trying to land mail in a dir
    /// that no longer existed and the user had to restart Kiddo.
    private var accountsSyncCancellable: AnyCancellable?
    /// Subscriber that re-runs `WorkerRegistry.syncWith` on every
    /// `AccountStore.reconcileGeneration` tick (every 30s). Catches
    /// the filesystem-only case where an account's walletDir was
    /// deleted in AxiomWallet — no account field changes, so
    /// `$accounts` doesn't fire, but the worker is now writing to a
    /// phantom dir. `syncWith` checks `walletDir/wallet.axiom`
    /// existence per account and stops the orphan.
    private var reconcileSyncCancellable: AnyCancellable?

    nonisolated func applicationWillFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            self.registerURLHandler()
        }
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
            self.startWorkersOnce()
            // Register here too — `applicationWillFinishLaunching` is
            // not reliably forwarded to the delegate by SwiftUI's app
            // lifecycle, but `didFinishLaunching` always is (it's
            // where startWorkersOnce runs). setEventHandler just
            // replaces, so a double-register is harmless.
            self.registerURLHandler()
            // Brief launch splash. AxiomKiddo is an `.accessory`
            // (LSUIElement) app — it has no Dock icon and opens no
            // window, so launching it produces no visible feedback
            // beyond a menu-bar icon the user often doesn't notice.
            // Users repeatedly thought the app hadn't started. The
            // splash gives a clear "I'm running — I live in the menu
            // bar" signal, then auto-dismisses.
            self.showLaunchSplash()
        }
    }

    /// Owned splash window. Held so the auto-dismiss timer + the
    /// `.accessory`-policy fronting don't race a deallocation.
    private var splashWindow: NSWindow?

    /// Show the launch splash, then auto-close it after a few
    /// seconds. The window is closeable so an impatient user can
    /// dismiss it early.
    @MainActor
    private func showLaunchSplash() {
        let hosting = NSHostingController(rootView: KiddoSplashView())
        // Clear sizingOptions for the same macOS 26 layout-recursion
        // reason as the Settings window — let the window own its size.
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 340, height: 320))
        window.center()
        window.isReleasedWhenClosed = false
        splashWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // Auto-dismiss. 5s is long enough to read the one line, short
        // enough not to nag a developer who restarts Kiddo often.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.splashWindow?.close()
            self?.splashWindow = nil
        }
    }

    /// Register the classic Carbon-era `GetURL` Apple Event handler —
    /// the URL-scheme delivery path that works regardless of SwiftUI
    /// scene shape. For this MenuBarExtra-only app:
    ///   - `NSApplicationDelegate.application(_:open:)` is not invoked
    ///     (verified — it never fired);
    ///   - SwiftUI's `.onOpenURL` needs a rendered view, and
    ///     MenuBarExtra content only realizes on menu click.
    /// The GetURL Apple Event predates both and is delivered to the
    /// process regardless.
    @MainActor
    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// Apple Event `GetURL` handler. The event's direct-object
    /// parameter is the URL string. Extract it and hand off to the
    /// shared `axiomkiddo://` router.
    @objc func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        guard
            let str = event
                .paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?
                .stringValue,
            let url = URL(string: str)
        else {
            NSLog("AxiomKiddo: GetURL event carried no usable URL")
            return
        }
        handleAxiomKiddoURL(url)
    }

    /// URL-scheme handler. Registered via CFBundleURLTypes in
    /// Info.plist for `axiomkiddo://`. Routes (the URL `.host`):
    ///
    ///   `axiomkiddo://settings`
    ///     Opens Kiddo's Settings window. The AxiomWallet's pre-flight
    ///     gate uses this for "Open Kiddo Settings".
    ///
    ///   `axiomkiddo://provision?email=<e>&walletDir=<d>&label=<l>`
    ///     Auto-provision a dev/FATMAMA account for the given wallet.
    ///     The wallet fires this during onboarding so the user never
    ///     has to hand-configure Kiddo for a local dev env. See
    ///     `provisionAccount` for the create-or-no-op logic.
    ///
    /// `nonisolated` because `NSApplicationDelegate.application(_:open:)`
    /// is declared nonisolated; we hop to MainActor for the actual
    /// NSApp + store work.
    /// NSApplicationDelegate URL hook. Kept as a belt-and-suspenders
    /// path — in practice the GetURL Apple Event handler above is
    /// what fires for this MenuBarExtra-only app, but if a future
    /// macOS does route through here, the shared router makes it a
    /// no-cost duplicate (settings just refronts the same window;
    /// provision is idempotent).
    nonisolated func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleAxiomKiddoURL(url)
        }
    }

    /// Shared `axiomkiddo://` router. Both the GetURL Apple Event and
    /// the NSApplicationDelegate hook funnel here. `.host` is the
    /// route; query items carry parameters.
    nonisolated func handleAxiomKiddoURL(_ url: URL) {
        guard url.scheme == "axiomkiddo" else { return }
        let route = url.host ?? ""
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        func q(_ name: String) -> String {
            items.first { $0.name == name }?.value ?? ""
        }
        Task { @MainActor in
            switch route {
            case "settings":
                self.openSettingsWindow()
            case "provision":
                self.provisionAccount(
                    email: q("email"),
                    walletDir: q("walletDir"),
                    label: q("label")
                )
            default:
                // Unknown route — log and ignore. An unknown URL
                // must never crash the daemon.
                NSLog("AxiomKiddo: ignoring unknown axiomkiddo:// route '\(route)'")
            }
        }
    }

    /// Auto-provision a dev/FATMAMA Kiddo account for `email` +
    /// `walletDir`. Fired by the AxiomWallet's onboarding flow
    /// (`axiomkiddo://provision`) so a first-time dev user never has
    /// to hand-fill Kiddo's Settings.
    ///
    /// Idempotent: if an account already targets this wallet email
    /// (case-insensitive), we leave it untouched and just make sure
    /// its worker is running. The wallet may re-fire the provision
    /// URL (e.g. user navigates Back/Forward through onboarding) —
    /// this MUST NOT produce duplicate accounts.
    ///
    /// The account is built from `KiddoAccount.devDefault`, which
    /// derives the FATMAMA SMTP/POP3 host+ports from the SHARED
    /// `~/Library/Application Support/Axiom/axiom.conf` (the wallet
    /// writes it; Kiddo reads it — one source of truth). We only
    /// overlay the wallet-specific fields the wallet told us:
    /// `walletEmail`, `walletDir`, `label`. `kind` stays `.axiomDev`
    /// (plain SMTP/POP3, no auth) — that's the FATMAMA dev profile.
    /// A real-email wallet is deliberately NOT auto-provisioned: its
    /// SMTP/POP3 needs a password Kiddo cannot know, so the wallet
    /// only fires this route for dev-class wallets.
    ///
    /// Starting the worker IS the "bind": once the account exists and
    /// its `AccountWorker` is running, Kiddo begins watching the
    /// wallet's `outbox/` for SMTP and polling FATMAMA POP3 for the
    /// wallet's mailbox.
    private func provisionAccount(email: String, walletDir: String, label: String) {
        let email = email.trimmingCharacters(in: .whitespaces)
        let walletDir = walletDir.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty, !walletDir.isEmpty else {
            NSLog("AxiomKiddo: provision ignored — missing email or walletDir")
            return
        }

        // Idempotency — never create a second account for the same
        // wallet email.
        if let existing = store.accounts.first(where: {
            $0.walletEmail.lowercased() == email.lowercased()
        }) {
            NSLog("AxiomKiddo: provision no-op — account for \(email) already exists")
            workers.start(account: existing)  // ensure its worker is live
            return
        }

        var acct = KiddoAccount.devDefault
        acct.walletEmail = email
        acct.walletDir = walletDir
        if !label.isEmpty {
            acct.label = label
        }
        store.add(acct)
        workers.start(account: acct)
        NSLog("AxiomKiddo: auto-provisioned dev account for \(email) at \(walletDir)")
    }

    /// Owned NSWindowController for the Settings UI. Created lazily
    /// on first open, then reused. Kept on the delegate so the
    /// window survives Dispatch hops + multiple open requests
    /// without being deallocated (an NSWindowController is
    /// retain-cycle-safe by design — it owns its NSWindow which
    /// retains the controller back via `windowController`).
    private var settingsWindowController: NSWindowController?

    /// Bring the Settings window to the front. Owns the entire
    /// open path — both the menu-bar dropdown's "Open Settings…"
    /// button and the Wallet's `axiomkiddo://settings` URL
    /// handler call here.
    ///
    /// Why not SwiftUI's `Settings { … }` or `Window { … }`
    /// scenes — see the long comment in `AxiomKiddoApp.body`.
    /// Short version: LSUIElement apps have no menu bar to
    /// drive a SwiftUI scene's lazy init from outside view code,
    /// and the macOS 14+ Settings selector is gone.
    @MainActor
    fileprivate func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindowController == nil {
            settingsWindowController = makeSettingsWindowController()
        }
        guard let window = settingsWindowController?.window else {
            NSLog("AxiomKiddo: settings — window controller has no window")
            return
        }

        // Re-center on the main screen's visible frame every open.
        // Guards against the window having drifted off-screen after a
        // display reconfigure / resolution change since the last open
        // — a real "I clicked and nothing happened" cause that looks
        // identical to "the window didn't open".
        if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(
                x: vis.midX - size.width / 2,
                y: vis.midY - size.height / 2
            ))
        }

        // `.accessory`-policy apps lose window-ordering battles by
        // default. `orderFrontRegardless()` is stronger than
        // `makeKeyAndOrderFront` — it fronts the window even when the
        // app isn't formally active, which is exactly the accessory
        // case. We do both: makeKey for focus, orderFrontRegardless
        // to guarantee visibility.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }


    /// Build the NSWindow + NSHostingController that backs Settings.
    /// One window per process — we cache the controller in
    /// `settingsWindowController` and reuse it on subsequent opens.
    ///
    /// 640×620 mirrors the size SwiftUI's Settings scene picks for
    /// the existing SettingsView content. Adjustable if the panes
    /// grow; the contentSize style mask + `setContentSize` below
    /// drives sizing from the SwiftUI view's intrinsic size, so
    /// the explicit dimensions are just a "first render" anchor.
    @MainActor
    private func makeSettingsWindowController() -> NSWindowController {
        let view = SettingsView(store: store, workers: workers)
        let hosting = NSHostingController(rootView: view)
        // CRITICAL on macOS 14+/26: clear `sizingOptions`. The default
        // includes `.preferredContentSize`, which makes the hosting
        // controller push the SwiftUI view's intrinsic size up to the
        // window AND react to the window's size — a feedback loop that
        // triggers AppKit's "-layoutSubtreeIfNeeded on a view which is
        // already being laid out" recursion. On macOS 26 that
        // recursion can leave the window half-laid-out and never
        // displayed (the "I clicked Settings and nothing happened"
        // bug). With `sizingOptions = []` the window owns its size
        // outright and SwiftUI just fills the content rect — no loop.
        hosting.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AxiomKiddo Settings"
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 640, height: 620))
        window.center()
        // Allow the green-traffic-light "close" to hide rather
        // than destroy. Without this, closing the window would
        // tear down `settingsWindowController` indirectly via
        // SwiftUI lifecycle and the next open would build a
        // fresh one — losing any in-flight edits (e.g. a half-
        // typed POP3 password). `isReleasedWhenClosed = false` +
        // reusing the same controller preserves state.
        window.isReleasedWhenClosed = false
        return NSWindowController(window: window)
    }

    private func startWorkersOnce() {
        guard !didStartWorkers else { return }
        didStartWorkers = true
        workers.startAll(store.accounts)
        // Re-sync workers on every accounts mutation thereafter. The
        // dropFirst() skips the initial value (already consumed above
        // by startAll); subsequent fires are UI edits or
        // AccountStore.reconcileWalletDirs re-pointing walletDir.
        accountsSyncCancellable = store.$accounts
            .dropFirst()
            .sink { [weak workers] accounts in
                workers?.syncWith(accounts)
            }
        // Re-sweep on every reconcile tick (every 30s), even when no
        // account field changed. Catches the case where a wallet was
        // deleted in AxiomWallet but reconcile found no replacement
        // — accounts[i] didn't mutate, so $accounts wouldn't fire,
        // but the worker is now writing into a phantom maildir.
        // syncWith checks walletDir/wallet.axiom and stops orphans.
        reconcileSyncCancellable = store.$reconcileGeneration
            .dropFirst()
            .sink { [weak store, weak workers] _ in
                guard let store = store, let workers = workers else { return }
                workers.syncWith(store.accounts)
            }
    }

    var menuIcon: String {
        let s = workers.summary
        if s.hasError { return "envelope.badge" }
        if s.queue > 0 { return "envelope.arrow.triangle.branch" }
        return "envelope"
    }
}

// =================================================================
// MenuBarView — the dropdown content. Per-account status rows plus an
// "Open Settings…" button.
// =================================================================

struct MenuBarView: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var workers: WorkerRegistry
    /// Direct reference to the live AppDelegate. Required so
    /// "Open Settings…" can call `openSettingsWindow()` on the real
    /// instance — `NSApp.delegate as? AppDelegate` fails for SwiftUI
    /// `@NSApplicationDelegateAdaptor` apps (SwiftUI installs its own
    /// delegate that forwards to ours; the cast doesn't see through it).
    let appDelegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.accounts.isEmpty {
                emptyState
            } else {
                ForEach(store.accounts) { acct in
                    accountRow(acct)
                    Divider()
                }
            }
            actions
        }
        .frame(width: 320)
        .padding(.vertical, KiddoTokens.Spacing.xxs)
    }

    private var header: some View {
        let s = workers.summary
        // Same conditions as the old raw-color expression:
        // hasError → attention, queued work → busy, else running.
        let style: WorkerStatusStyle = s.hasError
            ? .attention
            : (s.queue > 0 ? .busy : .running)
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("AxiomKiddo")
                    .font(KiddoTokens.Typography.heading)
                Text("\(s.sent) sent · \(s.pulled) pulled · \(s.queue) queued")
                    .font(KiddoTokens.Typography.monoSmall)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(style.fg)
                .frame(width: KiddoTokens.Size.statusDot,
                       height: KiddoTokens.Size.statusDot)
                .accessibilityLabel(style.label)
                .help(style.label)
        }
        .padding(.horizontal, KiddoTokens.Spacing.sm)
        .padding(.vertical, KiddoTokens.Spacing.xxs)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: KiddoTokens.Spacing.xxs) {
            Text("No accounts configured.")
                .font(KiddoTokens.Typography.label)
            Text("Open Settings to add one.")
                .font(KiddoTokens.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, KiddoTokens.Spacing.sm)
        .padding(.vertical, KiddoTokens.Spacing.xs)
    }

    private func accountRow(_ acct: KiddoAccount) -> some View {
        let w = workers.worker(for: acct.id)
        let style = rowStatusStyle(w)
        return HStack(alignment: .top, spacing: KiddoTokens.Spacing.xxs) {
            Circle()
                .fill(style.fg)
                .frame(width: KiddoTokens.Size.statusDot,
                       height: KiddoTokens.Size.statusDot)
                .padding(.top, KiddoTokens.Spacing.xxs)
                .accessibilityLabel(style.label)
                .help(style.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(acct.label)
                    .font(KiddoTokens.Typography.labelStrong)
                Text(acct.walletEmail.isEmpty ? "no mailbox configured" : acct.walletEmail)
                    .font(KiddoTokens.Typography.monoSmall)
                    .foregroundStyle(.secondary)
                if let w {
                    HStack(spacing: KiddoTokens.Spacing.xs) {
                        statusBadge(label: "↑", count: w.totalSent)
                        statusBadge(label: "↓", count: w.totalPulled)
                        if w.queueDepth > 0 {
                            statusBadge(label: "queue", count: w.queueDepth)
                        }
                    }
                    if let err = w.lastError {
                        Text(err)
                            .font(KiddoTokens.Typography.caption)
                            .foregroundStyle(KiddoTokens.statusAttentionFg)
                            .lineLimit(2)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, KiddoTokens.Spacing.sm)
        .padding(.vertical, KiddoTokens.Spacing.xxs)
    }

    private func statusBadge(label: String, count: Int) -> some View {
        Text("\(label) \(count)")
            .font(KiddoTokens.Typography.monoSmall)
            .foregroundStyle(.secondary)
    }

    /// Same conditions the old `rowColor` used, mapped onto the one
    /// canonical status style: no worker / not running → idle,
    /// lastError → attention, otherwise running.
    private func rowStatusStyle(_ w: AccountWorker?) -> WorkerStatusStyle {
        guard let w = w else { return .idle }
        if !w.running { return .idle }
        if w.lastError != nil { return .attention }
        return .running
    }

    private var actions: some View {
        VStack(spacing: KiddoTokens.Spacing.xxs) {
            Button {
                openSettings()
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("Open Settings…")
                    Spacer()
                }
                .frame(minHeight: KiddoTokens.Size.minHit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, KiddoTokens.Spacing.sm)

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit Kiddo")
                    Spacer()
                }
                .frame(minHeight: KiddoTokens.Size.minHit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, KiddoTokens.Spacing.sm)
        }
        .padding(.vertical, KiddoTokens.Spacing.xxs)
    }

    private func openSettings() {
        // Call openSettingsWindow() on the REAL AppDelegate instance.
        // The previous `AppDelegate.openSettingsWindowStatic()` did
        // `NSApp.delegate as? AppDelegate` — that cast fails for a
        // SwiftUI `@NSApplicationDelegateAdaptor` app (SwiftUI's own
        // delegate sits in `NSApp.delegate` and forwards to ours), so
        // the static path silently no-op'd and the menu's "Open
        // Settings…" did nothing. The injected `appDelegate` reference
        // is the live instance — no cast, no failure.
        appDelegate.openSettingsWindow()
    }
}

// =================================================================
// KiddoSplashView — the brief launch splash. AxiomKiddo opens no
// window of its own (it's a menu-bar `.accessory` app), so without
// this the only launch feedback is a menu-bar icon users routinely
// miss — they think the app failed to start. The splash makes
// "I'm running, and here's WHERE" unmistakable, then auto-dismisses.
// =================================================================
struct KiddoSplashView: View {
    var body: some View {
        VStack(spacing: KiddoTokens.Spacing.sm) {
            // The app icon — no separate asset needed; this is the
            // same icon the user will be hunting for in the menu bar
            // conceptually (envelope glyph), so showing the app
            // identity here anchors it.
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
            }

            Text("AxiomKiddo")
                .font(KiddoTokens.Typography.title)
            Text("Mail transport for AXIOM wallets")
                .font(KiddoTokens.Typography.caption)
                .foregroundStyle(.secondary)

            Divider().frame(width: 180)

            // The load-bearing message — tells the user the app is
            // running AND where to find it. The envelope glyph
            // matches the menu-bar icon (`AppDelegate.menuIcon`).
            VStack(spacing: KiddoTokens.Spacing.xxs) {
                HStack(spacing: KiddoTokens.Spacing.xxs) {
                    Image(systemName: "arrow.up")
                    Image(systemName: "envelope")
                }
                .font(KiddoTokens.Typography.labelStrong)
                .foregroundStyle(.secondary)
                Text("AxiomKiddo is running. It lives in the menu bar at the top of your screen — look for the envelope icon.")
                    .font(KiddoTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(EdgeInsets(top: KiddoTokens.Spacing.md,
                            leading: KiddoTokens.Spacing.xl,
                            bottom: KiddoTokens.Spacing.xl,
                            trailing: KiddoTokens.Spacing.xl))
        .frame(width: 340, height: 320)
    }
}
