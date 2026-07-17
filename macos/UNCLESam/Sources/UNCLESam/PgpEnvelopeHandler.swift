import Foundation
import AxiomSdk

// =================================================================
// PgpEnvelopeHandler — Bucket 2 + 3 of the UNCLE SAM peer wire.
//
// Replaces LoggingStubHandler in UncleSamListener. Implements the
// full inbound pipeline that Linux laid out:
//
//   1. envelope_bytes (raw u32-BE-framed payload off the wire)
//   2. → sdkPgpEnvelopePeekSigner(operator_key, envelope_bytes)
//        → fingerprint (hex)
//   3. → CounterpartyStore.byPgpFingerprint(fingerprint)
//        → Counterparty (transport-layer identity bound)
//   4. → sdkPgpEnvelopeUnwrap(operator_key, sender_pgp_pubkey,
//                              envelope_bytes)
//        → FfiVerifiedEnvelope { payload, fingerprint, email }
//   5. → ciborium-decode payload into FfiNotifyCheques (Bucket 3)
//   6. → unclesamWireNotifyChequesCanonicalBytes(msg) → canonical
//   7. → ed25519-verify(canonical, sender_signature,
//                       counterparty.operatorEd25519PubkeyHex)
//        → Transaction-level intent confirmed
//   8. → publish ReceivedNotifyCheques to NotifyChequesInbox so
//        the future pull worker (Bucket 4) can fire PullCheques
//        against each expected_pieces[].uncle_endpoint
//   9. → compose NotifyChequesAck { Accepted }
//  10. → ciborium-encode ack → bytes
//  11. → sdkPgpEnvelopeWrap(operator_key, sender_pgp_pubkey, bytes)
//        → reply envelope
//  12. return reply bytes — UncleSamListener frames + writes back
//
// Any step that fails returns a NotifyChequesAck { Rejected, reason }
// PGP-wrapped to the same sender. That way the sender always
// receives a typed reply on the same TCP connection — never a bare
// close or timeout that's hard to diagnose at 2 AM.
// =================================================================

/// Inbox slot for a received + verified NotifyCheques. Bucket 4
/// (pull worker) reads this list to know what to PullCheques.
/// Lives in this module rather than MessageStore because the
/// pull worker is a sibling concern, not part of the existing
/// SWIFT/wire authorisation pipeline.
@MainActor
final class NotifyChequesInbox: ObservableObject {
    struct Entry: Identifiable {
        let id: UUID = UUID()
        let receivedAt: Date
        let senderPgpFingerprint: String
        let senderEmail: String
        let counterpartyName: String
        let notice: FfiNotifyCheques
    }
    @Published private(set) var entries: [Entry] = []

    func append(_ entry: Entry) {
        // Newest first so the Settings card / future Inbox view
        // shows the most recent on top.
        entries.insert(entry, at: 0)
        // Cap at 100 so a misbehaving counterparty can't blow out
        // memory by flooding NotifyCheques.
        if entries.count > 100 {
            entries.removeLast(entries.count - 100)
        }
    }
}

/// Real PGP-envelope inbound handler. Operator key is loaded
/// post-construction via `loadOperatorKey(...)` so the app can
/// instantiate the handler at launch and let the operator load the
/// key from Settings (file path + optional passphrase).
@MainActor
final class PgpEnvelopeHandler: ObservableObject, UncleSamInboundHandler {

    /// Status of the operator key. UI binds to this to surface load
    /// state in Settings → Keys.
    enum KeyState: Equatable {
        case notLoaded
        case loaded(fingerprint: String)
        case failed(String)
    }

    @Published private(set) var keyState: KeyState = .notLoaded

    /// Held outside the published state so we can pass it to the
    /// FFI calls without copying out of an enum on every receive.
    private var operatorKey: FfiOperatorPgpKey?
    private let inbox: NotifyChequesInbox

    /// Weak reference to the outbound gateway client — auto-pull
    /// uses it to fire PullCheques against each
    /// expected_pieces[].uncle_endpoint after verification. Wired
    /// at App init (bilateral cycle: gateway client needs handler
    /// for its key; handler needs gateway client for auto-pull).
    weak var gatewayClient: UncleGatewayClient?

    init(inbox: NotifyChequesInbox) {
        self.inbox = inbox
    }

    /// Load the operator's PGP secret key from disk. Errors surface
    /// in `keyState` for the UI to display. Calling again with a
    /// different path swaps the key.
    func loadOperatorKey(path: String, passphrase: String?) {
        do {
            let key = try FfiOperatorPgpKey.load(path: path,
                                                  passphrase: passphrase)
            self.operatorKey = key
            self.keyState = .loaded(fingerprint: key.fingerprint())
        } catch {
            self.operatorKey = nil
            self.keyState = .failed(error.localizedDescription)
        }
    }

    /// Discard the loaded key. After this every inbound returns
    /// unrecoverable until the next load.
    func clearOperatorKey() {
        operatorKey = nil
        keyState = .notLoaded
    }

    /// Lend the loaded operator key to a sibling component (e.g.
    /// UncleGatewayClient for outbound PullCheques wrapping). Returns
    /// nil when the key isn't loaded. Mac always holds a single
    /// operator key; this is borrow-not-clone — the FFI side is an
    /// Arc-backed handle so passing the reference is cheap.
    func borrowOperatorKey() -> FfiOperatorPgpKey? {
        operatorKey
    }

    func handle(envelopeBytes: Data, peer: String) async -> Data? {
        // Try the whole pipeline; on any failure we still return a
        // sealed Rejected ack so the sender gets a typed reply on
        // the same connection.
        let outcome = decodeAndVerify(envelopeBytes: envelopeBytes,
                                       peer: peer)
        switch outcome {
        case .accepted(let entry, let recipientPubkey):
            inbox.append(entry)
            // Auto-pull — for each expected piece in the
            // NotifyCheques, fire PullCheques against that
            // validator UNCLE so the actual cheque pieces land in
            // MessageStore's Inbox. Empty expected_pieces means no
            // pulls (e.g. peer just told us "expect a payment
            // soon" without naming validators yet — fine).
            Task { @MainActor in
                await autoPullExpectedPieces(entry.notice.expectedPieces)
            }
            return composeAck(.accepted,
                              reason: nil,
                              recipientPubkey: recipientPubkey)
        case .rejected(let reason, let recipientPubkey):
            NSLog("[unclesam.pgp] rejected inbound from \(peer): \(reason)")
            return composeAck(.rejected,
                              reason: reason,
                              recipientPubkey: recipientPubkey)
        case .unrecoverable(let reason):
            // Couldn't even decode the outer envelope or peek the
            // signer — no recipient pubkey to encrypt the ack to.
            // Close the connection without replying.
            NSLog("[unclesam.pgp] unrecoverable on inbound from \(peer): \(reason)")
            return nil
        }
    }

    // ─── Step decomposition ──────────────────────────────────────

    private enum Outcome {
        case accepted(NotifyChequesInbox.Entry, recipientPubkey: Data)
        case rejected(reason: String, recipientPubkey: Data)
        case unrecoverable(reason: String)
    }

    private func decodeAndVerify(envelopeBytes: Data,
                                  peer: String) -> Outcome {
        // 0. Operator key must be loaded before we can decrypt
        //    anything. Without it there's no way to read the outer
        //    layer or compose a reply ack.
        guard let operatorKey = self.operatorKey else {
            return .unrecoverable(
                reason: "operator PGP key not loaded — configure in Settings → Keys")
        }

        // 1. Peek the signer fingerprint (decrypts outer with our
        //    operator key, returns the unverified signer ID).
        let fingerprint: String
        do {
            fingerprint = try sdkPgpEnvelopePeekSigner(
                operatorKey: operatorKey,
                envelopeBytes: envelopeBytes)
        } catch {
            return .unrecoverable(
                reason: "peek_signer: \(error.localizedDescription)")
        }

        // 2. Find the counterparty whose bilateral arrangement has
        //    that PGP fingerprint pinned. No counterparty = no
        //    pubkey to verify against = no ack to compose.
        guard let counterparty = CounterpartyStore.byPgpFingerprint(
                fingerprint)
        else {
            return .unrecoverable(
                reason: "unknown signer fingerprint \(fingerprint)")
        }

        // 3. Counterparty MUST have pgpPublicKey provisioned. If
        //    not, we can't verify outer signature AND we can't seal
        //    a reply ack back to them.
        guard !counterparty.pgpPublicKey.isEmpty,
              let recipientPubkey = counterparty.pgpPublicKey
                  .data(using: .utf8)
        else {
            return .unrecoverable(
                reason: "counterparty \(counterparty.name) has no PGP public key — provision via bilateral ceremony")
        }

        // 4. Full unwrap + verify outer signature against the
        //    counterparty's pinned pubkey.
        let verified: FfiVerifiedEnvelope
        do {
            verified = try sdkPgpEnvelopeUnwrap(
                operatorKey: operatorKey,
                senderPubkeyArmored: recipientPubkey,
                envelopeBytes: envelopeBytes)
        } catch {
            return .rejected(
                reason: "envelope verify: \(error.localizedDescription)",
                recipientPubkey: recipientPubkey)
        }

        // 5. CBOR-decode the verified payload into an
        //    FfiNotifyCheques. Bucket 3 — the verified payload is
        //    the inner CBOR bytes; we decode into the typed
        //    record uniffi generated.
        let notice: FfiNotifyCheques
        do {
            notice = try decodeNotifyChequesCbor(verified.payload)
        } catch {
            return .rejected(
                reason: "cbor decode: \(error.localizedDescription)",
                recipientPubkey: recipientPubkey)
        }

        // 6. Defense-in-depth: counterparty ed25519 pubkey must be
        //    provisioned. PGP envelope verify covers transport
        //    identity; ed25519 over canonical bytes covers
        //    Transaction-level intent. Refuse to accept unless
        //    BOTH halves verify.
        guard !counterparty.operatorEd25519PubkeyHex.isEmpty,
              let pubkeyBytes = Self.hexToData(counterparty.operatorEd25519PubkeyHex),
              pubkeyBytes.count == 32
        else {
            return .rejected(
                reason: "counterparty \(counterparty.name) has no operator ed25519 pubkey — provision via bilateral ceremony",
                recipientPubkey: recipientPubkey)
        }

        // 7. Compute canonical bytes via the shared FFI helper
        //    (single source of truth — Swift NEVER reconstructs
        //    the layout).
        let canonical: Data
        do {
            canonical = try unclesamWireNotifyChequesCanonicalBytes(
                msg: notice)
        } catch {
            return .rejected(
                reason: "canonical_bytes: \(error.localizedDescription)",
                recipientPubkey: recipientPubkey)
        }

        // 8. Ed25519-verify sender_signature against the
        //    counterparty's pinned operator pubkey.
        let sigData = Data(notice.senderSignature)
        guard sigData.count == 64 else {
            return .rejected(
                reason: "sender_signature length \(sigData.count) != 64",
                recipientPubkey: recipientPubkey)
        }
        guard Self.verifyEd25519(message: canonical,
                                  signature: sigData,
                                  publicKey: pubkeyBytes)
        else {
            return .rejected(
                reason: "sender_signature verify failed",
                recipientPubkey: recipientPubkey)
        }

        // 9. Verified end-to-end. Drop it in the inbox for the
        //    pull worker to pick up.
        let entry = NotifyChequesInbox.Entry(
            receivedAt: Date(),
            senderPgpFingerprint: verified.senderPgpFingerprint,
            senderEmail: verified.senderEmail,
            counterpartyName: counterparty.name,
            notice: notice)
        return .accepted(entry, recipientPubkey: recipientPubkey)
    }

    // ─── Auto-pull (Bucket 5(b)) ─────────────────────────────────

    /// For each `expected_piece`, fire a PullCheques against that
    /// validator UNCLE endpoint. The validator UNCLE PGP pubkey
    /// is read from @AppStorage: when an endpoint matches the
    /// configured `uncle.sam.gateway.endpoint`, the configured
    /// `uncle.sam.gateway.pubkey_armored` is used. Other endpoints
    /// fall back to "no pubkey — skip" with a clear NSLog. Future
    /// work: a proper validator-UNCLE registry keyed by validator_id
    /// or endpoint.
    private func autoPullExpectedPieces(_ pieces: [FfiExpectedPiece]) async {
        guard let gw = gatewayClient else {
            if !pieces.isEmpty {
                NSLog("[unclesam.autopull] no gatewayClient bound; skipping \(pieces.count) pieces")
            }
            return
        }
        if pieces.isEmpty {
            return
        }
        // Build a small endpoint → pubkey lookup table from
        // @AppStorage. Today this is a single-entry registry
        // matching the operator's primary validator. A bigger
        // deployment swaps this for a persisted per-validator
        // registry.
        let defaultEndpoint = UserDefaults.standard.string(
            forKey: "uncle.sam.gateway.endpoint") ?? ""
        let defaultPubkey = UserDefaults.standard.string(
            forKey: "uncle.sam.gateway.pubkey_armored") ?? ""
        var registry: [String: String] = [:]
        if !defaultEndpoint.isEmpty, !defaultPubkey.isEmpty {
            registry[defaultEndpoint] = defaultPubkey
        }
        NSLog("[unclesam.autopull] firing \(pieces.count) pull(s)")
        for (idx, piece) in pieces.enumerated() {
            let endpoint = piece.uncleEndpoint
            guard let pubkey = registry[endpoint] else {
                NSLog("[unclesam.autopull] piece[\(idx)]: no pubkey for \(endpoint) — skipping")
                continue
            }
            // PullCheques into MessageStore via gatewayClient. The
            // client's existing ingestReceivedCheques call dedups
            // by txid hex so re-pulling the same cheque across
            // multiple validators (which IS the k-of-n witness
            // shape) lands the cheque exactly once in the Inbox.
            await gw.pullCheques(endpoint: endpoint,
                                  targetPubkeyArmored: pubkey,
                                  sinceTick: 0,
                                  walletFilter: nil,
                                  maxRows: 100)
            if let err = gw.lastError {
                NSLog("[unclesam.autopull] piece[\(idx)] @ \(endpoint) FAIL: \(err.localizedDescription)")
            } else {
                let count = gw.lastPullResponse?.cheques.count ?? -1
                let ingested = gw.lastIngestedCount
                NSLog("[unclesam.autopull] piece[\(idx)] @ \(endpoint) OK rows=\(count) ingested=\(ingested)")
            }
        }
    }

    // ─── Ack composition ─────────────────────────────────────────

    private enum AckStatus { case accepted, rejected }

    /// Wire shape: `NotifyChequesAck { status: "Accepted"|"Rejected",
    /// reason: Option<String> }`. Encoded as CBOR map with text keys
    /// for cross-language compat; ciborium on the Rust side decodes
    /// into the canonical struct.
    private func composeAck(_ status: AckStatus,
                            reason: String?,
                            recipientPubkey: Data) -> Data? {
        // Guard mirrors decodeAndVerify(): if the key was cleared
        // between receive and ack-compose we can't wrap a reply.
        guard let operatorKey = self.operatorKey else { return nil }
        let ackCbor = encodeAckCbor(status: status, reason: reason)
        do {
            return try sdkPgpEnvelopeWrap(
                operatorKey: operatorKey,
                recipientPubkeyArmored: recipientPubkey,
                payload: ackCbor)
        } catch {
            NSLog("[unclesam.pgp] failed to wrap ack: \(error.localizedDescription)")
            return nil
        }
    }

    // ─── CBOR helpers ────────────────────────────────────────────

    /// Decode FfiNotifyCheques from CBOR bytes. Hand-written rather
    /// than via a Codable conformance because the uniffi-generated
    /// FfiNotifyCheques doesn't conform to Codable; we read the
    /// fields manually from the CBOR map.
    private func decodeNotifyChequesCbor(_ bytes: Data) throws
        -> FfiNotifyCheques
    {
        let value = try CborValue.decode(Data(bytes))
        guard case .map(let pairs) = value else {
            throw CborError.message("NotifyCheques: expected CBOR map at root")
        }
        let lookup = Dictionary(uniqueKeysWithValues: pairs.compactMap {
            (k, v) -> (String, CborValue)? in
            if case .text(let key) = k { return (key, v) }
            return nil
        })

        let chequeBundleId = try Self.requireBytes(lookup, key: "cheque_bundle_id")
        let senderWalletId = try Self.requireText(lookup, key: "sender_wallet_id")
        let receiverWalletId = try Self.requireText(lookup, key: "receiver_wallet_id")
        let amountAtoms = try Self.requireUint(lookup, key: "amount_atoms")
        let swiftReference = try Self.requireText(lookup, key: "swift_reference")
        let issuedAtWallNs = try Self.requireInt(lookup, key: "issued_at_wall_ns")
        let senderSignature = try Self.requireBytes(lookup, key: "sender_signature")

        // Optional fields
        let issuedAtTick: UInt64?
        if case .some(.uint(let t)) = lookup["issued_at_tick"] {
            issuedAtTick = t
        } else {
            issuedAtTick = nil
        }

        // expected_pieces is an array of maps
        guard case .array(let pieces) = lookup["expected_pieces"]
                                        ?? .array([]) else {
            throw CborError.message("expected_pieces: expected array")
        }
        let parsedPieces = try pieces.map { piece -> FfiExpectedPiece in
            guard case .map(let pairs) = piece else {
                throw CborError.message("expected_pieces[i]: expected map")
            }
            let pieceLookup = Dictionary(uniqueKeysWithValues: pairs.compactMap {
                (k, v) -> (String, CborValue)? in
                if case .text(let key) = k { return (key, v) }
                return nil
            })
            let validatorId = try Self.requireBytes(pieceLookup, key: "validator_id")
            let uncleEndpoint = try Self.requireText(pieceLookup, key: "uncle_endpoint")
            return FfiExpectedPiece(
                validatorId: validatorId,
                uncleEndpoint: uncleEndpoint)
        }

        return FfiNotifyCheques(
            chequeBundleId: chequeBundleId,
            senderWalletId: senderWalletId,
            receiverWalletId: receiverWalletId,
            amountAtoms: amountAtoms,
            expectedPieces: parsedPieces,
            swiftReference: swiftReference,
            issuedAtWallNs: issuedAtWallNs,
            issuedAtTick: issuedAtTick,
            senderSignature: senderSignature)
    }

    private func encodeAckCbor(status: AckStatus, reason: String?) -> Data {
        var pairs: [(CborValue, CborValue)] = []
        let statusText: String
        switch status {
        case .accepted: statusText = "Accepted"
        case .rejected: statusText = "Rejected"
        }
        pairs.append((.text("status"), .text(statusText)))
        if let reason = reason {
            pairs.append((.text("reason"), .text(reason)))
        } else {
            pairs.append((.text("reason"), .null))
        }
        return CborValue.map(pairs).encode()
    }

    // ─── Small static helpers ────────────────────────────────────

    private static func requireBytes(_ lookup: [String: CborValue],
                                      key: String) throws -> Data {
        guard let v = lookup[key] else {
            throw CborError.message("missing field: \(key)")
        }
        switch v {
        case .bytes(let b): return b
        case .array(let arr):
            // Some encoders write byte arrays as CBOR integer arrays.
            // Tolerate that round-trip.
            var out = Data()
            out.reserveCapacity(arr.count)
            for item in arr {
                if case .uint(let i) = item, i <= 255 {
                    out.append(UInt8(i))
                } else {
                    throw CborError.message(
                        "field \(key): array element not a byte")
                }
            }
            return out
        default:
            throw CborError.message("field \(key): expected bytes/array")
        }
    }

    private static func requireText(_ lookup: [String: CborValue],
                                     key: String) throws -> String {
        guard let v = lookup[key], case .text(let s) = v else {
            throw CborError.message("missing or non-text field: \(key)")
        }
        return s
    }

    private static func requireUint(_ lookup: [String: CborValue],
                                     key: String) throws -> UInt64 {
        guard let v = lookup[key], case .uint(let n) = v else {
            throw CborError.message("missing or non-uint field: \(key)")
        }
        return n
    }

    private static func requireInt(_ lookup: [String: CborValue],
                                    key: String) throws -> Int64 {
        guard let v = lookup[key] else {
            throw CborError.message("missing field: \(key)")
        }
        switch v {
        case .uint(let n):
            if n > UInt64(Int64.max) {
                throw CborError.message("field \(key): uint exceeds i64")
            }
            return Int64(n)
        case .nint(let n):
            // CBOR negative integers are encoded as -1 - n; n is the
            // unsigned-magnitude encoding. Our CborValue.nint holds
            // the original integer value directly.
            return n
        default:
            throw CborError.message("field \(key): expected int")
        }
    }

    /// Hex-string → Data. Tolerates upper/lower case, rejects
    /// non-hex chars or odd length.
    static func hexToData(_ hex: String) -> Data? {
        let cleaned = hex
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var out = Data()
        out.reserveCapacity(cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let byte = UInt8(cleaned[idx..<next], radix: 16) else {
                return nil
            }
            out.append(byte)
            idx = next
        }
        return out
    }

    /// Ed25519 signature verification via Apple's CryptoKit. Returns
    /// `false` for any failure path (bad key, bad sig, sig mismatch);
    /// the caller maps that to a Rejected ack.
    static func verifyEd25519(message: Data,
                               signature: Data,
                               publicKey: Data) -> Bool {
        // Lazy-import CryptoKit only when called — the rest of the
        // module works without it.
        guard publicKey.count == 32, signature.count == 64 else {
            return false
        }
        return CryptoKitBridge.ed25519Verify(
            publicKey: publicKey,
            signature: signature,
            message: message)
    }
}

// =================================================================
// CryptoKit bridge — isolates the `import CryptoKit` so the rest
// of this file stays Foundation-only.
// =================================================================

import CryptoKit

enum CryptoKitBridge {
    static func ed25519Verify(publicKey: Data,
                               signature: Data,
                               message: Data) -> Bool {
        do {
            let key = try Curve25519.Signing
                .PublicKey(rawRepresentation: publicKey)
            return key.isValidSignature(signature, for: message)
        } catch {
            return false
        }
    }
}

// =================================================================
// Hand-rolled minimal CBOR encoder/decoder for the Ack + NotifyCheques
// fields we touch. We don't use a third-party CBOR library to avoid
// adding a dependency for a single use site — the surface here is
// ~5 types (uint, nint, bytes, text, array, map, null, bool). When
// we add more inbound message types beyond NotifyCheques this gets
// replaced with SwiftCBOR or a uniffi-side decode helper.
// =================================================================

indirect enum CborValue {
    case uint(UInt64)
    case nint(Int64)     // negative integer, stored as actual signed value
    case bytes(Data)
    case text(String)
    case array([CborValue])
    case map([(CborValue, CborValue)])
    case null
    case bool(Bool)
}

enum CborError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

extension CborValue {
    // Encode — minimal subset, enough for NotifyChequesAck.
    func encode() -> Data {
        var out = Data()
        encodeInto(&out)
        return out
    }

    private func encodeInto(_ out: inout Data) {
        switch self {
        case .uint(let n):
            CborValue.writeTypedLength(major: 0, n: n, out: &out)
        case .nint(let n):
            // CBOR encoding of -1-n is `major=1, n=-(n+1)`
            // Our .nint holds the signed value directly; convert.
            if n >= 0 { return CborValue.writeTypedLength(major: 0, n: UInt64(n), out: &out) }
            let mag = UInt64(-(n + 1))
            CborValue.writeTypedLength(major: 1, n: mag, out: &out)
        case .bytes(let b):
            CborValue.writeTypedLength(major: 2, n: UInt64(b.count), out: &out)
            out.append(b)
        case .text(let s):
            let bytes = Data(s.utf8)
            CborValue.writeTypedLength(major: 3, n: UInt64(bytes.count), out: &out)
            out.append(bytes)
        case .array(let arr):
            CborValue.writeTypedLength(major: 4, n: UInt64(arr.count), out: &out)
            for item in arr { item.encodeInto(&out) }
        case .map(let pairs):
            CborValue.writeTypedLength(major: 5, n: UInt64(pairs.count), out: &out)
            for (k, v) in pairs {
                k.encodeInto(&out)
                v.encodeInto(&out)
            }
        case .null:
            out.append(0xf6)
        case .bool(let b):
            out.append(b ? 0xf5 : 0xf4)
        }
    }

    private static func writeTypedLength(major: UInt8,
                                          n: UInt64,
                                          out: inout Data) {
        let tag = major << 5
        if n < 24 {
            out.append(tag | UInt8(n))
        } else if n < 0x100 {
            out.append(tag | 24)
            out.append(UInt8(n))
        } else if n < 0x10000 {
            out.append(tag | 25)
            out.append(UInt8((n >> 8) & 0xff))
            out.append(UInt8(n & 0xff))
        } else if n < 0x100000000 {
            out.append(tag | 26)
            out.append(UInt8((n >> 24) & 0xff))
            out.append(UInt8((n >> 16) & 0xff))
            out.append(UInt8((n >> 8) & 0xff))
            out.append(UInt8(n & 0xff))
        } else {
            out.append(tag | 27)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((n >> shift) & 0xff))
            }
        }
    }

    // Decode — same minimal subset.
    static func decode(_ data: Data) throws -> CborValue {
        var idx = 0
        let v = try decodeOne(data, &idx)
        if idx < data.count {
            throw CborError.message("trailing bytes after root CBOR value")
        }
        return v
    }

    private static func decodeOne(_ data: Data, _ idx: inout Int)
        throws -> CborValue
    {
        guard idx < data.count else {
            throw CborError.message("CBOR: unexpected end")
        }
        let head = data[idx]
        let major = head >> 5
        let info = head & 0x1f
        idx += 1
        let n = try readLength(info: info, data: data, idx: &idx)
        switch major {
        case 0:
            return .uint(n)
        case 1:
            // -1 - n
            let signed = -1 - Int64(min(n, UInt64(Int64.max)))
            return .nint(signed)
        case 2:
            guard idx + Int(n) <= data.count else {
                throw CborError.message("CBOR: bytes overflow")
            }
            let b = data.subdata(in: idx..<(idx + Int(n)))
            idx += Int(n)
            return .bytes(b)
        case 3:
            guard idx + Int(n) <= data.count else {
                throw CborError.message("CBOR: text overflow")
            }
            let b = data.subdata(in: idx..<(idx + Int(n)))
            idx += Int(n)
            guard let s = String(data: b, encoding: .utf8) else {
                throw CborError.message("CBOR: invalid utf8")
            }
            return .text(s)
        case 4:
            var items: [CborValue] = []
            items.reserveCapacity(Int(n))
            for _ in 0..<n {
                items.append(try decodeOne(data, &idx))
            }
            return .array(items)
        case 5:
            var pairs: [(CborValue, CborValue)] = []
            pairs.reserveCapacity(Int(n))
            for _ in 0..<n {
                let k = try decodeOne(data, &idx)
                let v = try decodeOne(data, &idx)
                pairs.append((k, v))
            }
            return .map(pairs)
        case 7:
            // Simple / float / null / bool — we only need null + bool
            // for the Ack round-trip; longer floats can be added when
            // a real wire requires them.
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            default:
                throw CborError.message("CBOR: unsupported simple value \(info)")
            }
        default:
            throw CborError.message("CBOR: unsupported major type \(major)")
        }
    }

    private static func readLength(info: UInt8,
                                    data: Data,
                                    idx: inout Int) throws -> UInt64 {
        if info < 24 { return UInt64(info) }
        switch info {
        case 24:
            guard idx < data.count else {
                throw CborError.message("CBOR: short u8 length")
            }
            let v = UInt64(data[idx])
            idx += 1
            return v
        case 25:
            guard idx + 2 <= data.count else {
                throw CborError.message("CBOR: short u16 length")
            }
            let v = (UInt64(data[idx]) << 8) | UInt64(data[idx + 1])
            idx += 2
            return v
        case 26:
            guard idx + 4 <= data.count else {
                throw CborError.message("CBOR: short u32 length")
            }
            var v: UInt64 = 0
            for i in 0..<4 { v = (v << 8) | UInt64(data[idx + i]) }
            idx += 4
            return v
        case 27:
            guard idx + 8 <= data.count else {
                throw CborError.message("CBOR: short u64 length")
            }
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(data[idx + i]) }
            idx += 8
            return v
        default:
            throw CborError.message("CBOR: indefinite length not supported (info=\(info))")
        }
    }
}
