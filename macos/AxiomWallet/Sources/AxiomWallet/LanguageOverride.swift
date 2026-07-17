import Foundation
import AppKit

// =================================================================
// LanguageOverride — read / write the AppleLanguages UserDefault.
//
// macOS resolves `Bundle.main`'s localized resources against
// the first BCP-47 code in the `AppleLanguages` array (under the
// app's bundle ID, falling back to the global). Writing to this
// key from inside the app overrides the system preference. The
// override survives relaunches and uninstall+drag-to-trash, since
// it's persisted in `~/Library/Preferences/org.axiom.AxiomWallet.plist`
// (the standard UserDefaults plist).
//
// SwiftUI doesn't rebuild already-rendered views against a new
// locale — so changing the language is a "set and relaunch" flow.
// The Settings panel hands the user a "Relaunch wallet" button
// after a change.
// =================================================================

enum LanguageOverride {

    /// Sentinel used by the picker for "follow system default."
    /// Empty `AppleLanguages` (or unset) gives macOS the wheel.
    static let systemDefaultSentinel = ""

    private static let key = "AppleLanguages"

    /// Returns the current override BCP-47 code, or
    /// `systemDefaultSentinel` if the app has set none.
    ///
    /// We read the app's OWN persistent domain rather than
    /// `UserDefaults.standard.array(forKey:)`. The latter resolves
    /// `AppleLanguages` through `NSGlobalDomain`, so on a fresh
    /// install (no app override yet) it returns the full system code
    /// — e.g. `en-US` / `zh-Hant-TW` — which matches none of the
    /// picker's bare tags (`en` / `zh-Hant` / `ja`) and leaves the
    /// Picker rendering blank. The persistent domain contains only
    /// what `set(_:)` wrote (always a bare tag, or absent), so an
    /// unset override correctly reads back as "System default".
    static var current: String {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let domain = UserDefaults.standard.persistentDomain(forName: bundleID)
        let langs = domain?[key] as? [String] ?? []
        return langs.first ?? systemDefaultSentinel
    }

    /// Persist a new override. Pass `systemDefaultSentinel` (empty
    /// string) to clear the override and let macOS pick.
    static func set(_ bcp47: String) {
        let d = UserDefaults.standard
        if bcp47.isEmpty {
            d.removeObject(forKey: key)
        } else {
            d.set([bcp47], forKey: key)
        }
        d.synchronize()
    }

    /// Relaunch the wallet. Spawns a new instance via `open` then
    /// terminates this one — macOS handles the handoff cleanly.
    /// Used after a language change so SwiftUI picks up the new
    /// bundle locale on the fresh process.
    static func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        // -n forces a new instance even if the app is already running
        // (it won't be, since we're about to terminate, but -n
        // protects against the rare case where the terminate is
        // slow and `open` finds the still-alive PID).
        task.arguments = ["-n", bundlePath]
        try? task.run()
        // Give the new instance ~200 ms to start launching before
        // we kill ourselves, so macOS sees overlap rather than a
        // dead-then-resurrect transition.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.terminate(nil)
        }
    }
}
