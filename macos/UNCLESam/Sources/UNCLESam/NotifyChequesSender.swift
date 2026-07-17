import Foundation
import Network
import CryptoKit
import AxiomSdk

// =================================================================
// NotifyChequesSender — outbound side of the UNCLE SAM ↔ UNCLE SAM
// peer wire (Bucket 5 / step (a)).
//
//   Mac UNCLE SAM (sender)
//     → compose FfiNotifyCheques
//     → canonical_bytes via FFI helper
//     → ed25519-sign with Mac's operator ed25519 secret
//     → set sender_signature
//     → CBOR-encode the full struct
//     → PGP-wrap with operator key encrypting to peer's PGP pubkey
//     → u32-BE-frame + TCP-send to peer UNCLE SAM at :9090
//     → read framed reply
//     → PGP-unwrap (peer signs + encrypts the ack back)
//     → CBOR-decode NotifyChequesAck
//
// For loopback self-send testing the peer endpoint is the SAME
// process — sender and recipient PGP keys are both Mac's operator
// key. CounterpartyDirectory.selfEntry provides the receive-side
// verify against Mac's own fingerprint + ed25519 pubkey.
// =================================================================

/// Result body matching `axiom_unclesam_wire::NotifyChequesAck`:
///   `{ status: "Accepted" | "Rejected", reason: Option<String> }`.
struct NotifyChequesAckResult {
    enum Status: String { case accepted = "Accepted"
                          case rejected = "Rejected" }
    let status: Status
    let reason: String?
}

@MainActor
final class NotifyChequesSender: ObservableObject {

    @Published private(set) var sending: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastAck: NotifyChequesAckResult?
    @Published private(set) var lastSentAt: Date?
    @Published private(set) var lastBundleIdHex: String?

    private let pgpHandler: PgpEnvelopeHandler

    init(pgpHandler: PgpEnvelopeHandler) {
        self.pgpHandler = pgpHandler
    }

    /// Compose + sign + send a NotifyCheques to a peer UNCLE SAM.
    /// All fields are operator-supplied except cheque_bundle_id
    /// (random 32 bytes per call) and issued_at_wall_ns (now).
    func send(
        senderWalletId: String,
        receiverWalletId: String,
        amountAtoms: UInt64,
        swiftReference: String,
        expectedPieces: [(validatorId: Data, uncleEndpoint: String)],
        ed25519SecretBytes: Data,
        recipientPubkeyArmored: String,
        targetEndpoint: String
    ) async {
        sending = true
        lastError = nil
        lastAck = nil
        lastBundleIdHex = nil
        defer { sending = false }

        // 1. Sanity checks.
        guard let operatorKey = pgpHandler.borrowOperatorKey() else {
            lastError = "Operator PGP key not loaded"
            return
        }
        guard ed25519SecretBytes.count == 32 else {
            lastError = "ed25519 secret must be 32 raw bytes, got \(ed25519SecretBytes.count)"
            return
        }
        guard !recipientPubkeyArmored.isEmpty,
              let recipientPubkeyData = recipientPubkeyArmored.data(using: .utf8)
        else {
            lastError = "Recipient PGP pubkey missing or non-UTF8"
            return
        }

        // 2. Generate cheque_bundle_id (32 random bytes). In real
        //    sends this is BLAKE3 over the cheque-piece manifest;
        //    for the peer-wire test it's any unique 32-byte id.
        var bundleIdBytes = [UInt8](repeating: 0, count: 32)
        let rc = SecRandomCopyBytes(kSecRandomDefault, 32, &bundleIdBytes)
        guard rc == errSecSuccess else {
            lastError = "Failed to generate random bundle id"
            return
        }
        let chequeBundleId = Data(bundleIdBytes)

        // 3. Build the FfiNotifyCheques (with zero-filled sig so
        //    canonical_bytes can validate field lengths). The
        //    helper IGNORES sender_signature in its canonical
        //    input; the placeholder is only there because the
        //    Swift struct requires it.
        let issuedAtWallNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let pieces = expectedPieces.map {
            FfiExpectedPiece(validatorId: $0.validatorId,
                             uncleEndpoint: $0.uncleEndpoint)
        }
        var msg = FfiNotifyCheques(
            chequeBundleId: chequeBundleId,
            senderWalletId: senderWalletId,
            receiverWalletId: receiverWalletId,
            amountAtoms: amountAtoms,
            expectedPieces: pieces,
            swiftReference: swiftReference,
            issuedAtWallNs: issuedAtWallNs,
            issuedAtTick: nil,
            senderSignature: Data(count: 64)
        )

        // 4. Compute canonical signing bytes via the FFI helper —
        //    single source of truth, never hand-rolled in Swift.
        let canonical: Data
        do {
            canonical = try unclesamWireNotifyChequesCanonicalBytes(msg: msg)
        } catch {
            lastError = "canonical_bytes failed: \(error.localizedDescription)"
            return
        }

        // 5. Ed25519-sign with Mac's operator ed25519 secret.
        let signature: Data
        do {
            let key = try Curve25519.Signing.PrivateKey(
                rawRepresentation: ed25519SecretBytes)
            signature = try key.signature(for: canonical)
        } catch {
            lastError = "ed25519 sign: \(error.localizedDescription)"
            return
        }
        guard signature.count == 64 else {
            lastError = "ed25519 signature wrong length \(signature.count)"
            return
        }
        msg.senderSignature = signature

        // 6. CBOR-encode the full struct (this is the wire format
        //    serde sees on the receiver side after PGP unwrap).
        let wireCbor = Self.encodeNotifyCheques(msg)

        // 7. PGP-wrap to the recipient.
        let envelopeBytes: Data
        do {
            envelopeBytes = try sdkPgpEnvelopeWrap(
                operatorKey: operatorKey,
                recipientPubkeyArmored: recipientPubkeyData,
                payload: wireCbor)
        } catch {
            lastError = "PGP wrap: \(error.localizedDescription)"
            return
        }

        // 8. TCP round-trip — frame, send, read framed reply.
        let replyBytes: Data
        do {
            replyBytes = try await Self.tcpRoundTrip(
                envelope: envelopeBytes,
                target: targetEndpoint)
        } catch {
            lastError = "TCP: \(error.localizedDescription)"
            return
        }

        // 9. PGP-unwrap the reply. The peer signs + encrypts the
        //    ack back to us using the same key pair; we verify
        //    against the same recipient pubkey we encrypted to.
        let verifiedReply: FfiVerifiedEnvelope
        do {
            verifiedReply = try sdkPgpEnvelopeUnwrap(
                operatorKey: operatorKey,
                senderPubkeyArmored: recipientPubkeyData,
                envelopeBytes: replyBytes)
        } catch {
            lastError = "Reply PGP unwrap: \(error.localizedDescription)"
            return
        }

        // 10. CBOR-decode the NotifyChequesAck.
        do {
            let ack = try Self.decodeAck(Data(verifiedReply.payload))
            self.lastAck = ack
            self.lastSentAt = Date()
            self.lastBundleIdHex = chequeBundleId
                .map { String(format: "%02x", $0) }.joined()
        } catch {
            lastError = "Ack CBOR decode: \(error.localizedDescription)"
            return
        }
    }

    // ─── CBOR encode FfiNotifyCheques (matches serde shape) ──────

    /// Encode `FfiNotifyCheques` as CBOR matching
    /// `axiom_unclesam_wire::NotifyCheques`'s serde output. Field
    /// keys are the snake_case Rust names; byte arrays emit as CBOR
    /// bstr (matches `serde-cbor`'s default for `[u8; N]`).
    static func encodeNotifyCheques(_ msg: FfiNotifyCheques) -> Data {
        var pairs: [(CborValue, CborValue)] = []
        pairs.append((.text("cheque_bundle_id"), .bytes(msg.chequeBundleId)))
        pairs.append((.text("sender_wallet_id"), .text(msg.senderWalletId)))
        pairs.append((.text("receiver_wallet_id"), .text(msg.receiverWalletId)))
        pairs.append((.text("amount_atoms"), .uint(msg.amountAtoms)))
        let pieceItems = msg.expectedPieces.map { piece -> CborValue in
            return .map([
                (.text("validator_id"), .bytes(piece.validatorId)),
                (.text("uncle_endpoint"), .text(piece.uncleEndpoint)),
            ])
        }
        pairs.append((.text("expected_pieces"), .array(pieceItems)))
        pairs.append((.text("swift_reference"), .text(msg.swiftReference)))
        // i64 — encode negative as nint, non-negative as uint.
        if msg.issuedAtWallNs >= 0 {
            pairs.append((.text("issued_at_wall_ns"),
                          .uint(UInt64(msg.issuedAtWallNs))))
        } else {
            pairs.append((.text("issued_at_wall_ns"),
                          .nint(msg.issuedAtWallNs)))
        }
        if let tick = msg.issuedAtTick {
            pairs.append((.text("issued_at_tick"), .uint(tick)))
        } else {
            pairs.append((.text("issued_at_tick"), .null))
        }
        pairs.append((.text("sender_signature"), .bytes(msg.senderSignature)))
        return CborValue.map(pairs).encode()
    }

    // ─── CBOR decode NotifyChequesAck ────────────────────────────

    static func decodeAck(_ bytes: Data) throws -> NotifyChequesAckResult {
        let value = try CborValue.decode(bytes)
        guard case .map(let pairs) = value else {
            throw CborError.message("Ack: expected CBOR map at root")
        }
        var statusText: String?
        var reason: String?
        for (k, v) in pairs {
            guard case .text(let key) = k else { continue }
            switch key {
            case "status":
                if case .text(let s) = v { statusText = s }
            case "reason":
                if case .text(let s) = v { reason = s }
                // .null leaves reason nil
            default:
                break
            }
        }
        guard let s = statusText,
              let status = NotifyChequesAckResult.Status(rawValue: s)
        else {
            throw CborError.message("Ack: missing or unknown status")
        }
        return NotifyChequesAckResult(status: status, reason: reason)
    }

    // ─── TCP round-trip (mirrors UncleGatewayClient) ─────────────

    nonisolated static func tcpRoundTrip(envelope: Data,
                                          target: String) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let parts = target.split(separator: ":")
            guard parts.count == 2, let port = UInt16(parts[1]) else {
                cont.resume(throwing: NSError(
                    domain: "NotifyChequesSender",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "endpoint must be host:port"]))
                return
            }
            let host = String(parts[0])
            let queue = DispatchQueue(
                label: "unclesam.notify.send.\(host)",
                qos: .userInitiated)
            let conn = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
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
                    var frame = Data()
                    var lenBE = UInt32(envelope.count).bigEndian
                    withUnsafeBytes(of: &lenBE) { frame.append(contentsOf: $0) }
                    frame.append(envelope)
                    conn.send(content: frame, completion: .contentProcessed { e in
                        if let e = e {
                            resumeOnce(.failure(e)); return
                        }
                        conn.receive(minimumIncompleteLength: 4,
                                     maximumLength: 4) { d, _, _, err in
                            if let err = err { resumeOnce(.failure(err)); return }
                            guard let d = d, d.count == 4 else {
                                resumeOnce(.failure(NSError(
                                    domain: "NotifyChequesSender", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "short reply length"])))
                                return
                            }
                            let n = Int(d.withUnsafeBytes { raw -> UInt32 in
                                raw.load(as: UInt32.self).bigEndian
                            })
                            if n == 0 || n > UNCLE_SAM_MAX_ENVELOPE_BYTES {
                                resumeOnce(.failure(NSError(
                                    domain: "NotifyChequesSender", code: 3,
                                    userInfo: [NSLocalizedDescriptionKey:
                                        "bad reply length \(n)"])))
                                return
                            }
                            conn.receive(minimumIncompleteLength: n,
                                         maximumLength: n) { d2, _, _, e2 in
                                if let e2 = e2 { resumeOnce(.failure(e2)); return }
                                guard let d2 = d2, d2.count == n else {
                                    resumeOnce(.failure(NSError(
                                        domain: "NotifyChequesSender", code: 4,
                                        userInfo: [NSLocalizedDescriptionKey:
                                            "short reply body"])))
                                    return
                                }
                                resumeOnce(.success(d2))
                            }
                        }
                    })
                case .failed(let e):
                    resumeOnce(.failure(e))
                case .cancelled:
                    resumeOnce(.failure(NSError(
                        domain: "NotifyChequesSender", code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "connection cancelled"])))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }
}
