import Foundation
import AxiomSdk

// =================================================================
// VersionSkewWatcher — app-scoped observer of client/server SDK
// protocol-version skew.
//
// The SDK FFI exposes four accessors (`clientProtocolVersion`,
// `serverProtocolVersion`, `minClientProtocolVersion`,
// `isSdkTooOld`) backed by a process-global cache that updates on
// every Nabla ACK. This object pulls those values forward after a
// broadcast and republishes them as `@Published` properties so the
// UI can react.
//
// Two surfaces drive off this state:
//
//  1. `isSdkTooOld` — the mesh's stated min-client floor exceeds
//     this SDK's baked version. The wallet binary will misinterpret
//     newer error codes; we surface a blocking "Update Required"
//     alert (one-shot per session) and disable all broadcast paths
//     (Send / Redeem / Claim). Persistent banner stays at the top
//     of the main shell so dismissing the alert doesn't lose the
//     state.
//
//  2. `updateAvailable` (derived: server > client && !isSdkTooOld)
//     — server is newer but still tolerates this client. Surfaced
//     as an unobtrusive Settings chip; never blocks anything.
//
// Refresh is caller-driven: each broadcast site (SendCoordinator,
// BundleDetailView redeem, GenesisClaimSheet claim) calls
// `refresh(from:)` on the success path. We don't poll on a timer —
// the SDK's only source of truth is incoming ACKs, and ACKs only
// happen during broadcasts.
// =================================================================

@MainActor
final class VersionSkewWatcher: ObservableObject {
    /// The mesh has bumped its `min_client_protocol_version` past
    /// this SDK's baked `CLIENT_PROTOCOL_VERSION` — broadcasts are
    /// unsafe (the wallet cannot reliably interpret newer error
    /// codes). UI must refuse further send/redeem/claim and surface
    /// the Update Required alert.
    @Published private(set) var isSdkTooOld: Bool = false

    /// Last-observed `server_protocol_version` from a Nabla ACK.
    /// Zero until the first ACK has landed in this process.
    @Published private(set) var serverProtocolVersion: UInt32 = 0

    /// Last-observed mesh floor (`min_client_protocol_version`).
    /// Zero until the first ACK has landed.
    @Published private(set) var minClientProtocolVersion: UInt32 = 0

    /// This SDK's baked client protocol version. Latched once on
    /// the first refresh; constant for the life of the process.
    @Published private(set) var clientProtocolVersion: UInt32 = 0

    /// Server reports a newer protocol than this client, but the
    /// mesh still tolerates us. Drives the optional Settings
    /// "Update available" chip — never blocks broadcasts.
    var updateAvailable: Bool {
        serverProtocolVersion > 0
            && serverProtocolVersion > clientProtocolVersion
            && !isSdkTooOld
    }

    /// True if `isSdkTooOld` has flipped on at least once in this
    /// session. Used by `MainAppView` to fire the one-shot alert.
    /// Reset to `false` only when the watcher is destroyed (i.e.
    /// on logout / app relaunch).
    @Published var alertPending: Bool = false

    /// Pull current values out of the SDK's process-global runtime.
    /// Called on the success path of every broadcast (send, redeem,
    /// fund_genesis). Idempotent — if the SDK has no fresh ACK to
    /// report, the values are unchanged.
    func refresh(from wallet: AxiomWallet) {
        let client = wallet.clientProtocolVersion()
        let server = wallet.serverProtocolVersion()
        let minClient = wallet.minClientProtocolVersion()
        let tooOld = wallet.isSdkTooOld()

        let flippedToTooOld = tooOld && !isSdkTooOld

        clientProtocolVersion = client
        serverProtocolVersion = server
        minClientProtocolVersion = minClient
        isSdkTooOld = tooOld

        if flippedToTooOld {
            alertPending = true
        }
    }
}
