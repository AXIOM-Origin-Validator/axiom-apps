import Foundation

// =================================================================
// LastNablaTickStore — persist the most-recently-observed Nabla
// TARDIS tick across app relaunches.
//
// The SDK side (`axiom-sdk/client/src/nabla.rs`) stores the tick + observation
// time in two static `AtomicU64`s. Process-global, in-memory only,
// reset to 0 on every relaunch. The OverviewView's "TARDIS <n> +
// <m> min" indicator depended on those statics, so after quit/relaunch
// the user always saw "TARDIS —" until the next register op, even
// though the wallet had observed a tick in the previous session and
// it was still recent.
//
// Fix shape:
//   - Persist (tick, seenAt) to UserDefaults whenever the SDK
//     observes a fresher tick than what's on disk.
//   - At display time, merge SDK + persisted by `seenAt` — return
//     whichever has the more recent observation timestamp.
//   - The TARDIS tick is a property of the Nabla mesh (not of a
//     specific wallet), so a single app-level pair is the right
//     scope. No per-wallet plumbing needed.
//
// Storage is UserDefaults under the bundle ID:
//   ~/Library/Preferences/org.axiom.AxiomWallet.plist
// — survives drag-to-trash uninstall, intentionally cleared by
// `defaults delete org.axiom.AxiomWallet`.
// =================================================================

enum LastNablaTickStore {
    private static let tickKey   = "lastTardisTick"
    private static let seenAtKey = "lastTardisSeenAt"

    /// Read the persisted (tick, seenAt). Returns (0, 0) if nothing
    /// was ever persisted on this Mac.
    static var persisted: (tick: UInt64, seenAt: UInt64) {
        let d = UserDefaults.standard
        let tick = UInt64(d.integer(forKey: tickKey))
        let seenAt = UInt64(d.integer(forKey: seenAtKey))
        return (tick, seenAt)
    }

    /// Persist (tick, seenAt) if either is non-zero. No-op for the
    /// (0, 0) sentinel pair — that's "I haven't observed anything yet"
    /// and persisting it would clobber a legitimate prior observation.
    static func write(tick: UInt64, seenAt: UInt64) {
        guard tick != 0 || seenAt != 0 else { return }
        let d = UserDefaults.standard
        d.set(Int(tick), forKey: tickKey)
        d.set(Int(seenAt), forKey: seenAtKey)
    }

    /// Merge the SDK's in-process observation with the persisted one
    /// and return whichever has the more recent `seenAt`. Side-effect:
    /// if SDK is newer, write the SDK values to UserDefaults so the
    /// next process inherits them.
    ///
    /// This is the function the UI should call instead of the bare
    /// `sdkLastNablaTick()` / `sdkLastNablaSeenAt()` pair.
    static func effective(sdkTick: UInt64, sdkSeenAt: UInt64) -> (tick: UInt64, seenAt: UInt64) {
        let p = persisted
        if sdkSeenAt > p.seenAt {
            // SDK observed something newer (any register op this
            // process did). Persist it forward.
            write(tick: sdkTick, seenAt: sdkSeenAt)
            return (sdkTick, sdkSeenAt)
        }
        return p
    }
}
