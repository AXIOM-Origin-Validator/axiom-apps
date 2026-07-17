import Foundation

// =================================================================
// ChequeBlobVerifier — Bucket 5(c) — receive-side cheque blob check
//
// When MessageStore ingests an UncleInboundCheque pulled from
// validator UNCLE, we cross-check that the raw protocol cheque
// inside cheque_blob actually matches what UNCLE TOLD us about
// the row. This is partial verification — it does NOT recompute
// the BLAKE3("AXIOM_CHEQUE_V2"|...) commitment + ed25519-verify
// against validator_pk (full verification needs either a Rust FFI
// helper or a full Core port to Swift; deferred as a follow-on).
//
// What this DOES catch:
//   - A malicious / corrupted UNCLE that returns rows whose
//     envelope metadata (txid, receiver_wallet, sender_wallet,
//     amount) doesn't agree with the cheque_blob payload.
//   - Structurally malformed cheque_blobs (CBOR parse failure,
//     missing required fields, wrong-length signature or
//     validator_pk).
//
// What this does NOT catch:
//   - A cheque that's perfectly self-consistent but was never
//     actually witnessed (forged validator signature).
//   - Replay of an old cheque against a new state.
//   - FACT chain manipulation.
//
// For the bank-side demo this is the minimum "we cross-checked
// what UNCLE served" step. Bank forks targeting full production
// security replace this with a Core-FFI verify call.
// =================================================================

struct ChequeBlobVerification {
    enum Outcome: Equatable {
        /// Cross-check passed: CBOR ValidatorCheque + all envelope
        /// fields agree.
        case passed
        /// Blob is an email envelope (RFC 5322 headers prefix) —
        /// ANTIE format with the cheque embedded after the body
        /// boundary. The current UNCLE stores ANTIE's outbound mail
        /// as-is rather than the unwrapped CBOR. Cross-check is
        /// SKIPPED rather than failed; bank forks targeting full
        /// receive-side verify should pre-process the email,
        /// extract the AXIOM payload, then run this verifier on
        /// the extracted CBOR.
        case skippedEmailFormat
        /// Blob structure not recognisable — neither CBOR nor email.
        /// Could be a future encoding bank forks have to handle.
        case skippedUnknownFormat(firstBytesHex: String)
        /// CBOR root parsed but a field is missing / wrong shape.
        case malformed(reason: String)
        /// CBOR root parsed AND fields exist, but a field value
        /// disagrees with what UNCLE's envelope claimed. The bigger
        /// concern: catches an UNCLE that serves
        /// metadata-vs-payload mismatches.
        case mismatch(field: String, envelope: String, blob: String)

        var passed: Bool {
            if case .passed = self { return true }
            return false
        }
        /// True for outcomes that are not real failures — partial
        /// or skipped checks. The UI surfaces these distinct from
        /// `.malformed` / `.mismatch` to keep the visual signal
        /// honest about what we did and didn't verify.
        var isInformational: Bool {
            switch self {
            case .skippedEmailFormat, .skippedUnknownFormat:
                return true
            default:
                return false
            }
        }
    }
    let outcome: Outcome
    /// One-line summary suitable for MessageRecord lifecycle note.
    var summary: String {
        switch outcome {
        case .passed:
            return "Structural cross-check passed: cheque_blob fields agree with UNCLE envelope."
        case .skippedEmailFormat:
            return "Structural cross-check skipped: cheque_blob is in ANTIE email-envelope format (RFC 5322 headers). Bank forks needing full verify should extract the AXIOM payload from the body first."
        case .skippedUnknownFormat(let head):
            return "Structural cross-check skipped: cheque_blob format unknown (first bytes: \(head)…). Not CBOR, not RFC 5322."
        case .malformed(let reason):
            return "Structural cross-check FAILED — malformed cheque_blob: \(reason)"
        case .mismatch(let field, let env, let blob):
            return "Structural cross-check FAILED — \(field) mismatch: envelope=\(env) blob=\(blob)"
        }
    }
}

enum ChequeBlobVerifier {

    /// Structurally verify that a cheque_blob CBOR payload matches
    /// the metadata UNCLE returned in the InboundCheque envelope.
    static func verify(_ cheque: UncleInboundCheque) -> ChequeBlobVerification {
        // Empty blob → cannot verify, but UNCLE shouldn't return
        // these. Treat as malformed so the operator sees it.
        if cheque.chequeBlob.isEmpty {
            return ChequeBlobVerification(outcome: .malformed(
                reason: "cheque_blob is empty"))
        }
        // Format sniff: RFC 5322 email envelopes start with
        // `From: ` (one of the few mandatory header fields). The
        // current UNCLE observer stores ANTIE's outbound email
        // bytes as-is — those are valid cheque-bearing payloads
        // but not raw CBOR. Mark and return rather than fail.
        if cheque.chequeBlob.starts(with: Data("From: ".utf8))
            || cheque.chequeBlob.starts(with: Data("Return-Path:".utf8))
            || cheque.chequeBlob.starts(with: Data("Received:".utf8))
        {
            return ChequeBlobVerification(outcome: .skippedEmailFormat)
        }
        // CBOR map root (major type 5) — well-formed cheque CBOR
        // starts with the map-header byte 0xA0..0xBF (definite small
        // map) or 0xBF (indefinite map). Otherwise we don't know
        // the format.
        let firstByte = cheque.chequeBlob.first ?? 0
        let majorType = firstByte >> 5
        if majorType != 5 {
            let head = cheque.chequeBlob.prefix(8)
                .map { String(format: "%02x", $0) }.joined()
            return ChequeBlobVerification(
                outcome: .skippedUnknownFormat(firstBytesHex: head))
        }

        let value: CborValue
        do {
            value = try CborValue.decode(cheque.chequeBlob)
        } catch {
            return ChequeBlobVerification(outcome: .malformed(
                reason: "CBOR parse: \(error.localizedDescription)"))
        }
        guard case .map(let pairs) = value else {
            return ChequeBlobVerification(outcome: .malformed(
                reason: "expected CBOR map at root"))
        }
        let m = Dictionary(uniqueKeysWithValues: pairs.compactMap {
            (k, v) -> (String, CborValue)? in
            if case .text(let s) = k { return (s, v) }
            return nil
        })

        // ── Cross-check field 1: txid ────────────────────────────
        let blobTxid: Data
        switch m["txid"] {
        case .some(.bytes(let b)):
            blobTxid = b
        case .some(.array(let arr)):
            blobTxid = Data(arr.compactMap { item -> UInt8? in
                if case .uint(let n) = item, n <= 255 { return UInt8(n) }
                return nil
            })
        default:
            return ChequeBlobVerification(outcome: .malformed(
                reason: "missing/non-bytes txid"))
        }
        if blobTxid != cheque.txid {
            return ChequeBlobVerification(outcome: .mismatch(
                field: "txid",
                envelope: cheque.txidHex,
                blob: blobTxid.map { String(format: "%02x", $0) }.joined()))
        }

        // ── Cross-check field 2: sender_wallet_id ────────────────
        guard case .some(.text(let blobSender)) = m["sender_wallet_id"] else {
            return ChequeBlobVerification(outcome: .malformed(
                reason: "missing/non-text sender_wallet_id"))
        }
        if blobSender != cheque.senderWallet {
            return ChequeBlobVerification(outcome: .mismatch(
                field: "sender_wallet_id",
                envelope: cheque.senderWallet,
                blob: blobSender))
        }

        // ── Cross-check field 3: receiver_wallet_id ─────────────
        guard case .some(.text(let blobReceiver)) = m["receiver_wallet_id"] else {
            return ChequeBlobVerification(outcome: .malformed(
                reason: "missing/non-text receiver_wallet_id"))
        }
        if blobReceiver != cheque.receiverWallet {
            return ChequeBlobVerification(outcome: .mismatch(
                field: "receiver_wallet_id",
                envelope: cheque.receiverWallet,
                blob: blobReceiver))
        }

        // ── Cross-check field 4: amount ──────────────────────────
        guard case .some(.uint(let blobAmount)) = m["amount"] else {
            return ChequeBlobVerification(outcome: .malformed(
                reason: "missing/non-uint amount"))
        }
        if blobAmount != cheque.amountAtoms {
            return ChequeBlobVerification(outcome: .mismatch(
                field: "amount",
                envelope: String(cheque.amountAtoms),
                blob: String(blobAmount)))
        }

        // ── Field-shape checks: validator_pk + signature ─────────
        switch m["validator_pk"] {
        case .some(.bytes(let b)):
            if b.count != 32 {
                return ChequeBlobVerification(outcome: .malformed(
                    reason: "validator_pk wrong length \(b.count) (want 32)"))
            }
        case .some(.array(let arr)):
            if arr.count != 32 {
                return ChequeBlobVerification(outcome: .malformed(
                    reason: "validator_pk array wrong length \(arr.count) (want 32)"))
            }
        default:
            return ChequeBlobVerification(outcome: .malformed(
                reason: "missing/non-bytes validator_pk"))
        }
        switch m["signature"] {
        case .some(.bytes(let b)):
            if b.count != 64 {
                return ChequeBlobVerification(outcome: .malformed(
                    reason: "signature wrong length \(b.count) (want 64)"))
            }
        case .some(.array(let arr)):
            if arr.count != 64 {
                return ChequeBlobVerification(outcome: .malformed(
                    reason: "signature array wrong length \(arr.count) (want 64)"))
            }
        default:
            return ChequeBlobVerification(outcome: .malformed(
                reason: "missing/non-bytes signature"))
        }

        return ChequeBlobVerification(outcome: .passed)
    }
}
