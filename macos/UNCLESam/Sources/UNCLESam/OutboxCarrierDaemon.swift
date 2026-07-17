import Foundation
import Network
import SwiftUI
import AxiomSdk

// =================================================================
// OutboxCarrierDaemon — UNCLE SAM's witness-delivery carrier over
// the UNCLE TCP wire.
//
// Context (see docs/AXIOM_DESIGN_UncleSam_CarrierDirect.md):
//
//   The SDK's wallet.send() builds a signed witness UMP, writes it
//   to <wallet.dir>/outbox/, then polls <wallet.dir>/maildir/inbox/
//   for k witness-response UMPs. SDK never touches the network for
//   anything but Nabla — application owns the carrier.
//
//   UNCLE SAM cannot use TOT or FATMAMA: UNCLE is Apache 2.0 and
//   must stay self-contained relative to the Apache stack. This
//   daemon is the Apache-clean replacement carrier — it talks
//   directly to validators' UNCLE gateways over PGP-enveloped TCP
//   (the same wire UncleGatewayClient uses for PullCheques + Status).
//
// Flow (per outbox file):
//
//   1. Read UMP bytes from <wallet.dir>/outbox/<name>.
//   2. Scan sdkValidatorHintsLive() for validators advertising an
//      uncle: carrier with a non-empty PGP encryptionPublicKey.
//   3. Pick up to k targets (default 3 — sender's address tier
//      drives this in §4 below).
//   4. For each target, build a SubmitSend with payload = raw UMP
//      bytes, PGP-wrap with the validator's pubkey, send to
//      uncle:host:port, await SubmitSendResponse.
//   5. SubmitSendResponse.witness_responses carries the validator's
//      witness UMP — drop each one as a file in
//      <wallet.dir>/maildir/inbox/. The SDK's wallet.send() poll
//      loop picks them up and finalises the round.
//   6. If any responses came back: delete outbox file. If none: leave
//      for retry with a 5s backoff per filename (next poll tick).
//
// Backoff model:
//
//   - Each outbox filename is tracked by lastAttemptAt.
//   - Backoff = 5s between retries on the same filename.
//   - On success the entry is removed from the in-flight set.
//   - Daemon polls every 200ms; backoff is enforced before
//     re-dispatch.
//
// Linux-side contract this daemon depends on:
//
//   axiom-uncle::wire::SubmitSendResponse MUST gain a
//   `witness_responses: Vec<Vec<u8>>` field (one entry per
//   collected witness response). When absent or empty, the daemon
//   treats it as "round didn't close — try again."
// =================================================================

/// Per-account dispatch trace surfaced to the Settings card.
struct OutboxDispatchTrace: Identifiable {
    let id: UUID = UUID()
    let timestamp: Date
    let outboxFile: String
    let walletDir: String
    let targets: [String]
    let witnessResponsesReceived: Int
    let droppedToMaildir: Int
    let outcome: Outcome

    enum Outcome {
        case ok
        case partial(String)
        case error(String)
    }

    var outcomeLabel: String {
        switch outcome {
        case .ok: return "OK"
        case .partial(let s): return "PARTIAL: \(s)"
        case .error(let s): return "ERROR: \(s)"
        }
    }
}

/// Default witness-round size when the daemon can't read it off
/// the UMP. Matches §3.5 (Standard tier k=3 DMAP).
private let UNCLE_SAM_OUTBOX_DEFAULT_K: Int = 3

/// Backoff between retries on the same outbox filename when no
/// responses came back.
private let UNCLE_SAM_OUTBOX_RETRY_BACKOFF_SECS: TimeInterval = 5.0

/// Poll cadence — fast enough to feel synchronous, slow enough that
/// idle daemons don't burn CPU.
private let UNCLE_SAM_OUTBOX_POLL_INTERVAL_NS: UInt64 = 200_000_000

/// Sequoia/PGP wrap + TCP send timeout per validator.
private let UNCLE_SAM_OUTBOX_PER_TARGET_TIMEOUT_SECS: TimeInterval = 90.0

@MainActor
final class OutboxCarrierDaemon: ObservableObject {

    @Published private(set) var pollingActive: Bool = false
    @Published private(set) var lastError: String? = nil
    @Published private(set) var traces: [OutboxDispatchTrace] = []

    private weak var pgpHandler: PgpEnvelopeHandler?
    weak var session: InstitutionSession?

    private var pollTask: Task<Void, Never>? = nil
    private var inFlight: Set<String> = []          // outbox path
    private var nextAttemptAt: [String: Date] = [:] // outbox path

    init(pgpHandler: PgpEnvelopeHandler) {
        self.pgpHandler = pgpHandler
    }

    // ─── Lifecycle ──────────────────────────────────────────────

    func start() {
        guard pollTask == nil else { return }
        pollingActive = true
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
        NSLog("[OutboxCarrierDaemon] started")
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        pollingActive = false
        NSLog("[OutboxCarrierDaemon] stopped")
    }

    // ─── Poll loop ──────────────────────────────────────────────

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            try? await Task.sleep(nanoseconds: UNCLE_SAM_OUTBOX_POLL_INTERVAL_NS)
        }
    }

    private func pollOnce() async {
        guard let session = session else { return }
        let appDir = uncleAppDir()
        let accounts = session.accounts
        let now = Date()
        for account in accounts {
            let walletDir = Self.walletDirFor(account: account, appDir: appDir)
            // SDK writes to `<walletDir>/outbox/new/<unix_micros>.<uuid>.eml`
            // — full RFC 5321 emails — via atomic tmp→rename. We watch
            // only `outbox/new/`; the SDK's `outbox/tmp/` is private to
            // the writer (see sdk/client/src/outbox.rs).
            let outboxDir = "\(walletDir)/outbox/new"
            guard let entries = try? FileManager.default
                .contentsOfDirectory(atPath: outboxDir) else { continue }
            for name in entries {
                if name.hasPrefix(".") { continue }
                if !name.hasSuffix(".eml") { continue }
                let full = "\(outboxDir)/\(name)"
                if inFlight.contains(full) { continue }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full,
                                                      isDirectory: &isDir),
                      !isDir.boolValue else { continue }
                if let nextOk = nextAttemptAt[full], nextOk > now { continue }
                inFlight.insert(full)
                Task { [weak self] in
                    await self?.dispatchOne(outboxFile: full,
                                             walletDir: walletDir,
                                             account: account)
                }
            }
        }
    }

    /// Compute the on-disk wallet directory for an account. Matches
    /// InstitutionSession's own derivation (`<appDir>/wallets/
    /// <pairName>-normal/`). Done here instead of via AxiomWallet
    /// because the FFI does not expose `wallet.dir()` and the path
    /// is stable at the institution-account layer.
    private static func walletDirFor(account: InstitutionAccount,
                                       appDir: String) -> String {
        return "\(appDir)/wallets/\(account.config.pairName)-normal"
    }

    // ─── Per-file dispatch ──────────────────────────────────────

    private func dispatchOne(outboxFile: String,
                              walletDir: String,
                              account: InstitutionAccount) async {
        defer { inFlight.remove(outboxFile) }

        guard let payload = try? Data(contentsOf:
                URL(fileURLWithPath: outboxFile)) else {
            recordError(outboxFile: outboxFile, walletDir: walletDir,
                         targets: [],
                         msg: "could not read outbox file")
            return
        }

        // Skip suspiciously small files — almost certainly partial
        // writes from the SDK still in progress. Retry on next tick.
        if payload.count < 32 {
            nextAttemptAt[outboxFile] = Date().addingTimeInterval(
                UNCLE_SAM_OUTBOX_RETRY_BACKOFF_SECS)
            return
        }

        guard let pgpHandler = pgpHandler,
              let operatorKey = pgpHandler.borrowOperatorKey() else {
            recordError(outboxFile: outboxFile, walletDir: walletDir,
                         targets: [],
                         msg: "PGP operator key not loaded")
            nextAttemptAt[outboxFile] = Date().addingTimeInterval(
                UNCLE_SAM_OUTBOX_RETRY_BACKOFF_SECS)
            return
        }

        // 1:1 routing — each outbox .eml is destined for ONE
        // specific validator, named in the `To:` header. The SDK
        // sealed the UMP body to that validator's recipient pubkey
        // (sdk/client/src/send.rs:3011), so any other validator's ANTIE
        // rejects with [ANTIE-DROP-DECRYPT]. Fan-out is wrong here.
        let toAddress = (Self.extractEmailHeader(payload, name: "To") ?? "")
            .trimmingCharacters(in: .whitespaces)
        if toAddress.isEmpty {
            recordError(outboxFile: outboxFile, walletDir: walletDir,
                         targets: [],
                         msg: "outbox .eml missing To: header")
            nextAttemptAt[outboxFile] = Date().addingTimeInterval(
                UNCLE_SAM_OUTBOX_RETRY_BACKOFF_SECS)
            return
        }

        // Match the To: address to a validator. Runtime hints first
        // (carry per-validator PGP keys after gossip propagation),
        // static list + shared gateway pubkey as cold-start fallback.
        // The cold-start fallback works because in the dev env all
        // UNCLE-capable validators share one operator key.
        let pickedTarget: (name: String, endpoint: String, pubkey: String)?
        if let live = sdkValidatorHintsLive().first(where: { hint in
            !hint.encryptionPublicKey.isEmpty &&
            hint.carriers.contains(where: {
                $0.lowercased().contains(toAddress.lowercased())
            })
        }), let uri = live.carriers.first(where: { $0.hasPrefix("uncle:") }) {
            pickedTarget = (live.name,
                             String(uri.dropFirst("uncle:".count)),
                             live.encryptionPublicKey)
        } else if let stat = sdkAppValidators().first(where: {
            $0.email.lowercased() == toAddress.lowercased()
        }), let uri = stat.carriers.first(where: { $0.hasPrefix("uncle:") }) {
            let fallbackKey = UserDefaults.standard.string(
                forKey: "uncle.sam.gateway.pubkey_armored") ?? ""
            if !fallbackKey.isEmpty {
                pickedTarget = (stat.name,
                                 String(uri.dropFirst("uncle:".count)),
                                 fallbackKey)
            } else {
                pickedTarget = nil
            }
        } else {
            pickedTarget = nil
        }

        guard let chosen = pickedTarget else {
            recordError(outboxFile: outboxFile, walletDir: walletDir,
                         targets: [],
                         msg: "no uncle: validator matches To: \(toAddress)")
            nextAttemptAt[outboxFile] = Date().addingTimeInterval(
                UNCLE_SAM_OUTBOX_RETRY_BACKOFF_SECS)
            return
        }
        let targets = [chosen]
        NSLog("[OutboxCarrierDaemon] routed To:%@ → %@ (%@)", toAddress,
              chosen.name, chosen.endpoint)

        // PGP-wrap once per target on the MainActor — uniffi's
        // FfiOperatorPgpKey is a reference handle and isn't safe to
        // ship into a TaskGroup child. Wrap on MainActor produces
        // a Data envelope; only the envelope (plus the validator's
        // pubkey for the reply unwrap) crosses the actor boundary.
        //
        // sender_wallet must match a wallet owned by the requesting
        // PGP fingerprint per UNCLE's wallet_ownership ACL — the same
        // gate PullCheques uses. We pull the canonical wallet_id from
        // the account's tier address; UNCLE's ACL on alpha was
        // grantsed for these fingerprint↔wallet pairings during Mac
        // onboarding (Bucket b).
        let senderWalletId = account.tierAddress
        let innerCbor = Self.encodeSubmitSend(payload: payload,
                                                senderWallet: senderWalletId)
        var prewrapped: [(target: (name: String, endpoint: String, pubkey: String),
                          envelope: Data)] = []
        for target in targets {
            guard let pubkeyData = target.pubkey.data(using: .utf8) else { continue }
            do {
                let envelope = try sdkPgpEnvelopeWrap(
                    operatorKey: operatorKey,
                    recipientPubkeyArmored: pubkeyData,
                    payload: innerCbor)
                prewrapped.append((target, envelope))
            } catch {
                NSLog("[OutboxCarrierDaemon] %@:%@", target.endpoint,
                      "PGP wrap: \(error.localizedDescription)")
            }
        }

        // Fan out — one TCP round-trip per target. Each connection
        // is a single SubmitSend → SubmitSendResponse; UNCLE holds
        // the TCP open until its witness observer collects the
        // local validator's response (or its timeout fires).
        let replies = await withTaskGroup(of: (target: (name: String, endpoint: String, pubkey: String),
                                                 reply: Data?).self,
                                            returning: [(target: (name: String, endpoint: String, pubkey: String),
                                                         reply: Data?)].self) { group in
            for (target, envelope) in prewrapped {
                group.addTask {
                    do {
                        let reply = try await Self.tcpRoundTrip(
                            endpoint: target.endpoint,
                            framedRequest: envelope)
                        return (target, reply)
                    } catch {
                        NSLog("[OutboxCarrierDaemon] %@:%@", target.endpoint,
                              "TCP: \(error.localizedDescription)")
                        return (target, nil)
                    }
                }
            }
            var all: [(target: (name: String, endpoint: String, pubkey: String),
                       reply: Data?)] = []
            for await item in group {
                all.append(item)
            }
            return all
        }

        // Unwrap replies on MainActor and aggregate witness_responses.
        var collected: [Data] = []
        for (target, replyOpt) in replies {
            guard let reply = replyOpt else { continue }
            guard let pubkeyData = target.pubkey.data(using: .utf8) else { continue }
            do {
                let verified = try sdkPgpEnvelopeUnwrap(
                    operatorKey: operatorKey,
                    senderPubkeyArmored: pubkeyData,
                    envelopeBytes: reply)
                let witnesses = Self.decodeSubmitSendResponseWitnesses(
                    Data(verified.payload), endpoint: target.endpoint)
                collected.append(contentsOf: witnesses)
            } catch {
                NSLog("[OutboxCarrierDaemon] %@:%@", target.endpoint,
                      "PGP unwrap: \(error.localizedDescription)")
            }
        }

        // Drop each witness-response email into `maildir/inbox/new/`.
        // Linux ANTIE's UnclesCarrier sink returns the same RFC 5321
        // bytes ANTIE would normally hand to the SMTP carrier — the
        // SDK's poll_inbox_for_response loop expects .eml files and
        // parses them the same way for both transports.
        //
        // Standard maildir convention: write to `tmp/` first, then
        // rename into `new/`, so the SDK's directory scan never sees
        // a half-written file.
        let inboxNewDir = "\(walletDir)/maildir/inbox/new"
        let inboxTmpDir = "\(walletDir)/maildir/inbox/tmp"
        try? FileManager.default.createDirectory(atPath: inboxNewDir,
                                                   withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: inboxTmpDir,
                                                   withIntermediateDirectories: true)
        var dropped = 0
        for (i, body) in collected.enumerated() {
            let micros = UInt64(Date().timeIntervalSince1970 * 1_000_000)
            let fname = "\(micros).\(UUID().uuidString).\(i).eml"
            let tmpPath = "\(inboxTmpDir)/\(fname)"
            let newPath = "\(inboxNewDir)/\(fname)"
            do {
                try body.write(to: URL(fileURLWithPath: tmpPath))
                try FileManager.default.moveItem(atPath: tmpPath,
                                                   toPath: newPath)
                dropped += 1
            } catch {
                NSLog("[OutboxCarrierDaemon] failed to write \(newPath): \(error.localizedDescription)")
                try? FileManager.default.removeItem(atPath: tmpPath)
            }
        }

        if dropped > 0 {
            try? FileManager.default.removeItem(atPath: outboxFile)
            nextAttemptAt.removeValue(forKey: outboxFile)
            recordTrace(OutboxDispatchTrace(
                timestamp: Date(),
                outboxFile: outboxFile,
                walletDir: walletDir,
                targets: targets.map { $0.name },
                witnessResponsesReceived: collected.count,
                droppedToMaildir: dropped,
                outcome: collected.count == dropped
                    ? .ok
                    : .partial("\(dropped)/\(collected.count) responses written")))
        } else {
            nextAttemptAt[outboxFile] = Date().addingTimeInterval(
                UNCLE_SAM_OUTBOX_RETRY_BACKOFF_SECS)
            recordTrace(OutboxDispatchTrace(
                timestamp: Date(),
                outboxFile: outboxFile,
                walletDir: walletDir,
                targets: targets.map { $0.name },
                witnessResponsesReceived: 0,
                droppedToMaildir: 0,
                outcome: .error("0 witness_responses from any target — retry in \(Int(UNCLE_SAM_OUTBOX_RETRY_BACKOFF_SECS))s")))
        }
    }

    /// Witness-round size selector. Default 3 (Standard tier k=3 DMAP).
    /// When UMP-parsing is added we can read the sender's tier off
    /// the payload and pick 4 / 5 for higher tiers.
    private func pickK(payload: Data) -> Int {
        return UNCLE_SAM_OUTBOX_DEFAULT_K
    }

    private func recordTrace(_ t: OutboxDispatchTrace) {
        traces.insert(t, at: 0)
        if traces.count > 32 { traces.removeLast(traces.count - 32) }
        NSLog("[OutboxCarrierDaemon] %@", "trace targets=\(t.targets.joined(separator: ",")) responses=\(t.witnessResponsesReceived) dropped=\(t.droppedToMaildir) outcome=\(t.outcomeLabel)")
    }

    private func recordError(outboxFile: String, walletDir: String,
                              targets: [String], msg: String) {
        lastError = msg
        recordTrace(OutboxDispatchTrace(
            timestamp: Date(),
            outboxFile: outboxFile,
            walletDir: walletDir,
            targets: targets,
            witnessResponsesReceived: 0,
            droppedToMaildir: 0,
            outcome: .error(msg)))
    }

    // ─── RFC 5322 header extraction ─────────────────────────────

    /// Extract a header value from an RFC 5322 email by name.
    /// Reads only the first 8KB (headers always fit) and operates
    /// at the byte level — Swift's `String.range(of:)` treats `\r\n`
    /// as one grapheme cluster, so character-level search for `\nTo:`
    /// fails inside `\r\nTo:`. Byte search avoids the trap.
    /// Case-insensitive header name match. Returns the trimmed value
    /// of the first matching header, or nil if absent.
    private nonisolated static func extractEmailHeader(
        _ data: Data, name: String
    ) -> String? {
        let headerBytes = data.prefix(8 * 1024)
        // Pre-build the lowercase ASCII byte prefix we're searching
        // for: `\n<name>:` (covers all but a header at file start)
        // plus a separate check for `<name>:` at offset 0.
        let nameLower = name.lowercased()
        let prefixBytes: [UInt8] = [0x0A] + nameLower.utf8.map { $0 } + [UInt8(ascii: ":")]
        let zeroOffsetBytes: [UInt8] = nameLower.utf8.map { $0 } + [UInt8(ascii: ":")]
        let bytes = Array(headerBytes)

        func toLowerAscii(_ b: UInt8) -> UInt8 {
            (b >= 0x41 && b <= 0x5A) ? (b + 0x20) : b
        }

        // Match position where the value starts (right after the colon).
        var valueStart: Int? = nil
        // Check start-of-file case first.
        if bytes.count >= zeroOffsetBytes.count {
            var match = true
            for i in 0..<zeroOffsetBytes.count {
                if toLowerAscii(bytes[i]) != zeroOffsetBytes[i] {
                    match = false; break
                }
            }
            if match { valueStart = zeroOffsetBytes.count }
        }
        if valueStart == nil {
            // Scan for \n<name>: anywhere in the buffer.
            let needleLen = prefixBytes.count
            var i = 0
            while i + needleLen <= bytes.count {
                if bytes[i] == 0x0A {
                    var match = true
                    for j in 1..<needleLen {
                        if toLowerAscii(bytes[i + j]) != prefixBytes[j] {
                            match = false; break
                        }
                    }
                    if match {
                        valueStart = i + needleLen
                        break
                    }
                }
                i += 1
            }
        }
        guard let start = valueStart else { return nil }
        // Walk forward to end of line (\r or \n).
        var end = start
        while end < bytes.count && bytes[end] != 0x0D && bytes[end] != 0x0A {
            end += 1
        }
        let valueBytes = Array(bytes[start..<end])
        guard let raw = String(bytes: valueBytes, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // ─── CBOR encode / decode ───────────────────────────────────

    /// Encode the SubmitSend internally-tagged variant. The payload
    /// is the raw RFC 5321 .eml the SDK wrote — UNCLE drops it into
    /// the validator's maildir verbatim, ANTIE picks it up the same
    /// way it would for any SMTP-delivered email.
    ///
    /// `sender_wallet` is load-bearing: UNCLE's wallet_ownership ACL
    /// rejects SubmitSend whose `sender_wallet` doesn't appear in the
    /// requesting fingerprint's owned-wallets list. Same gate as
    /// PullCheques. Empty string → ACL rejection → TCP closed without
    /// a framed response.
    ///
    /// `receiver_wallet` / `amount_atoms` are audit-only attestation
    /// per [[feedback_uncle_is_recording_carrier]] — UNCLE records but
    /// doesn't verify against the (sealed) payload, so leaving them
    /// blank is honest about the daemon not parsing the UMP body.
    ///
    /// UNCLE owns correlation end-to-end (Subject stamp + ANTIE
    /// skip-list mechanism), so no per-request id from Mac.
    ///
    /// **`payload` encoding** — Linux pinned `SubmitSend.payload` to
    /// CBOR byte string (major type 2) via `#[serde(with =
    /// "serde_bytes")]` at f37a97a0. The deserializer accepts both
    /// byte string and array-of-u8 for compat, but emitting byte
    /// string here halves the wire size on the carrier hot path
    /// (~1 MB UMP → ~500 KB instead of ~1 MB).
    private nonisolated static func encodeSubmitSend(payload: Data,
                                                      senderWallet: String) -> Data {
        let pairs: [(CborValue, CborValue)] = [
            (.text("t"),                .text("SubmitSend")),
            (.text("sender_email"),     .text("")),
            (.text("submitted_by"),     .text("UNCLE SAM")),
            (.text("sender_wallet"),    .text(senderWallet)),
            (.text("receiver_wallet"),  .text("")),
            (.text("amount_atoms"),     .uint(0)),
            (.text("reference"),        .null),
            (.text("payload"),          .bytes(payload)),
        ]
        return CborValue.map(pairs).encode()
    }

    /// Decode SubmitSendResponse — only field we care about right
    /// now is `witness_responses: Vec<Vec<u8>>` (added by Linux as
    /// the round-trip carrier-extension). Tolerates absence: returns
    /// empty array. Tolerates daemon `error` field: logs and returns
    /// empty.
    private nonisolated static func decodeSubmitSendResponseWitnesses(
        _ data: Data, endpoint: String
    ) -> [Data] {
        let value: CborValue
        do {
            value = try CborValue.decode(data)
        } catch {
            NSLog("[OutboxCarrierDaemon] %@:%@", endpoint,
                  "decode: \(error.localizedDescription)")
            return []
        }
        guard case .map(let pairs) = value else {
            NSLog("[OutboxCarrierDaemon] %@:%@", endpoint,
                  "SubmitSendResponse: expected map at root")
            return []
        }
        var lookup: [String: CborValue] = [:]
        for (k, v) in pairs {
            if case .text(let s) = k { lookup[s] = v }
        }
        guard case .some(.text(let tag)) = lookup["t"] else {
            NSLog("[OutboxCarrierDaemon] %@:%@", endpoint,
                  "SubmitSendResponse: missing 't' tag")
            return []
        }
        if tag != "SubmitSendResponse" {
            NSLog("[OutboxCarrierDaemon] %@:%@", endpoint,
                  "unexpected variant: \(tag)")
            return []
        }
        // Daemon-side error?
        if case .some(.map(let errPairs)) = lookup["error"] {
            var em: [String: CborValue] = [:]
            for (k, v) in errPairs {
                if case .text(let s) = k { em[s] = v }
            }
            let code = (em["code"].flatMap {
                if case .text(let s) = $0 { return s } else { return nil }
            }) ?? "?"
            let msg = (em["message"].flatMap {
                if case .text(let s) = $0 { return s } else { return nil }
            }) ?? ""
            NSLog("[OutboxCarrierDaemon] %@:%@", endpoint,
                  "UNCLE error \(code): \(msg)")
            return []
        }
        // witness_responses — new field. If absent, we're talking to
        // a pre-extension UNCLE binary.
        guard case .some(.array(let nodes)) = lookup["witness_responses"]
        else {
            NSLog("[OutboxCarrierDaemon] %@:%@", endpoint,
                  "SubmitSendResponse has no witness_responses (UNCLE pre-extension?)")
            return []
        }
        var out: [Data] = []
        out.reserveCapacity(nodes.count)
        for node in nodes {
            switch node {
            case .bytes(let b):
                out.append(b)
            case .array(let arr):
                let b = Data(arr.compactMap { item -> UInt8? in
                    if case .uint(let i) = item, i <= 255 { return UInt8(i) }
                    return nil
                })
                if !b.isEmpty { out.append(b) }
            default:
                continue
            }
        }
        return out
    }

    /// u32-BE length-prefixed TCP round-trip. Mirrors
    /// UncleGatewayClient.tcpRoundTrip — same framing, same
    /// timeout posture, separate copy to keep the daemon's
    /// dispatch graph independent.
    private nonisolated static func tcpRoundTrip(
        endpoint: String, framedRequest: Data
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let parts = endpoint.split(separator: ":")
            guard parts.count == 2,
                  let port = UInt16(parts[1])
            else {
                cont.resume(throwing: NSError(domain: "OutboxCarrierDaemon",
                                                code: 1,
                                                userInfo: [NSLocalizedDescriptionKey:
                                                "endpoint must be host:port"]))
                return
            }
            let host = String(parts[0])
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                cont.resume(throwing: NSError(domain: "OutboxCarrierDaemon",
                                                code: 2,
                                                userInfo: [NSLocalizedDescriptionKey:
                                                "invalid port \(port)"]))
                return
            }
            let queue = DispatchQueue(
                label: "uncle.sam.outbox.\(host).\(port)",
                qos: .userInitiated)
            let conn = NWConnection(host: NWEndpoint.Host(host),
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
            // Per-target timeout — UNCLE may hold the TCP open up to
            // its own configured submit_send_timeout_secs (90s default
            // per the design doc).
            queue.asyncAfter(deadline: .now() + UNCLE_SAM_OUTBOX_PER_TARGET_TIMEOUT_SECS) {
                resumeOnce(.failure(NSError(domain: "OutboxCarrierDaemon",
                                              code: 3,
                                              userInfo: [NSLocalizedDescriptionKey:
                                              "timeout after \(Int(UNCLE_SAM_OUTBOX_PER_TARGET_TIMEOUT_SECS))s"])))
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Self.sendAndReadReply(conn: conn,
                                           framedRequest: framedRequest,
                                           resume: resumeOnce)
                case .failed(let err):
                    resumeOnce(.failure(err))
                case .cancelled:
                    resumeOnce(.failure(NSError(
                        domain: "OutboxCarrierDaemon",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey:
                            "connection cancelled before reply"])))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    nonisolated private static func sendAndReadReply(
        conn: NWConnection,
        framedRequest body: Data,
        resume: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        var frame = Data()
        var lenBE = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &lenBE) { frame.append(contentsOf: $0) }
        frame.append(body)
        conn.send(content: frame,
                  completion: .contentProcessed { error in
            if let error = error {
                resume(.failure(error))
                return
            }
            conn.receive(minimumIncompleteLength: 4,
                         maximumLength: 4) { lenData, _, _, lenErr in
                if let lenErr = lenErr {
                    resume(.failure(lenErr))
                    return
                }
                guard let lenData = lenData, lenData.count == 4 else {
                    resume(.failure(NSError(domain: "OutboxCarrierDaemon",
                                              code: 5,
                                              userInfo: [NSLocalizedDescriptionKey:
                                              "short read on reply length"])))
                    return
                }
                let replyLen = lenData.withUnsafeBytes { raw -> UInt32 in
                    raw.load(as: UInt32.self).bigEndian
                }
                let n = Int(replyLen)
                if n == 0 || n > UNCLE_SAM_MAX_ENVELOPE_BYTES {
                    resume(.failure(NSError(domain: "OutboxCarrierDaemon",
                                              code: 6,
                                              userInfo: [NSLocalizedDescriptionKey:
                                              "reply length \(n) out of range"])))
                    return
                }
                conn.receive(minimumIncompleteLength: n,
                             maximumLength: n) { body, _, _, bodyErr in
                    if let bodyErr = bodyErr {
                        resume(.failure(bodyErr))
                        return
                    }
                    guard let body = body, body.count == n else {
                        resume(.failure(NSError(domain: "OutboxCarrierDaemon",
                                                  code: 7,
                                                  userInfo: [NSLocalizedDescriptionKey:
                                                  "short read on reply body"])))
                        return
                    }
                    resume(.success(body))
                }
            }
        })
    }
}
