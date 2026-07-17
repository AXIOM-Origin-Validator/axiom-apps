import Foundation
import Network
import AxiomSdk

// =================================================================
// Smoke — Mac→Linux PullCheques cross-process validator. Mirrors
// UncleGatewayClient logic flat in a single file so the wire can
// be validated from a terminal without the SwiftUI shell.
//
// Usage:
//   swift run Smoke <op-key-path> <uncle-pubkey-path> <host:port>
//
// Example:
//   swift run Smoke /tmp/uncle-sam-smoke/mac-uncle-sam-secret.asc \
//                   /tmp/alpha-uncle-public.asc \
//                   172.20.0.42:9301
//
// Workflow:
//   1. Load Mac operator PGP secret key from disk
//   2. Read UNCLE alpha PGP public key armoured block from disk
//   3. Send Status → print response
//   4. Send PullCheques → print response (cheques count + each row's
//      txid prefix, receiver, sender, amount, blob size)
// =================================================================

let MAX_ENVELOPE: Int = 4 * 1024 * 1024

guard CommandLine.arguments.count == 4 else {
    print("usage: Smoke <op-key-path> <uncle-pubkey-path> <host:port>")
    exit(1)
}
let opKeyPath = CommandLine.arguments[1]
let unclePubkeyPath = CommandLine.arguments[2]
let targetEndpoint = CommandLine.arguments[3]

print("smoke: loading op key from \(opKeyPath)")
let operatorKey: FfiOperatorPgpKey
do {
    operatorKey = try FfiOperatorPgpKey.load(path: opKeyPath, passphrase: nil)
} catch {
    print("smoke: load op key failed: \(error)")
    exit(2)
}
print("smoke: op fingerprint=\(operatorKey.fingerprint())")

print("smoke: reading UNCLE pubkey from \(unclePubkeyPath)")
let unclePubkeyArmored: Data
do {
    let s = try String(contentsOfFile: unclePubkeyPath, encoding: .utf8)
    unclePubkeyArmored = s.data(using: .utf8)!
} catch {
    print("smoke: read uncle pubkey failed: \(error)")
    exit(3)
}

print("smoke: target=\(targetEndpoint)")
print("")

// ── Status ──────────────────────────────────────────────────────

let statusReq = encodeStatusRequest()
print("smoke: --- Status ---")
let statusReply = roundTrip(
    inner: statusReq,
    opKey: operatorKey,
    targetPubkey: unclePubkeyArmored,
    endpoint: targetEndpoint)
guard let statusReply = statusReply else { exit(4) }
guard case .map(let pairs) = try? CborValue.decode(statusReply.payload) else {
    print("smoke: status: response not a CBOR map")
    exit(4)
}
let smap = pairs.reduce(into: [String: CborValue]()) { acc, p in
    if case .text(let k) = p.0 { acc[k] = p.1 }
}
guard case .some(.text(let tag)) = smap["t"], tag == "StatusResponse" else {
    print("smoke: status: unexpected tag")
    exit(4)
}
print("  version          = \(textOrErr(smap, "version"))")
print("  uptime_secs      = \(uintOrErr(smap, "uptime_secs"))")
print("  pending_outbound = \(uintOrErr(smap, "pending_outbound"))")
print("  pending_inbound  = \(uintOrErr(smap, "pending_inbound"))")
let tip = bytesOrErr(smap, "audit_chain_tip")
print("  audit_chain_tip  = \(tip.map { String(format: "%02x", $0) }.joined())")
print("")

// ── PullCheques ────────────────────────────────────────────────

let pullReq = encodePullChequesRequest(sinceTick: 0,
                                        walletFilter: nil,
                                        maxRows: 100)
print("smoke: --- PullCheques ---")
let pullReply = roundTrip(
    inner: pullReq,
    opKey: operatorKey,
    targetPubkey: unclePubkeyArmored,
    endpoint: targetEndpoint)
guard let pullReply = pullReply else { exit(5) }
guard case .map(let prPairs) = try? CborValue.decode(pullReply.payload) else {
    print("smoke: pull: response not a CBOR map")
    exit(5)
}
let pmap = prPairs.reduce(into: [String: CborValue]()) { acc, p in
    if case .text(let k) = p.0 { acc[k] = p.1 }
}
guard case .some(.text(let prTag)) = pmap["t"], prTag == "PullChequesResponse" else {
    print("smoke: pull: unexpected tag")
    exit(5)
}
let chequeNodes: [CborValue]
if case .some(.array(let arr)) = pmap["cheques"] {
    chequeNodes = arr
} else {
    chequeNodes = []
}
print("  cheques=\(chequeNodes.count)")
if case .some(.bool(let more)) = pmap["more_available"], more {
    print("  more_available=true")
}
if case .some(.map(let errPairs)) = pmap["error"] {
    let em = errPairs.reduce(into: [String: CborValue]()) { acc, p in
        if case .text(let k) = p.0 { acc[k] = p.1 }
    }
    print("  daemon error: \(textOrErr(em, "code")): \(textOrErr(em, "message"))")
}
for (i, c) in chequeNodes.enumerated() {
    guard case .map(let cPairs) = c else { continue }
    let cm = cPairs.reduce(into: [String: CborValue]()) { acc, p in
        if case .text(let k) = p.0 { acc[k] = p.1 }
    }
    let txid = bytesOrErr(cm, "txid")
    let txidHex = txid.map { String(format: "%02x", $0) }.joined()
    let blob = bytesOrErr(cm, "cheque_blob")
    print("  [\(i)] txid=\(String(txidHex.prefix(16)))…")
    print("       receiver=\(textOrErr(cm, "receiver_wallet"))")
    print("       sender=\(textOrErr(cm, "sender_wallet"))")
    print("       amount_atoms=\(uintOrErr(cm, "amount_atoms"))")
    print("       received_at_tick=\(uintOrErr(cm, "received_at_tick"))")
    print("       blob=\(blob.count) bytes")
}

print("")
print("smoke: done")

// ── helpers ────────────────────────────────────────────────────

struct RoundTripResult { let payload: Data; let senderFp: String; let senderEmail: String }

func roundTrip(inner: Data,
                opKey: FfiOperatorPgpKey,
                targetPubkey: Data,
                endpoint: String) -> RoundTripResult? {
    // wrap
    let envelope: Data
    do {
        envelope = try sdkPgpEnvelopeWrap(operatorKey: opKey,
                                           recipientPubkeyArmored: targetPubkey,
                                           payload: inner)
    } catch {
        print("smoke: wrap failed: \(error)")
        return nil
    }

    // tcp send / receive
    let parts = endpoint.split(separator: ":")
    guard parts.count == 2, let port = UInt16(parts[1]) else {
        print("smoke: invalid endpoint")
        return nil
    }
    let host = String(parts[0])
    var reply: Data?
    let group = DispatchGroup()
    group.enter()
    let queue = DispatchQueue(label: "smoke.tcp", qos: .userInitiated)
    let conn = NWConnection(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(rawValue: port)!,
                             using: .tcp)
    var resumed = false
    let done: (Data?) -> Void = { d in
        if resumed { return }
        resumed = true
        reply = d
        conn.cancel()
        group.leave()
    }
    conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
            var frame = Data()
            var lenBE = UInt32(envelope.count).bigEndian
            withUnsafeBytes(of: &lenBE) { frame.append(contentsOf: $0) }
            frame.append(envelope)
            conn.send(content: frame, completion: .contentProcessed { err in
                if let err = err { print("smoke: send err \(err)"); done(nil); return }
                conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { d, _, _, e in
                    if let e = e { print("smoke: read len err \(e)"); done(nil); return }
                    guard let d = d, d.count == 4 else { print("smoke: short len"); done(nil); return }
                    let len = Int(d.withUnsafeBytes { raw -> UInt32 in
                        raw.load(as: UInt32.self).bigEndian
                    })
                    if len == 0 || len > MAX_ENVELOPE {
                        print("smoke: bad reply len \(len)"); done(nil); return
                    }
                    conn.receive(minimumIncompleteLength: len, maximumLength: len) { d2, _, _, e2 in
                        if let e2 = e2 { print("smoke: read body err \(e2)"); done(nil); return }
                        guard let d2 = d2, d2.count == len else { print("smoke: short body"); done(nil); return }
                        done(d2)
                    }
                }
            })
        case .failed(let e):
            print("smoke: conn failed \(e)")
            done(nil)
        case .cancelled:
            done(nil)
        default:
            break
        }
    }
    conn.start(queue: queue)
    let waitResult = group.wait(timeout: .now() + 30)
    if waitResult == .timedOut {
        print("smoke: tcp timeout")
        return nil
    }
    guard let replyBytes = reply else { return nil }

    // unwrap
    do {
        let verified = try sdkPgpEnvelopeUnwrap(
            operatorKey: opKey,
            senderPubkeyArmored: targetPubkey,
            envelopeBytes: replyBytes)
        return RoundTripResult(payload: Data(verified.payload),
                                senderFp: verified.senderPgpFingerprint,
                                senderEmail: verified.senderEmail)
    } catch {
        print("smoke: unwrap failed: \(error)")
        return nil
    }
}

// ── Encoding helpers ───────────────────────────────────────────

func encodeStatusRequest() -> Data {
    CborValue.map([(.text("t"), .text("Status"))]).encode()
}

func encodePullChequesRequest(sinceTick: UInt64,
                               walletFilter: [String]?,
                               maxRows: UInt32) -> Data {
    var pairs: [(CborValue, CborValue)] = [
        (.text("t"), .text("PullCheques")),
        (.text("since_tick"), .uint(sinceTick)),
    ]
    if let wf = walletFilter {
        pairs.append((.text("wallet_filter"), .array(wf.map { .text($0) })))
    } else {
        pairs.append((.text("wallet_filter"), .null))
    }
    pairs.append((.text("max_rows"), .uint(UInt64(maxRows))))
    return CborValue.map(pairs).encode()
}

// ── Lookup helpers ─────────────────────────────────────────────

func textOrErr(_ m: [String: CborValue], _ k: String) -> String {
    if case .some(.text(let s)) = m[k] { return s }
    return "<missing \(k)>"
}
func uintOrErr(_ m: [String: CborValue], _ k: String) -> UInt64 {
    if case .some(.uint(let n)) = m[k] { return n }
    return 0
}
func bytesOrErr(_ m: [String: CborValue], _ k: String) -> Data {
    guard let v = m[k] else { return Data() }
    switch v {
    case .bytes(let b): return b
    case .array(let arr):
        return Data(arr.compactMap { item -> UInt8? in
            if case .uint(let i) = item, i <= 255 { return UInt8(i) }
            return nil
        })
    default: return Data()
    }
}

// ── Inline CBOR encoder/decoder (small subset, mirrors
// PgpEnvelopeHandler.swift but standalone for the smoke binary) ─

indirect enum CborValue {
    case uint(UInt64)
    case nint(Int64)
    case bytes(Data)
    case text(String)
    case array([CborValue])
    case map([(CborValue, CborValue)])
    case null
    case bool(Bool)
}

enum CborError: Error { case msg(String) }

extension CborValue {
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
            if n >= 0 {
                CborValue.writeTypedLength(major: 0, n: UInt64(n), out: &out)
            } else {
                CborValue.writeTypedLength(major: 1, n: UInt64(-(n + 1)), out: &out)
            }
        case .bytes(let b):
            CborValue.writeTypedLength(major: 2, n: UInt64(b.count), out: &out)
            out.append(b)
        case .text(let s):
            let bs = Data(s.utf8)
            CborValue.writeTypedLength(major: 3, n: UInt64(bs.count), out: &out)
            out.append(bs)
        case .array(let arr):
            CborValue.writeTypedLength(major: 4, n: UInt64(arr.count), out: &out)
            for item in arr { item.encodeInto(&out) }
        case .map(let pairs):
            CborValue.writeTypedLength(major: 5, n: UInt64(pairs.count), out: &out)
            for (k, v) in pairs { k.encodeInto(&out); v.encodeInto(&out) }
        case .null:
            out.append(0xf6)
        case .bool(let b):
            out.append(b ? 0xf5 : 0xf4)
        }
    }
    private static func writeTypedLength(major: UInt8, n: UInt64, out: inout Data) {
        let tag = major << 5
        if n < 24 { out.append(tag | UInt8(n)) }
        else if n < 0x100 { out.append(tag | 24); out.append(UInt8(n)) }
        else if n < 0x10000 {
            out.append(tag | 25); out.append(UInt8((n >> 8) & 0xff)); out.append(UInt8(n & 0xff))
        } else if n < 0x100000000 {
            out.append(tag | 26)
            out.append(UInt8((n >> 24) & 0xff)); out.append(UInt8((n >> 16) & 0xff))
            out.append(UInt8((n >> 8) & 0xff)); out.append(UInt8(n & 0xff))
        } else {
            out.append(tag | 27)
            for s in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((n >> s) & 0xff))
            }
        }
    }

    static func decode(_ data: Data) throws -> CborValue {
        var i = 0
        let v = try decodeOne(data, &i)
        return v
    }
    private static func decodeOne(_ d: Data, _ i: inout Int) throws -> CborValue {
        guard i < d.count else { throw CborError.msg("eof") }
        let head = d[i]; let major = head >> 5; let info = head & 0x1f
        i += 1
        let n = try readLen(info, d, &i)
        switch major {
        case 0: return .uint(n)
        case 1: return .nint(-1 - Int64(min(n, UInt64(Int64.max))))
        case 2:
            guard i + Int(n) <= d.count else { throw CborError.msg("bytes ovf") }
            let b = d.subdata(in: i..<(i + Int(n))); i += Int(n)
            return .bytes(b)
        case 3:
            guard i + Int(n) <= d.count else { throw CborError.msg("text ovf") }
            let b = d.subdata(in: i..<(i + Int(n))); i += Int(n)
            guard let s = String(data: b, encoding: .utf8) else { throw CborError.msg("utf8") }
            return .text(s)
        case 4:
            var arr: [CborValue] = []
            for _ in 0..<n { arr.append(try decodeOne(d, &i)) }
            return .array(arr)
        case 5:
            var pairs: [(CborValue, CborValue)] = []
            for _ in 0..<n {
                let k = try decodeOne(d, &i); let v = try decodeOne(d, &i)
                pairs.append((k, v))
            }
            return .map(pairs)
        case 7:
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            default: throw CborError.msg("simple \(info)")
            }
        default: throw CborError.msg("major \(major)")
        }
    }
    private static func readLen(_ info: UInt8, _ d: Data, _ i: inout Int) throws -> UInt64 {
        if info < 24 { return UInt64(info) }
        switch info {
        case 24:
            guard i < d.count else { throw CborError.msg("len u8") }
            let v = UInt64(d[i]); i += 1; return v
        case 25:
            guard i + 2 <= d.count else { throw CborError.msg("len u16") }
            let v = (UInt64(d[i]) << 8) | UInt64(d[i + 1]); i += 2; return v
        case 26:
            guard i + 4 <= d.count else { throw CborError.msg("len u32") }
            var v: UInt64 = 0
            for k in 0..<4 { v = (v << 8) | UInt64(d[i + k]) }
            i += 4; return v
        case 27:
            guard i + 8 <= d.count else { throw CborError.msg("len u64") }
            var v: UInt64 = 0
            for k in 0..<8 { v = (v << 8) | UInt64(d[i + k]) }
            i += 8; return v
        default: throw CborError.msg("indef len")
        }
    }
}
