import Foundation
import SwiftUI

// =================================================================
// DigitVersionWatcher — tracks the Console's *suggested* L$
// digit_version (read from the axiom-dist feed; not enforced).
//
// digit_version is a display-only convention: 1 AXC = 10^dv L$. AXC /
// atoms are the invariant unit — a dv change never changes value, only
// how L$ is shown. It is a suggestion (many independent wallets exist;
// none can be forced onto a dv), so the feed is just a coordination
// point and any wallet may ignore it.
//
// When the suggested dv changes we adopt it for display and arm a
// reminder that fires on the user's NEXT 3 TRANSACTIONS — non-ignorable,
// terse, with a drift-relevant example — so the new L$ scale can't
// surprise anyone. After 3 transactions it's done.
// =================================================================
@MainActor
final class DigitVersionWatcher: ObservableObject {
    /// dv currently applied to L$ display — persisted so display survives
    /// an offline launch (worldline.json unreachable) and so a change is
    /// detected by comparing the new suggestion against it.
    @AppStorage("axiom.dv.applied") private var appliedDV: Int = 0
    /// Transactions left in the current reminder cycle (0 = none active).
    @AppStorage("axiom.dv.remindLeft") private var remindLeft: Int = 0
    @AppStorage("axiom.dv.remindFrom") private var remindFrom: Int = 0
    @AppStorage("axiom.dv.remindTo") private var remindTo: Int = 0
    /// The Console-published date this dv suggestion took effect
    /// (`digit_version_started` from worldline.json, e.g. "2026-06-17").
    /// Empty if the feed didn't carry one. Persisted so both warning
    /// channels can show "in effect since …" even on an offline launch.
    @AppStorage("axiom.dv.startedDate") private var startedDate: String = ""
    /// App launches left in the launch-popup cycle (0 = none active). A
    /// SECOND warning channel alongside the per-send gate: the user sees
    /// the dv-change notice on their next 3 app starts too, so it can't
    /// be missed by someone who doesn't send for a while.
    @AppStorage("axiom.dv.launchLeft") private var launchLeft: Int = 0

    /// Bumped so SwiftUI re-evaluates `needsSendWarning` after a consume.
    @Published private(set) var cycleTick = 0
    /// Drives the launch popup. Set true by `tickLaunchWarning()` once per
    /// app start while a launch cycle is active; the view clears it.
    @Published var showLaunchWarning = false
    /// Guards `tickLaunchWarning()` to fire at most once per process launch
    /// (it's wired to an `onReceive` that can emit more than once).
    private var launchTicked = false

    init() {
        // Restore the last-applied dv before any fetch, so L$ display is
        // correct even when worldline.json can't be reached this launch.
        let applied = UserDefaults.standard.integer(forKey: "axiom.dv.applied")
        DigitVersionState.current = UInt8(max(0, min(255, applied)))
    }

    var fromDV: Int { remindFrom }   // old dv (for the "was X L$" line)
    var toDV: Int { remindTo }       // new dv (now applied)
    /// "in effect since" date for the active change, or "" if the feed
    /// carried none. Both the pre-send gate and launch popup show it.
    var effectiveDate: String { startedDate }

    /// True while the dv-change warning should gate sends. Clears after
    /// 3 confirmed sends.
    var needsSendWarning: Bool { remindLeft > 0 }

    /// "1/3", "2/3", "3/3" — which of the 3 warnings this is.
    var sendWarningCounter: String { "\(max(1, 4 - remindLeft))/3" }

    /// "1/3", "2/3", "3/3" — which of the 3 launch warnings this is.
    var launchWarningCounter: String { "\(max(1, 4 - launchLeft))/3" }

    /// Adopt the feed's suggested dv for display; if it changed vs what's
    /// already applied, arm a fresh 3-send warning cycle. No popup — the
    /// warning is shown as a pre-send confirmation gate (see SendView).
    func apply(suggested dv: Int, started: String) {
        let clamped = max(0, min(255, dv))
        let prev = appliedDV
        DigitVersionState.current = UInt8(clamped)
        guard clamped != prev else { return } // no change → no warning
        remindFrom = prev
        remindTo = clamped
        appliedDV = clamped
        startedDate = started
        remindLeft = 3
        launchLeft = 3   // arm the launch-popup channel too
        cycleTick += 1
    }

    /// Count one warned send. Call when the user confirms the dv warning
    /// and proceeds. After the 3rd, `needsSendWarning` goes false.
    func consumeSendWarning() {
        remindLeft = max(0, remindLeft - 1)
        cycleTick += 1
    }

    /// Fire the launch popup once per process launch if a launch cycle is
    /// active. Call ONLY after login (bio-auth overlaps a sheet shown at
    /// launch — see MainAppView.onAppear + the unlocked-gated onReceive).
    /// The once-per-launch guard is spent only when the popup actually
    /// shows, so an early call with nothing armed (feed not yet applied)
    /// doesn't block a later call once the change lands.
    func tickLaunchWarning() {
        guard !launchTicked else { return }
        guard launchLeft > 0 else { return }   // nothing armed yet — retry later
        launchTicked = true
        showLaunchWarning = true
    }

    /// Acknowledge the launch popup. Counts one launch (1/3 … 3/3) and
    /// dismisses; after the 3rd it no longer appears on future launches.
    func consumeLaunchWarning() {
        launchLeft = max(0, launchLeft - 1)
        showLaunchWarning = false
    }
}
