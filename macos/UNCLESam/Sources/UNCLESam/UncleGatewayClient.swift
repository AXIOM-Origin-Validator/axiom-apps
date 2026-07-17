import Foundation
import Network
import SwiftUI
import AxiomSdk

// =================================================================
// UncleGatewayClient — Bucket 4 — Mac UNCLE SAM as a client of
// validator UNCLE gateways.
//
// This is the PRODUCTION-DIRECTION flow Linux confirmed at the
// 2026-05-31 architectural correction:
//
//   Mac UNCLE SAM  ─PullCheques over PGP envelope─>  Linux UNCLE
//       (initiator)                                       (passive listener)
//
// UNCLE never dials out. Mac initiates every connection: open TCP
// to validator UNCLE :9301, wrap a UncleMessage::Status or
// ::PullCheques in a PGP envelope addressed to the UNCLE operator's
// pubkey, frame with u32 BE length-prefix, send, read framed
// response, unwrap + verify, CBOR-decode the *Response variant.
// One request per connection (Phase 1 contract).
//
// Wire types mirror axiom-uncle/src/wire.rs post-50b7058d
// (receiver_wallet / sender_wallet are String in canonical
// email-form, not [u8; 32] pubkey bytes).
//
// `#[serde(tag = "t")]` on UncleMessage means the inner CBOR
// flattens the variant fields alongside a "t" tag string:
//
//   Status   {}                           → {"t": "Status"}
//   PullCheques { since_tick, … }         → {"t": "PullCheques",
//                                             "since_tick": …, … }
//
// =================================================================

/// Wire-aligned with `axiom_uncle::wire::StatusResponse`.
struct UncleStatusResponse {
    let version: String
    let uptimeSecs: UInt64
    let pendingOutbound: UInt32
    let pendingInbound: UInt32
    let auditChainTip: Data  // 32 bytes
}

/// Wire-aligned with `axiom_uncle::wire::InboundCheque` post-50b7058d.
struct UncleInboundCheque: Identifiable {
    let id: UUID = UUID()
    let txid: Data              // 32 bytes
    let receiverWallet: String  // canonical email-form
    let senderWallet: String    // canonical email-form
    let amountAtoms: UInt64
    let receivedAtTick: UInt64
    let chequeBlob: Data        // raw CBOR cheque blob
    let validatorIds: [Data]    // k 32-byte validator IDs

    var txidHex: String {
        txid.map { String(format: "%02x", $0) }.joined()
    }
}

/// Wire-aligned with `axiom_uncle::wire::PullChequesResponse`.
struct UnclePullChequesResponse {
    let cheques: [UncleInboundCheque]
    let moreAvailable: Bool
    /// `code` + `message` when the daemon returned a typed error
    /// rather than a populated cheques list.
    let error: UncleErrorBody?
}

struct UncleErrorBody {
    let code: String
    let message: String
}

/// Failure cases raised by the client.
enum UncleGatewayError: Error, LocalizedError {
    case operatorKeyNotLoaded
    case targetPubkeyMissing
    case connectionFailed(String)
    case framingError(String)
    case envelopeError(String)
    case decodeError(String)
    case unexpectedVariant(String)
    case daemonError(UncleErrorBody)

    var errorDescription: String? {
        switch self {
        case .operatorKeyNotLoaded:
            return "Operator PGP key not loaded — configure in Settings → Cryptographic keys"
        case .targetPubkeyMissing:
            return "Validator UNCLE PGP public key not configured"
        case .connectionFailed(let m): return "TCP: \(m)"
        case .framingError(let m): return "Wire framing: \(m)"
        case .envelopeError(let m): return "PGP envelope: \(m)"
        case .decodeError(let m): return "CBOR decode: \(m)"
        case .unexpectedVariant(let v):
            return "UNCLE returned unexpected variant: \(v)"
        case .daemonError(let body):
            return "UNCLE error \(body.code): \(body.message)"
        }
    }
}

/// Observable smoke-driver for Mac → Linux UNCLE. The same client
/// will back the production pull worker once the smoke validates.
@MainActor
final class UncleGatewayClient: ObservableObject {

    @Published private(set) var lastStatus: UncleStatusResponse?
    @Published private(set) var lastPullResponse: UnclePullChequesResponse?
    @Published private(set) var lastError: UncleGatewayError?
    @Published private(set) var inFlight: Bool = false
    /// Count of NEW cheques the last PullCheques call ingested into
    /// MessageStore (excluding dedup matches). Visible in the
    /// gateway card so the operator sees the Inbox-side effect.
    @Published private(set) var lastIngestedCount: Int = 0

    /// PGP handler holds the operator key — wrap / unwrap calls
    /// route through it.
    private let pgpHandler: PgpEnvelopeHandler
    /// Weak reference to the shared MessageStore — bound at App
    /// init so successful PullCheques can post received cheques
    /// to the Inbox tab.
    weak var messageStore: MessageStore?

    init(pgpHandler: PgpEnvelopeHandler) {
        self.pgpHandler = pgpHandler
    }

    // ─── Public smoke methods ───────────────────────────────────

    /// One round-trip: open TCP, wrap a Status request, read +
    /// unwrap the StatusResponse, close.
    func status(endpoint: String, targetPubkeyArmored: String) async {
        await runRoundTrip(endpoint: endpoint,
                           targetPubkeyArmored: targetPubkeyArmored,
                           request: encodeStatusRequest(),
                           expectedTag: "StatusResponse") { decodedMap in
            self.lastStatus = try Self.decodeStatusResponse(decodedMap)
            self.lastPullResponse = nil
        }
    }

    /// One round-trip: open TCP, wrap a PullCheques request, read
    /// + unwrap the PullChequesResponse, close. On success ingests
    /// the response cheques into MessageStore (deduped by txid) so
    /// they surface in the Inbox tab.
    func pullCheques(endpoint: String,
                      targetPubkeyArmored: String,
                      sinceTick: UInt64 = 0,
                      walletFilter: [String]? = nil,
                      maxRows: UInt32 = 100) async {
        await runRoundTrip(
            endpoint: endpoint,
            targetPubkeyArmored: targetPubkeyArmored,
            request: encodePullChequesRequest(sinceTick: sinceTick,
                                               walletFilter: walletFilter,
                                               maxRows: maxRows),
            expectedTag: "PullChequesResponse"
        ) { decodedMap in
            let response = try Self.decodePullChequesResponse(decodedMap)
            self.lastPullResponse = response
            self.lastStatus = nil
            // Ingest into MessageStore — Inbox tab picks them up
            // via store.inbound(). Dedup is by txid hex so re-
            // running PullCheques before UNCLE marks the rows
            // served is idempotent.
            if let store = self.messageStore {
                self.lastIngestedCount = store.ingestReceivedCheques(
                    response.cheques)
            } else {
                self.lastIngestedCount = 0
            }
        }
    }

    // ─── Round-trip plumbing ────────────────────────────────────

    /// Shared driver: PGP-wrap → frame → send → read frame →
    /// unwrap → CBOR-decode → branch on tag. Errors and result
    /// surface in `@Published` properties for the UI to bind.
    private func runRoundTrip(
        endpoint: String,
        targetPubkeyArmored: String,
        request innerCbor: Data,
        expectedTag: String,
        applyDecoded: @MainActor (CborValue) throws -> Void
    ) async {
        inFlight = true
        lastError = nil
        defer { inFlight = false }

        // 1. Sanity: operator key must be loaded for the wrap.
        guard let operatorKey = pgpHandler.borrowOperatorKey() else {
            self.lastError = .operatorKeyNotLoaded
            return
        }
        guard !targetPubkeyArmored.isEmpty,
              let recipientPubkey = targetPubkeyArmored.data(using: .utf8)
        else {
            self.lastError = .targetPubkeyMissing
            return
        }

        // 2. Wrap the inner CBOR.
        let envelopeBytes: Data
        do {
            envelopeBytes = try sdkPgpEnvelopeWrap(
                operatorKey: operatorKey,
                recipientPubkeyArmored: recipientPubkey,
                payload: innerCbor)
        } catch {
            self.lastError = .envelopeError("wrap: \(error.localizedDescription)")
            return
        }

        // 3. TCP round-trip.
        let replyBytes: Data
        do {
            replyBytes = try await tcpRoundTrip(endpoint: endpoint,
                                                 framedRequest: envelopeBytes)
        } catch let e as UncleGatewayError {
            self.lastError = e
            return
        } catch {
            self.lastError = .connectionFailed(error.localizedDescription)
            return
        }

        // 4. Unwrap reply. Sender-side pubkey is the same UNCLE
        //    pubkey we encrypted to.
        let verified: FfiVerifiedEnvelope
        do {
            verified = try sdkPgpEnvelopeUnwrap(
                operatorKey: operatorKey,
                senderPubkeyArmored: recipientPubkey,
                envelopeBytes: replyBytes)
        } catch {
            self.lastError = .envelopeError("unwrap: \(error.localizedDescription)")
            return
        }

        // 5. CBOR-decode the inner reply.
        let value: CborValue
        do {
            value = try CborValue.decode(Data(verified.payload))
        } catch {
            self.lastError = .decodeError(error.localizedDescription)
            return
        }
        guard case .map(let pairs) = value else {
            self.lastError = .decodeError("response: expected map at root")
            return
        }
        let lookup = Self.mapAsLookup(pairs)

        // 6. Internally-tagged enum — find "t" and dispatch.
        guard case .some(.text(let tag)) = lookup["t"] else {
            self.lastError = .decodeError("response: missing 't' tag")
            return
        }
        if tag != expectedTag {
            self.lastError = .unexpectedVariant(tag)
            return
        }
        do {
            try applyDecoded(value)
        } catch let e as UncleGatewayError {
            self.lastError = e
        } catch {
            self.lastError = .decodeError(error.localizedDescription)
        }
    }

    /// Open one TCP connection to `endpoint` ("host:port"), write
    /// the u32 BE length-prefixed `framedRequest`, read one u32 BE
    /// length-prefixed reply, close.
    private func tcpRoundTrip(endpoint: String,
                               framedRequest: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let parts = endpoint.split(separator: ":")
            guard parts.count == 2,
                  let port = UInt16(parts[1])
            else {
                cont.resume(throwing: UncleGatewayError.connectionFailed("endpoint must be host:port"))
                return
            }
            let host = String(parts[0])
            let nwHost = NWEndpoint.Host(host)
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                cont.resume(throwing: UncleGatewayError.connectionFailed("invalid port \(port)"))
                return
            }
            let queue = DispatchQueue(label: "uncle.gateway.client.\(host)",
                                       qos: .userInitiated)
            let conn = NWConnection(host: nwHost,
                                     port: nwPort,
                                     using: .tcp)
            var resumed = false
            let resumeOnce: (Result<Data, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                conn.cancel()
                switch result {
                case .success(let d): cont.resume(returning: d)
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Self.sendAndReadReply(conn: conn,
                                           framedRequest: framedRequest,
                                           resume: resumeOnce)
                case .failed(let err):
                    resumeOnce(.failure(UncleGatewayError.connectionFailed(
                        err.localizedDescription)))
                case .cancelled:
                    // Either we cancelled after success, or peer
                    // closed early. If we haven't resumed yet,
                    // surface as connection failure.
                    resumeOnce(.failure(UncleGatewayError.connectionFailed(
                        "connection cancelled before reply")))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    /// Helper running on the NWConnection's queue: frame + send the
    /// request, then read the response frame, then resume.
    /// Nonisolated because it runs on the connection's dispatch
    /// queue (not MainActor); it touches no actor-isolated state.
    nonisolated private static func sendAndReadReply(
        conn: NWConnection,
        framedRequest body: Data,
        resume: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        // Send frame
        var frame = Data()
        var lenBE = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &lenBE) { frame.append(contentsOf: $0) }
        frame.append(body)
        conn.send(content: frame,
                  completion: .contentProcessed { error in
            if let error = error {
                resume(.failure(UncleGatewayError.connectionFailed(
                    "send: \(error.localizedDescription)")))
                return
            }
            // Read reply length prefix
            conn.receive(minimumIncompleteLength: 4,
                         maximumLength: 4) { lenData, _, _, lenErr in
                if let lenErr = lenErr {
                    resume(.failure(UncleGatewayError.connectionFailed(
                        "read reply length: \(lenErr.localizedDescription)")))
                    return
                }
                guard let lenData = lenData, lenData.count == 4 else {
                    resume(.failure(UncleGatewayError.framingError(
                        "short read on reply length prefix")))
                    return
                }
                let replyLen = lenData.withUnsafeBytes { raw -> UInt32 in
                    raw.load(as: UInt32.self).bigEndian
                }
                let n = Int(replyLen)
                if n == 0 || n > UNCLE_SAM_MAX_ENVELOPE_BYTES {
                    resume(.failure(UncleGatewayError.framingError(
                        "reply length \(n) out of range")))
                    return
                }
                conn.receive(minimumIncompleteLength: n,
                             maximumLength: n) { body, _, _, bodyErr in
                    if let bodyErr = bodyErr {
                        resume(.failure(UncleGatewayError.connectionFailed(
                            "read reply body: \(bodyErr.localizedDescription)")))
                        return
                    }
                    guard let body = body, body.count == n else {
                        resume(.failure(UncleGatewayError.framingError(
                            "short read on reply body")))
                        return
                    }
                    resume(.success(body))
                }
            }
        })
    }

    // ─── Encode requests ────────────────────────────────────────

    /// Internally-tagged Status request: `{"t": "Status"}`.
    private func encodeStatusRequest() -> Data {
        let map = CborValue.map([
            (.text("t"), .text("Status")),
        ])
        return map.encode()
    }

    /// Internally-tagged PullCheques request:
    /// `{"t": "PullCheques", "since_tick": N, "wallet_filter":
    ///   null|[...], "max_rows": N}`.
    private func encodePullChequesRequest(sinceTick: UInt64,
                                           walletFilter: [String]?,
                                           maxRows: UInt32) -> Data {
        var pairs: [(CborValue, CborValue)] = [
            (.text("t"), .text("PullCheques")),
            (.text("since_tick"), .uint(sinceTick)),
        ]
        if let wf = walletFilter {
            pairs.append((.text("wallet_filter"),
                          .array(wf.map { .text($0) })))
        } else {
            pairs.append((.text("wallet_filter"), .null))
        }
        pairs.append((.text("max_rows"), .uint(UInt64(maxRows))))
        return CborValue.map(pairs).encode()
    }

    // ─── Decode responses ───────────────────────────────────────

    private static func mapAsLookup(_ pairs: [(CborValue, CborValue)])
        -> [String: CborValue] {
        var out: [String: CborValue] = [:]
        out.reserveCapacity(pairs.count)
        for (k, v) in pairs {
            if case .text(let s) = k { out[s] = v }
        }
        return out
    }

    private static func decodeStatusResponse(_ value: CborValue) throws
        -> UncleStatusResponse {
        guard case .map(let pairs) = value else {
            throw UncleGatewayError.decodeError("StatusResponse: expected map")
        }
        let m = mapAsLookup(pairs)
        return UncleStatusResponse(
            version: try requireText(m, "version"),
            uptimeSecs: try requireUint(m, "uptime_secs"),
            pendingOutbound: UInt32(try requireUint(m, "pending_outbound")),
            pendingInbound: UInt32(try requireUint(m, "pending_inbound")),
            auditChainTip: try requireBytes(m, "audit_chain_tip"))
    }

    private static func decodePullChequesResponse(_ value: CborValue) throws
        -> UnclePullChequesResponse {
        guard case .map(let pairs) = value else {
            throw UncleGatewayError.decodeError("PullChequesResponse: expected map")
        }
        let m = mapAsLookup(pairs)
        guard case .some(.array(let chequeNodes)) = m["cheques"] else {
            throw UncleGatewayError.decodeError("missing/non-array cheques")
        }
        let cheques = try chequeNodes.map { try decodeInboundCheque($0) }
        let moreAvailable: Bool
        if case .some(.bool(let b)) = m["more_available"] {
            moreAvailable = b
        } else {
            moreAvailable = false
        }
        var error: UncleErrorBody? = nil
        if case .some(.map(let errPairs)) = m["error"] {
            let em = mapAsLookup(errPairs)
            error = UncleErrorBody(
                code: (try? requireText(em, "code")) ?? "",
                message: (try? requireText(em, "message")) ?? "")
        }
        return UnclePullChequesResponse(
            cheques: cheques,
            moreAvailable: moreAvailable,
            error: error)
    }

    private static func decodeInboundCheque(_ value: CborValue) throws
        -> UncleInboundCheque {
        guard case .map(let pairs) = value else {
            throw UncleGatewayError.decodeError("InboundCheque: expected map")
        }
        let m = mapAsLookup(pairs)
        let validatorIds: [Data]
        if case .some(.array(let nodes)) = m["validator_ids"] {
            validatorIds = try nodes.map {
                guard case .bytes(let b) = $0 else {
                    if case .array(let arr) = $0 {
                        return Data(arr.compactMap { item -> UInt8? in
                            if case .uint(let i) = item, i <= 255 {
                                return UInt8(i)
                            }
                            return nil
                        })
                    }
                    throw UncleGatewayError.decodeError(
                        "validator_ids element: expected bytes/array")
                }
                return b
            }
        } else {
            validatorIds = []
        }
        return UncleInboundCheque(
            txid: try requireBytes(m, "txid"),
            receiverWallet: try requireText(m, "receiver_wallet"),
            senderWallet: try requireText(m, "sender_wallet"),
            amountAtoms: try requireUint(m, "amount_atoms"),
            receivedAtTick: try requireUint(m, "received_at_tick"),
            chequeBlob: try requireBytes(m, "cheque_blob"),
            validatorIds: validatorIds)
    }

    // ─── Small field accessors ──────────────────────────────────

    private static func requireText(_ m: [String: CborValue],
                                     _ key: String) throws -> String {
        guard let v = m[key], case .text(let s) = v else {
            throw UncleGatewayError.decodeError("missing/non-text: \(key)")
        }
        return s
    }
    private static func requireUint(_ m: [String: CborValue],
                                     _ key: String) throws -> UInt64 {
        guard let v = m[key], case .uint(let n) = v else {
            throw UncleGatewayError.decodeError("missing/non-uint: \(key)")
        }
        return n
    }
    private static func requireBytes(_ m: [String: CborValue],
                                      _ key: String) throws -> Data {
        guard let v = m[key] else {
            throw UncleGatewayError.decodeError("missing: \(key)")
        }
        switch v {
        case .bytes(let b): return b
        case .array(let arr):
            return Data(arr.compactMap { item -> UInt8? in
                if case .uint(let i) = item, i <= 255 {
                    return UInt8(i)
                }
                return nil
            })
        default:
            throw UncleGatewayError.decodeError("non-bytes: \(key)")
        }
    }
}

