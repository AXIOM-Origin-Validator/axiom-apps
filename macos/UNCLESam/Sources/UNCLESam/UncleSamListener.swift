import Foundation
import Network
import SwiftUI

// =================================================================
// UNCLE SAM peer TCP listener — bilateral correspondent protocol.
//
// Inbound side of the UNCLE SAM ↔ UNCLE SAM peer wire described in
// docs/AXIOM_DESIGN_UNCLE.md + the side-branch correspondence with
// Linux. The sender bank's UNCLE SAM opens a direct TCP socket to
// this listener, ships a PGP-wrapped NotifyCheques envelope, and
// waits for a NotifyChequesAck on the same connection.
//
// THIS COMMIT — Bucket 1 scaffolding only:
//   - Bind / accept loop using Network framework (NWListener)
//   - u32 BE length-prefixed framing matching axiom-uncle/src/
//     listener.rs (MAX_ENVELOPE_BYTES = 4 MiB)
//   - Connection lifecycle + framing parser + handler trait
//   - Stub handler that records the inbound bytes + closes
//     without replying
//
// DEFERRED to Buckets 2 + 3 (need Linux's axiom-pgp-envelope crate
// + unclesam-wire crate to land):
//   - PGP envelope decrypt + signature verify
//   - CBOR-decode the NotifyCheques body
//   - Canonical-bytes ed25519 verify on sender_signature
//   - Compose + sign + encrypt NotifyChequesAck back through the
//     same connection
//   - Auto-pull worker that fires PullCheques for the verified
//     expected_pieces[] and assembles the bundle
//
// The handler is split behind a protocol so Bucket 2/3 work can
// replace the stub without touching the socket layer at all.
// =================================================================

/// Maximum envelope size we'll accept on the wire — matches
/// axiom-uncle's MAX_ENVELOPE_BYTES so the two sides cap at the
/// same place. A reject-large-envelope happens at this boundary,
/// not deeper in the PGP / CBOR stack.
let UNCLE_SAM_MAX_ENVELOPE_BYTES: Int = 4 * 1024 * 1024

/// Handler invoked once a full PGP envelope has been framed off
/// the wire. The handler decides what to do with the bytes;
/// returning non-empty bytes from `handle(...)` causes the
/// listener to frame + write them back as the reply on the same
/// connection. Return `nil` or empty to close without replying
/// (used by the stub).
@MainActor
protocol UncleSamInboundHandler: AnyObject {
    func handle(envelopeBytes: Data, peer: String) async -> Data?
}

/// Logging-only stub handler. Bucket 2 + 3 replace this with the
/// real PGP-decode + unclesam-wire-decode + sender-signature-
/// verify + NotifyChequesAck-compose pipeline. The listener does
/// all the inbound-evidence tracking on its own @Published
/// properties so the UI observes the listener directly.
@MainActor
final class LoggingStubHandler: UncleSamInboundHandler {
    func handle(envelopeBytes: Data, peer: String) async -> Data? {
        let head = envelopeBytes.prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        NSLog("[unclesam.listener] inbound envelope: peer=\(peer) bytes=\(envelopeBytes.count) head=\(head)…")
        return nil
    }
}

/// Listener state surfaced to the Settings UI.
enum UncleSamListenerState: Equatable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

@MainActor
final class UncleSamListener: ObservableObject {

    @Published private(set) var state: UncleSamListenerState = .stopped
    @Published private(set) var connectionsAccepted: Int = 0
    @Published private(set) var envelopesReceived: Int = 0
    @Published private(set) var lastErrorAt: Date?
    @Published private(set) var lastError: String?
    /// Inbound-evidence fields — populated each time a full
    /// envelope frames off the wire. Visible in Settings → Network
    /// so the operator can confirm a remote bank's NotifyCheques
    /// actually landed. Bucket 2 + 3 add PGP/CBOR decoded fields
    /// alongside; these basics stay.
    @Published private(set) var lastInboundSize: Int = 0
    @Published private(set) var lastInboundPeer: String = ""
    @Published private(set) var lastInboundAt: Date?
    @Published private(set) var lastInboundFirstBytes: String = ""

    /// The current handler. Replaced when the PGP + wire layers
    /// land — the socket plumbing is unaware of the swap.
    private(set) var handler: UncleSamInboundHandler

    /// Background dispatch queue for NWListener + NWConnection
    /// callbacks. Per Apple docs: NWListener delivers state +
    /// new-connection callbacks here; each NWConnection inherits
    /// the same queue for its own state + receive callbacks.
    private let queue = DispatchQueue(
        label: "axiom.unclesam.listener",
        qos: .userInitiated)

    private var listener: NWListener?
    /// Holds NWConnection references alive for the duration of
    /// each in-flight envelope read. NWConnection is reference-
    /// counted; without this map the accept callback returns and
    /// the connection deallocates before bytes arrive.
    private var connectionBox: [ObjectIdentifier: NWConnection] = [:]

    init(handler: UncleSamInboundHandler) {
        self.handler = handler
    }

    /// Bind to the requested port and begin accepting. Idempotent:
    /// calling start() while running tears down the existing
    /// listener and rebinds (e.g. after the port-config field
    /// changes in Settings).
    func start(port: UInt16) {
        stop()
        state = .starting
        do {
            let params = NWParameters.tcp
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                state = .failed("invalid port \(port)")
                return
            }
            let listener = try NWListener(using: params, on: nwPort)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] newState in
                DispatchQueue.main.async {
                    self?.applyListenerState(newState, requestedPort: port)
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                DispatchQueue.main.async {
                    self?.accept(conn)
                }
            }
            listener.start(queue: queue)
        } catch {
            state = .failed("bind \(port): \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, c) in connectionBox { c.cancel() }
        connectionBox.removeAll()
        state = .stopped
    }

    private func applyListenerState(_ newState: NWListener.State,
                                     requestedPort: UInt16) {
        switch newState {
        case .ready:
            state = .running(port: requestedPort)
        case .failed(let err):
            state = .failed("listener failed: \(err.localizedDescription)")
        case .cancelled:
            // stop() owns the .stopped transition; cancelled may
            // also fire mid-rebind, in which case we ignore.
            break
        default:
            break
        }
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        connectionBox[id] = conn
        connectionsAccepted += 1
        let peer = endpointString(conn.endpoint)
        conn.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready:
                DispatchQueue.main.async {
                    self?.readFrame(conn, peer: peer)
                }
            case .failed(let e):
                DispatchQueue.main.async {
                    self?.finish(conn, error: "ready failed: \(e.localizedDescription)")
                }
            case .cancelled:
                DispatchQueue.main.async {
                    self?.finish(conn, error: nil)
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    /// Read one u32 BE length-prefix + payload from the wire.
    /// Matches axiom-uncle's listener byte layout exactly so the
    /// two sides interop.
    private func readFrame(_ conn: NWConnection, peer: String) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = error {
                    self.finish(conn, error: "read length: \(error.localizedDescription)")
                    return
                }
                guard let data = data, data.count == 4 else {
                    self.finish(conn, error: "short read on length prefix")
                    return
                }
                let length = data.withUnsafeBytes { raw -> UInt32 in
                    raw.load(as: UInt32.self).bigEndian
                }
                let asInt = Int(length)
                if asInt > UNCLE_SAM_MAX_ENVELOPE_BYTES {
                    self.finish(conn, error: "envelope too large: \(asInt) bytes (max \(UNCLE_SAM_MAX_ENVELOPE_BYTES))")
                    return
                }
                if asInt == 0 {
                    self.finish(conn, error: "zero-length envelope")
                    return
                }
                self.readPayload(conn, peer: peer, length: asInt)
            }
        }
    }

    private func readPayload(_ conn: NWConnection,
                              peer: String,
                              length: Int) {
        conn.receive(minimumIncompleteLength: length,
                     maximumLength: length) { [weak self] data, _, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = error {
                    self.finish(conn, error: "read payload: \(error.localizedDescription)")
                    return
                }
                guard let data = data, data.count == length else {
                    self.finish(conn, error: "short read on payload (\(data?.count ?? 0)/\(length))")
                    return
                }
                self.envelopesReceived += 1
                self.lastInboundSize = data.count
                self.lastInboundPeer = peer
                self.lastInboundAt = Date()
                self.lastInboundFirstBytes = data.prefix(16)
                    .map { String(format: "%02x", $0) }.joined()
                Task { @MainActor in
                    let reply = await self.handler.handle(envelopeBytes: data, peer: peer)
                    if let reply = reply, !reply.isEmpty {
                        self.writeFrame(conn, peer: peer, body: reply)
                    } else {
                        self.finish(conn, error: nil)
                    }
                }
            }
        }
    }

    /// Frame + write `body` as the reply on the same connection.
    /// Bucket 1 doesn't reach here (the stub always returns nil),
    /// but Bucket 3 will: NotifyChequesAck encoded as CBOR, signed
    /// + encrypted via axiom-pgp-envelope, framed back through
    /// this path.
    private func writeFrame(_ conn: NWConnection,
                             peer: String,
                             body: Data) {
        if body.count > UNCLE_SAM_MAX_ENVELOPE_BYTES {
            finish(conn, error: "reply too large: \(body.count)")
            return
        }
        var frame = Data()
        var lenBE = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &lenBE) { frame.append(contentsOf: $0) }
        frame.append(body)
        conn.send(content: frame, completion: .contentProcessed { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.finish(conn, error: "write reply: \(error.localizedDescription)")
                } else {
                    self?.finish(conn, error: nil)
                }
            }
        })
    }

    private func finish(_ conn: NWConnection, error: String?) {
        if let error = error {
            lastError = error
            lastErrorAt = Date()
            NSLog("[unclesam.listener] connection error: \(error)")
        }
        conn.cancel()
        let id = ObjectIdentifier(conn)
        connectionBox.removeValue(forKey: id)
    }

    private func endpointString(_ ep: NWEndpoint) -> String {
        switch ep {
        case .hostPort(let host, let port):
            return "\(host):\(port.rawValue)"
        case .service(let name, _, _, _):
            return name
        case .unix(let path):
            return path
        case .url(let u):
            return u.absoluteString
        @unknown default:
            return "<unknown>"
        }
    }
}
