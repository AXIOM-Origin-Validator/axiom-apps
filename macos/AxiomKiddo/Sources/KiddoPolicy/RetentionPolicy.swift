import Foundation
import CryptoKit

// =================================================================
// RetentionPolicy — what Kiddo is allowed to delete from a mail server.
//
// Part 2 of docs/AXIOM_DESIGN_CarrierHandoff.md. Three pieces, all local:
// the mode, the SDK's status file (read-only), and the seen-store that
// makes "leave everything" possible at all.
//
// WHY THIS EXISTS. Before this, the drain loop RETR'd and DELE'd every
// message it found, with no filter and no per-message state — so DELE was
// load-bearing as dedup, and pointing Kiddo at a mailbox that carried
// anything else deleted that mail server-side. Both halves are fixed here:
// the mode decides what may be deleted, and the seen-store decides what has
// already been delivered.
//
// A LIBRARY, separate from the app target, for one reason: this decision
// removes mail from someone's server irreversibly, so it has to be
// exercisable on its own. This Mac carries CommandLineTools without Xcode,
// so there is no XCTest and no swift-testing — `KiddoPolicyCheck` is the
// gate instead (`swift run KiddoPolicyCheck`) and exits non-zero when a
// case moves.
//
// KIDDO STILL KNOWS NO PROTOCOL. The only AXIOM-specific thing below is a
// header test for `Subject: AXIOM/…`, which the SDK and ANTIE both stamp.
// No CBOR is decoded, no wallet file is read, and the status file is read
// but NEVER written — the SDK owns it (design §2).
//
// EVERY UNCERTAINTY KEEPS THE MAIL. No status entry, no mode, an
// unreadable file, a message we cannot classify: all resolve to "keep".
// Lost state costs disk; a wrong delete costs someone's mail.
// =================================================================

/// What may be removed from the server once a message has been collected.
public enum RetentionMode: String, Codable, CaseIterable, Equatable {
    /// Never DELE. Requires the seen-store, or every poll re-delivers.
    case leaveEverything
    /// DELE only messages that are AXIOM's *and* that the wallet has used.
    case axiomOnly
    /// DELE everything collected — the behaviour every account had before
    /// this type existed.
    case deleteAll

    /// Shown in Kiddo's Settings.
    public var title: String {
        switch self {
        case .leaveEverything: return "Leave everything"
        case .axiomOnly:       return "Delete AXIOM mail only"
        case .deleteAll:       return "Delete everything"
        }
    }

    /// One line, in the user's terms — what happens to *their* mail.
    public var detail: String {
        switch self {
        case .leaveEverything:
            return "Nothing is ever removed from the server. Choose this if the mailbox carries anything besides AXIOM."
        case .axiomOnly:
            return "Anything that isn't an AXIOM message is left untouched. AXIOM mail is removed once this wallet has used it."
        case .deleteAll:
            return "Everything collected is removed from the server. Only for an address nothing else uses."
        }
    }

}

/// The decision, as one pure function so it can be tested exhaustively.
///
/// `wasConsumed` comes from the SDK's status file; `isAxiomMail` from the
/// message's own headers. Both are *evidence*, and absent evidence keeps.
public func mayDeleteFromServer(mode: RetentionMode,
                         isAxiomMail: Bool,
                         wasConsumed: Bool) -> Bool {
    switch mode {
    case .leaveEverything:
        return false
    case .axiomOnly:
        // BOTH conditions. AXIOM mail the wallet has not used yet may be a
        // cheque it still needs; non-AXIOM mail is never ours to delete.
        return isAxiomMail && wasConsumed
    case .deleteAll:
        return true
    }
}

/// True iff the message's own header block carries `Subject: AXIOM/…`.
///
/// Deliberately strict: the HEADER BLOCK only (up to the first blank line),
/// and the subject value must *start* with `AXIOM/`. A body that merely
/// mentions the string is not ours. Both directions stamp this subject —
/// the SDK on requests, ANTIE on replies and cheques.
///
/// A message we cannot parse reads as NOT AXIOM, which keeps it.
public func messageIsAxiomMail(_ body: Data) -> Bool {
    // Headers are ASCII; 16 KiB is far past any real header block, and it
    // keeps this off the hot path for a 127 KB base64 cheque body.
    let head = body.prefix(16 * 1024)
    guard let text = String(data: head, encoding: .utf8)
            ?? String(data: head, encoding: .isoLatin1) else { return false }

    for rawLine in text.components(separatedBy: "\n") {
        // `.whitespacesAndNewlines`, NOT `.whitespaces`: the latter is space
        // and tab only, so on CRLF mail the blank separator line arrives as
        // "\r", tests as non-empty, and the scan runs straight on into the
        // BODY — where a quoted `Subject: AXIOM/…` then reads as ours and
        // `.axiomOnly` deletes someone's mail. Caught by KiddoPolicyCheck on
        // its first run, 2026-09-11.
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return false }               // end of header block
        guard line.lowercased().hasPrefix("subject:") else { continue }
        let value = line.dropFirst("subject:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("AXIOM/")
    }
    return false
}

// MARK: - The SDK's status file (read-only)

/// Reader for `<walletDir>/carrier/status.jsonl` — the SDK's half of the
/// contract. One JSONL line per message the wallet consumed, keyed on the
/// filename WE chose when we landed it in `inbox/new/`.
///
/// Kiddo never writes this file. It is also allowed to be missing, short, or
/// torn: unparseable lines are skipped and a missing file yields an empty
/// set, which means nothing gets deleted in `.axiomOnly`.
public struct CarrierStatus {
    /// Filenames the wallet reports as consumed.
    public let consumed: Set<String>

    public static func read(walletDir: String) -> CarrierStatus {
        let path = "\(walletDir)/carrier/status.jsonl"
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return CarrierStatus(consumed: [])
        }
        var names = Set<String>()
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)) as? [String: Any],
                  let file = obj["file"] as? String,
                  let verdict = obj["verdict"] as? String else { continue }
            // Only `consumed` licenses a delete today. An unknown verdict is
            // a NEWER SDK talking to an older Kiddo — ignore it rather than
            // guess, and the message stays on the server.
            if verdict == "consumed" { names.insert(file) }
        }
        return CarrierStatus(consumed: names)
    }
}

// MARK: - Seen-store (what makes "leave everything" possible)

/// Per-account record of messages already delivered to a wallet, and of the
/// filename each was delivered AS.
///
/// The filename matters as much as the key. A message can only be deleted
/// once the wallet reports having used it, and the wallet names it by the
/// file we wrote — which does not exist until after we have landed it. So
/// deletion is always a LATER tick's decision, and this store is what
/// carries the fact across ticks.
///
/// POP3 has no server-side read flag, so without this a mode that never
/// DELEs would re-deliver the whole mailbox on every poll — which is why
/// DELE had been doing this job. Keys are preferred in this order:
///
///   `u:<UIDL>`  — the server's own stable id, when it supports UIDL
///   `h:<sha256>` — a hash of the message bytes, when it does not
///
/// The hash fallback is not a nicety: a server without UIDL would otherwise
/// force a choice between duplicating forever and deleting against the
/// user's wishes.
///
/// Bounded, oldest-first. Losing this file re-delivers (the SDK tolerates
/// duplicates — carriers are at-least-once); it must never cause a delete.
public struct SeenStore {
    /// What we remember about one delivered message.
    public struct Entry: Codable, Equatable {
        /// The maildir filename we wrote into `inbox/new/` — the name the
        /// SDK reports back in its status file.
        public let name: String
        /// Whether its headers said `Subject: AXIOM/…`, decided when we had
        /// the bytes. Recorded so a later tick can apply `.axiomOnly`
        /// without downloading the message again.
        public let axiom: Bool
    }

    private static let cap = 4000
    private let fileURL: URL
    private var order: [String]
    private var entries: [String: Entry]

    public init(accountID: UUID) {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("AxiomKiddo/seen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("\(accountID.uuidString).json")

        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        self.entries = loaded
        // Insertion order is not preserved across a reload; the cap then
        // evicts in dictionary order, which is arbitrary but still bounded.
        // Evicting the wrong entry costs one re-delivery, never a delete.
        self.order = Array(loaded.keys)
    }

    /// Key for an IMAP message. A UID is stable only within one UIDVALIDITY,
    /// so both are the identity; the `i:` namespace keeps it apart from a
    /// POP3 UIDL (`u:`) — one account is one protocol, but the store must not
    /// depend on that.
    public static func imapKey(uidValidity: UInt32, uid: UInt32) -> String {
        "i:\(uidValidity)/\(uid)"
    }

    /// Key for a fetched message: the server's UIDL if it gave us one, else
    /// a content hash.
    public static func key(uid: String?, body: Data) -> String {
        if let uid, !uid.isEmpty { return "u:\(uid)" }
        let digest = SHA256.hash(data: body)
        return "h:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// What we know about this message, or nil if we have never seen it.
    public func entry(_ key: String) -> Entry? { entries[key] }

    public mutating func record(key: String, name: String, axiom: Bool) {
        guard entries[key] == nil else { return }
        entries[key] = Entry(name: name, axiom: axiom)
        order.append(key)
        if order.count > Self.cap {
            let drop = order.count - Self.cap
            for k in order.prefix(drop) { entries.removeValue(forKey: k) }
            order.removeFirst(drop)
        }
    }

    /// Forget a message we just deleted from the server — it can never come
    /// back, so keeping it would only crowd the cap.
    public mutating func forget(key: String) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    /// Best-effort persist. A failed write costs a re-delivery, never a mail.
    public func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
