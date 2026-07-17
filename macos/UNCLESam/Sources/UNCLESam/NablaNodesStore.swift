import Foundation
import SwiftUI
import AxiomSdk

// =================================================================
// Per-node Nabla service mode — surfaced to the institutional
// operator under the Provisional / Confirmed pairing rather than
// the SDK-internal `Bloom` / `Hashmap` names.
//
// Mapping (AXIOM Origin, 2026-05-30):
//   Provisional ⇄ Nabla's TxidServiceMode::Bloom
//     fast lookup, ~0.1% false positive rate. Useful for casual
//     retail-tier queries; NOT acceptable for institutional
//     settlement finality because a false positive lands as a
//     silent wrong answer at exactly the moment the bank needs
//     to be definitive.
//
//   Confirmed ⇄ Nabla's TxidServiceMode::Hashmap
//     zero false positives. The bank treats Nabla-Confirmed as
//     authoritative for settlement-finality decisions; the
//     UNCLE SAM picker only routes notarisation queries through
//     Confirmed-grade nodes.
//
// UNCLE SAM's institutional policy: only Confirmed counts for
// settlement. Provisional nodes are still listed in the Network
// settings (transparency, upgrade-path visibility, cross-bank
// reconciliation) but marked "not used (institutional policy)".
// If 0 Confirmed-grade nodes are reachable the bank's ops team
// gets an explicit "settlements paused" banner via the
// connection-health strip — never silently degraded to a
// Provisional answer.
//
// Discovery: each node is probed at app startup by calling
// `sdkProbeNablaMode(tcpAddress:)`. The FFI dispatches a
// `QueryTxidRequest(probe)` and returns the node's advertised
// `service_mode` ("hashmap" / "bloom" / "" for old Nabla
// binaries that don't advertise). Empty / unreachable nodes
// surface as Provisional + offline so the institutional filter
// excludes them by default. The user can press "Refresh" in
// Settings → Network to re-probe any time.
// =================================================================

enum NablaServiceMode: String, Codable, Identifiable {
    case provisional
    case confirmed
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .provisional: return "Provisional"
        case .confirmed:   return "Confirmed"
        }
    }
    /// One-line description for tooltips + Settings card.
    var explanation: String {
        switch self {
        case .provisional:
            return "Quick lookup. ~0.1% false-positive rate; not accepted by UNCLE SAM for settlement finality."
        case .confirmed:
            return "Definitive lookup. Zero false positives. Authoritative for institutional settlement."
        }
    }
    var dotColor: Color {
        switch self {
        case .provisional: return DesignTokens.statusPendingFg
        case .confirmed:   return DesignTokens.statusSettledFg
        }
    }
    var pillFg: Color {
        switch self {
        case .provisional: return DesignTokens.statusPendingFg
        case .confirmed:   return DesignTokens.statusSettledFg
        }
    }
    var pillBg: Color {
        switch self {
        case .provisional: return DesignTokens.statusPendingBg
        case .confirmed:   return DesignTokens.statusSettledBg
        }
    }
}

/// One row in the Network → Nabla nodes table. Live-probed via
/// `sdkProbeNablaMode(tcpAddress:)` — see NablaNodesStore.
struct NablaNodeStatus: Identifiable, Codable {
    let id: UUID
    let name: String
    let endpoint: String        // e.g. "axiom-dev.mooo.com:7300"
    let ed25519PubkeyHex: String
    var mode: NablaServiceMode
    /// `true` when the node replied to the probe within the
    /// timeout. False = unreachable, gossip-only, or
    /// confirmation pending.
    var online: Bool
    /// Timestamp of the most recent probe attempt; nil before
    /// the first probe completes.
    var lastProbedAt: Date?
    /// True between probe dispatch and probe response — the UI
    /// uses this to render a "probing…" affordance.
    var isProbing: Bool

    /// `true` when this node passes UNCLE SAM's institutional
    /// settlement filter: online AND confirmed-grade. The picker
    /// only routes Nabla queries through nodes where this is true.
    var inServiceForSettlement: Bool {
        online && mode == .confirmed
    }

    init(name: String, endpoint: String,
         ed25519PubkeyHex: String,
         mode: NablaServiceMode = .provisional,
         online: Bool = false,
         lastProbedAt: Date? = nil,
         isProbing: Bool = false) {
        self.id = UUID()
        self.name = name
        self.endpoint = endpoint
        self.ed25519PubkeyHex = ed25519PubkeyHex
        self.mode = mode
        self.online = online
        self.lastProbedAt = lastProbedAt
        self.isProbing = isProbing
    }
}

/// Observable live-probed store. Loads the seed list from the
/// bundled `nabla-nodes.list.default`, then probes each node via
/// the SDK's `sdkProbeNablaMode(tcpAddress:)` FFI to discover the
/// real service mode + reachability. Re-probe via `refresh()`.
@MainActor
final class NablaNodesStore: ObservableObject {

    @Published private(set) var nodes: [NablaNodeStatus] = []
    /// Wall-clock timestamp of the last full refresh kicked off.
    /// `nil` before the first probe round.
    @Published private(set) var lastRefreshStartedAt: Date?

    init() {
        loadSeed()
        refresh()
    }

    /// Count of nodes UNCLE SAM is willing to use for settlement
    /// notarisation — online + Confirmed-grade.
    var confirmedGradeAvailable: Int {
        nodes.filter { $0.inServiceForSettlement }.count
    }
    var total: Int { nodes.count }

    /// True when the bank has at least one Confirmed-grade Nabla
    /// node it can reach — the line between "operating normally"
    /// and "settlements paused".
    var hasSettlementCapacity: Bool {
        confirmedGradeAvailable > 0
    }

    /// True while at least one probe is in flight.
    var isProbing: Bool {
        nodes.contains { $0.isProbing }
    }

    /// Dispatch a concurrent probe per node. Idempotent: re-running
    /// while previous probes are in flight is safe (each probe
    /// updates its own node row on completion).
    func refresh() {
        lastRefreshStartedAt = Date()
        for index in nodes.indices {
            // Mark the row "probing" up front so the UI can render
            // a spinner / faded chip while we wait.
            nodes[index].isProbing = true
            let endpoint = nodes[index].endpoint
            let nodeId = nodes[index].id
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // FFI call is synchronous and blocks until the
                // TCP probe completes (or times out at the SDK
                // level). Run off main; dispatch the result back.
                let probedMode: String?
                do {
                    probedMode = try sdkProbeNablaMode(tcpAddress: endpoint)
                } catch {
                    probedMode = nil
                }
                let result = probedMode
                DispatchQueue.main.async {
                    self?.applyProbeResult(nodeId: nodeId, raw: result)
                }
            }
        }
    }

    /// Map the SDK's `"hashmap"` / `"bloom"` / `""` answer onto the
    /// UI's Provisional / Confirmed pairing + online flag, and
    /// mutate the matching node row. Called on the main actor.
    private func applyProbeResult(nodeId: UUID, raw: String?) {
        guard let index = nodes.firstIndex(where: { $0.id == nodeId }) else {
            return
        }
        nodes[index].isProbing = false
        nodes[index].lastProbedAt = Date()
        switch raw {
        case .some("hashmap"):
            nodes[index].mode = .confirmed
            nodes[index].online = true
        case .some("bloom"):
            nodes[index].mode = .provisional
            nodes[index].online = true
        case .some(""):
            // Old Nabla binary that doesn't advertise service_mode.
            // Reachable, but not safely classifiable as either —
            // default to Provisional so the institutional filter
            // excludes it from settlement decisions.
            nodes[index].mode = .provisional
            nodes[index].online = true
        case .some, .none:
            // Network failure, timeout, malformed response, or any
            // other error path — node is unreachable for our
            // purposes. Keep the prior mode badge but mark offline.
            nodes[index].online = false
        }
    }

    /// Parse the bundled `nabla-nodes.list.default` and populate the
    /// initial node list. Format (matches the file's header
    /// comment): three quoted comma-separated fields per row —
    /// `"name", "ed25519_pubkey_hex_or_empty", "TCP:host:port"`.
    /// Blank lines and '#' comments ignored.
    private func loadSeed() {
        guard let path = Bundle.main.path(
                forResource: "nabla-nodes.list.default",
                ofType: nil)
        else {
            // Bundle resource missing — keep nodes empty rather
            // than fall back to mock data. The Network card will
            // show "0 of 0" which is the truthful state.
            return
        }
        let raw: String
        do {
            raw = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            return
        }
        var parsed: [NablaNodeStatus] = []
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let row = Self.parseSeedLine(trimmed) else { continue }
            parsed.append(NablaNodeStatus(
                name: row.name,
                endpoint: row.endpoint,
                ed25519PubkeyHex: row.pubkey.isEmpty
                    ? "(not yet pinned in seed)"
                    : row.pubkey
            ))
        }
        nodes = parsed
    }

    /// Split a seed-file line into (name, pubkey, endpoint). The
    /// endpoint field is the third quoted value with the
    /// `TCP:` scheme stripped — `sdkProbeNablaMode` wants a bare
    /// `host:port` string.
    static func parseSeedLine(_ line: String) -> (name: String,
                                                   pubkey: String,
                                                   endpoint: String)? {
        // Tolerant split: collapse runs of `","` and trim. Format
        // is fixed and operator-edited so we don't need a full
        // CSV parser — but we DO need to strip the surrounding
        // quotes on each field.
        let fields = line.components(separatedBy: ",").map { field -> String in
            var s = field.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("\"") { s.removeFirst() }
            if s.hasSuffix("\"") { s.removeLast() }
            return s
        }
        guard fields.count >= 3 else { return nil }
        let name = fields[0]
        let pubkey = fields[1]
        var endpoint = fields[2]
        // Strip the carrier scheme — `sdkProbeNablaMode` wants
        // bare `host:port`. We default to TCP because the file
        // header documents TCP is the canonical Nabla transport
        // for native clients (CLAUDE.md §8 SDK transport boundary).
        if endpoint.uppercased().hasPrefix("TCP:") {
            endpoint = String(endpoint.dropFirst(4))
        }
        return (name: name, pubkey: pubkey, endpoint: endpoint)
    }
}

// =================================================================
// NablaModeChip — small pill rendered in tables.
// =================================================================

struct NablaModeChip: View {
    let mode: NablaServiceMode
    var body: some View {
        Text(mode.displayName.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(mode.pillFg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(mode.pillBg)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(mode.explanation)
    }
}
