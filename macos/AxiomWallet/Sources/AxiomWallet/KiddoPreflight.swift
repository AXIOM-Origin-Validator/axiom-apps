import Foundation
import SwiftUI
import AppKit

// =================================================================
// KiddoPreflight — detects whether AxiomKiddo.app is installed,
// running, and configured to relay mail for a given wallet email.
//
// Why this exists:
//
// The SDK is decoupled from any SMTP/POP3 transport — `wallet.send`,
// `wallet.fund_genesis`, `wallet.redeem`, etc. write a UMP envelope
// into `<walletDir>/outbox/new/` and block on `<walletDir>/maildir/
// inbox/new/` for k=3 validator cheques. There is NO code in the
// SDK that opens a network connection except to Nabla (see
// CLAUDE.md §8 "SDK ↔ transport boundary"). Something else has to
// pick the outbox up, ship it via SMTP, and drop the responses
// into the maildir. On Mac that something is AxiomKiddo.app.
//
// Without Kiddo configured for THIS wallet's email, every claim /
// send hangs for its full timeout window (60s for claim, longer
// for sends) and surfaces a confusing "didn't receive cheques"
// error. The user has no way to know it's a setup problem rather
// than a network outage.
//
// This helper reads two on-disk pieces of state — Kiddo's
// `accounts.json` and the NSWorkspace process table — and reports
// whether the broadcast path is likely to work. UI views call
// `KiddoPreflight.checkNow(for: email)` once and then poll via the
// `KiddoPreflightWatcher` observable for live updates.
//
// Match key: `KiddoAccount.walletEmail`. A `KiddoAccount.walletDir`
// mismatch (two wallets at the same email, different directories)
// would still report .ready here — that's an edge case the second
// wallet's owner would discover the first time they Send, and
// tightening to (email, walletDir) match is a follow-up if it
// becomes a real complaint.
// =================================================================

/// Result of a one-shot Kiddo readiness check.
enum KiddoPreflightState: Equatable {
    /// AxiomKiddo is running AND has an account configured for this
    /// wallet's email. Broadcasts should round-trip cleanly.
    case ready

    /// `/Applications/AxiomKiddo.app` doesn't exist. User likely
    /// hasn't installed it (or installed Wallet without the
    /// companion DMG). Recovery: install Kiddo or use a non-Kiddo
    /// transport (FATMAMA dev env, sendmail/postfix, etc.).
    case notInstalled

    /// Kiddo is installed but not running. Recovery: launch it.
    /// The accounts.json may still be empty — caller should treat
    /// this as "not ready", launch, and re-check after the user
    /// configures.
    case notRunning

    /// Kiddo is running but `accounts.json` has no entry whose
    /// `walletEmail` matches the wallet under inspection. Recovery:
    /// open Kiddo Settings and add an account.
    case noAccountForEmail(walletEmail: String)
}

enum KiddoPreflight {
    /// The bundle ID we look up via `NSRunningApplication`. Matches
    /// `AxiomKiddo/Info.plist` and the dev/release builds.
    static let bundleID = "org.axiom.AxiomKiddo"

    /// The disk path Kiddo writes `accounts.json` to (see
    /// `AccountStore.fileURL` in AxiomKiddo).
    static let accountsJSONPath: String = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("AxiomKiddo/accounts.json").path
    }()

    /// The install path we surface to the user when prompting them
    /// to launch. Both dev (build-dev-app.sh) and release
    /// (release-dmg.sh) install here.
    static let installPath = "/Applications/AxiomKiddo.app"

    /// One-shot synchronous check. Cheap (file read + process table
    /// scan, both microseconds). Safe to call from main thread.
    static func checkNow(walletEmail: String) -> KiddoPreflightState {
        // (1) Installed? Tested before the process check so a totally-
        // missing Kiddo gives a specific "go install it" message
        // instead of the generic "launch it".
        if !FileManager.default.fileExists(atPath: installPath) {
            return .notInstalled
        }

        // (2) Running? `NSRunningApplication` covers both dev (.app
        // launched via `open`) and the release MenuBarExtra. Bundle ID
        // is the stable identity across both.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.isEmpty {
            return .notRunning
        }

        // (3) Account configured for this email? Decode accounts.json
        // and look for a `walletEmail` match. We intentionally avoid
        // depending on the Kiddo Swift target — the file format is the
        // contract. Match is case-insensitive on the local-part to be
        // forgiving of "User@AXIOM" vs "user@axiom".
        let target = walletEmail.lowercased()
        if let accounts = loadAccountsJSON(), accounts.contains(where: {
            $0.walletEmail.lowercased() == target
        }) {
            return .ready
        }
        return .noAccountForEmail(walletEmail: walletEmail)
    }

    /// Open `/Applications/AxiomKiddo.app`. Returns the launched
    /// `NSRunningApplication` on success; nil on failure (Kiddo not
    /// installed at the expected path, or the OS refused to launch).
    /// Callers can re-poll `checkNow` after a short delay to confirm
    /// the launch took effect.
    @discardableResult
    static func launchKiddo() -> NSRunningApplication? {
        let url = URL(fileURLWithPath: installPath)
        // NSWorkspace.openApplication is the macOS 11+ async API.
        // We use the sync fallback because the call site is the user
        // tapping a button — they expect "launch and re-check" not
        // an async pipeline.
        return try? NSWorkspace.shared.launchApplication(at: url, options: [], configuration: [:])
    }

    /// Open Kiddo's Settings window via the `axiomkiddo://settings`
    /// URL scheme. Kiddo's `AppDelegate.application(_:open:)` parses
    /// the URL and calls `NSApp.sendAction(Selector("showSettingsWindow:"))`
    /// — which is the only cross-context way to drive a SwiftUI
    /// `Settings` scene from outside the app.
    ///
    /// Previous implementation just `activateIgnoringOtherApps`'d
    /// Kiddo, which brought the menu-bar icon to the foreground but
    /// left the user one step shy of Settings — they still had to
    /// click the icon → "Open Settings…". The URL scheme finishes
    /// the trip in one click.
    ///
    /// Falls back to plain launch if the URL open fails (very
    /// unlikely once Kiddo's Info.plist registers the scheme, but
    /// covers the "Kiddo from a stale build without the scheme"
    /// case — user lands on Kiddo's menu-bar icon and can take the
    /// last step manually, same as the old behaviour).
    static func openKiddoForSettings() {
        guard let url = URL(string: "axiomkiddo://settings") else {
            // Unreachable — literal URL is well-formed — but the
            // guard satisfies the optional and avoids a force-unwrap.
            _ = launchKiddo()
            return
        }
        // NSWorkspace.open routes the URL through LaunchServices,
        // which (a) launches Kiddo if it isn't running and (b)
        // delivers the URL to its `application(_:open:)`. Both
        // happen in one call — no separate launch + activate dance.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: installPath),
                                configuration: config) { _, error in
            if let error {
                // Pre-Info.plist Kiddo builds, or a launch failure.
                // Fall back to plain launch — user lands on the
                // menu-bar icon and can open Settings themselves.
                NSLog("KiddoPreflight: axiomkiddo:// open failed (\(error)) — falling back to launch-only")
                DispatchQueue.main.async {
                    _ = Self.launchKiddo()
                }
            }
        }
    }

    /// Auto-provision a dev/FATMAMA Kiddo account for this wallet via
    /// the `axiomkiddo://provision` URL route. Kiddo creates a
    /// `.axiomDev`-kind `KiddoAccount` bound to `walletEmail` +
    /// `walletDir`, deriving the FATMAMA SMTP/POP3 coords from the
    /// shared `axiom.conf` itself, then starts the account's worker
    /// (which begins polling FATMAMA — the "bind").
    ///
    /// Hands-free: the wallet's onboarding fires this for dev-class
    /// wallets so the user never hand-configures Kiddo. The route is
    /// idempotent on the Kiddo side — re-firing for an already-
    /// provisioned email is a no-op — so it's safe to call on every
    /// entry to the onboarding Kiddo step.
    ///
    /// `walletDir` is percent-encoded by `URLComponents` (the path
    /// contains spaces — "Application Support"). NSWorkspace routes
    /// the URL through LaunchServices, which launches Kiddo if it
    /// isn't running and delivers the route to `application(_:open:)`.
    ///
    /// Only call this for dev/FATMAMA wallets. A real-email wallet
    /// must NOT be auto-provisioned — its SMTP/POP3 needs a password
    /// Kiddo can't know; those go through manual Kiddo Settings.
    static func provisionKiddo(walletEmail: String, walletDir: String, label: String) {
        var comps = URLComponents()
        comps.scheme = "axiomkiddo"
        comps.host = "provision"
        comps.queryItems = [
            URLQueryItem(name: "email", value: walletEmail),
            URLQueryItem(name: "walletDir", value: walletDir),
            URLQueryItem(name: "label", value: label),
        ]
        guard let url = comps.url else {
            NSLog("KiddoPreflight: failed to build provision URL")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        // Don't steal focus — onboarding is mid-flow in the wallet;
        // the provision should happen quietly in the background and
        // the wallet's Kiddo step flips to .ready on its own.
        config.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: installPath),
                                configuration: config) { _, error in
            if let error {
                NSLog("KiddoPreflight: provision open failed (\(error))")
            }
        }
    }

    /// True when the wallet's `axiom.conf` points at a FATMAMA dev
    /// SMTP host — the case where Kiddo can synthesise the account
    /// without a password (FATMAMA accepts plain SMTP from any source).
    ///
    /// Bug B background: pre-fix, OnboardingView's auto-provision was
    /// gated on `isDevEmail` (i.e. `@axiom.internal` only) because for
    /// real-email wallets Kiddo can't know the SMTP/POP3 credentials.
    /// But the bundled axiom.conf points at `axiom-dev.mooo.com:2525`
    /// for any wallet — `@example.com` against the dev env is also
    /// FATMAMA-served and equally safe to auto-provision. The user
    /// reported smoke flow: send to a freshly-created `@example.com`
    /// wallet that never claimed genesis, the receiver's Receive view
    /// stays empty because FATMAMA drops every cheque (no XAXIOM-
    /// REGISTER fired → no route → DROP at RCPT TO). Once Kiddo is
    /// provisioned for that wallet, FATMAMA learns the route and
    /// subsequent cheques flow.
    ///
    /// "Dev-safe" matches the host patterns FATMAMA is plausibly
    /// running under in the dev / private-network world:
    ///   - `axiom-` prefix (axiom-dev.mooo.com, axiom-dev, …)
    ///   - `*.mooo.com` (the FreeDNS pattern this project uses)
    ///   - loopback (`127.0.0.1`, `::1`, `localhost`)
    ///   - private-network style (`*.internal`, `*.local`, `0.0.0.0`)
    /// Real-ISP hosts (`smtp.gmail.com`, `outlook.office365.com`, etc.)
    /// fall through to false — those need a password Kiddo can't know,
    /// so manual configuration via Settings → + still wins.
    ///
    /// Reads `appDir/axiom.conf` line-by-line. Returns false on missing
    /// file or unparseable contents — safer to skip auto-provision than
    /// to create a stub account that can never poll.
    static func smtpHostIsDevSafe(appDir: String) -> Bool {
        let path = "\(appDir)/axiom.conf"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // `key = value`, whitespace-tolerant. We only care about
            // `smtp_host`; everything else is skipped.
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0] == "smtp_host" else { continue }
            let host = parts[1].lowercased()
            if host.hasPrefix("axiom-")
                || host.hasSuffix(".mooo.com")
                || host == "localhost"
                || host == "127.0.0.1"
                || host == "::1"
                || host == "0.0.0.0"
                || host.hasSuffix(".internal")
                || host.hasSuffix(".local")
            {
                return true
            }
            return false
        }
        return false
    }

    // MARK: - accounts.json decode

    /// Minimal Codable view of a Kiddo account. We deliberately
    /// decode only the two fields we care about — `walletEmail` for
    /// the match and `walletDir` for the (future, currently unused)
    /// tighter match. New fields landing in Kiddo's `KiddoAccount`
    /// don't break us; missing optional fields don't break us.
    private struct KiddoAccountRow: Decodable {
        let walletEmail: String
        let walletDir: String?
    }

    private static func loadAccountsJSON() -> [KiddoAccountRow]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: accountsJSONPath)),
              let rows = try? JSONDecoder().decode([KiddoAccountRow].self, from: data) else {
            return nil
        }
        return rows
    }
}

// =================================================================
// KiddoPreflightWatcher — SwiftUI-observable poller.
//
// Wraps `checkNow` in a Timer-driven `@Published`. Onboarding +
// GenesisClaimSheet attach one as a `@StateObject`, the timer fires
// at 1Hz while the view is on-screen, and the published `state`
// drives the UI. Users tapping "Open Kiddo" → adding an account →
// returning to the wallet see the gate flip to `.ready` within a
// second without manual refresh.
// =================================================================

@MainActor
final class KiddoPreflightWatcher: ObservableObject {
    @Published private(set) var state: KiddoPreflightState

    private var walletEmail: String
    private var timer: Timer?

    init(walletEmail: String) {
        self.walletEmail = walletEmail
        // Initial synchronous read so the view's first render
        // already shows the correct state (no flicker through
        // a transient "checking…" frame).
        self.state = KiddoPreflight.checkNow(walletEmail: walletEmail)
    }

    /// Reconfigure the watched email after construction. Needed by
    /// `GenesisClaimSheet`, which can't pass the wallet email into
    /// `@StateObject` at init time (SwiftUI evaluates `@StateObject`
    /// initializers before the surrounding view's `@EnvironmentObject`
    /// resolves). The sheet constructs the watcher with an empty
    /// email and re-targets it in `.onAppear`.
    ///
    /// No-op if the email is unchanged.
    func setEmail(_ email: String) {
        guard email != walletEmail else { return }
        walletEmail = email
        recheck()
    }

    /// Begin polling. Idempotent — a second call is a no-op while
    /// the existing timer is alive. Call from the view's `.onAppear`.
    func start() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // Timer fires on the main runloop; @MainActor isolated.
            // The Task hop is required because Timer's closure isn't
            // declared @MainActor and Swift Concurrency would
            // otherwise warn about the actor-isolated `recheck` call.
            Task { @MainActor in
                self?.recheck()
            }
        }
        // Common runloop mode so the timer keeps firing during
        // modal sheets — without this the gate would stop updating
        // exactly when the user is most likely to be looking at it
        // (inside the claim sheet).
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stop polling. Call from the view's `.onDisappear` to avoid
    /// leaking a 1Hz timer for the rest of the process lifetime.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One-shot re-check. Public so a "Refresh" button can drive
    /// it without waiting for the next timer tick.
    func recheck() {
        let next = KiddoPreflight.checkNow(walletEmail: walletEmail)
        if next != state {
            state = next
        }
    }

    deinit {
        // Don't touch `timer` here — Timer.invalidate must run on
        // the runloop that scheduled the timer (main), and `deinit`
        // can run on a background actor. Callers are expected to
        // call `stop()` in `.onDisappear`. If they forget, the
        // worst case is one leaked 1Hz timer per orphaned watcher
        // — annoying but not unsafe.
    }
}
