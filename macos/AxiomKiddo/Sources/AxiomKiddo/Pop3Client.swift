import Foundation

// =================================================================
// Pop3Client — minimal RFC 1939 POP3 client.
//
// Walks a mailbox: USER, PASS, STAT, UIDL, RETR <n>, maybe DELE <n>, QUIT.
// No APOP.
//
// ⚠ CORRECTED 2026-09-11 — this header used to read "No APOP, no UIDL-based
// dedup (every fetch drains the server-side spool, the wallet's inbox/new/
// is the dedup boundary)". That was true and it was the bug: DELE was
// load-bearing as dedup, so not deleting was impossible and any mailbox
// Kiddo touched got drained. Deletion is now the CALLER's decision, per
// message, and UIDL (or a content hash) carries the dedup instead — see
// RetentionPolicy.swift and docs/AXIOM_DESIGN_CarrierHandoff.md §5.
//
// Two configurations behind one struct:
//
//   - Dev / FATMAMA: plain TCP, `useTLS: false`, password "x".
//     Behaviour unchanged from v0.
//   - Real email: implicit TLS on connect (POP3S, port 995),
//     `useTLS: true` plus the provider's POP3 password (often the
//     same as SMTP, e.g. a Gmail app password).
//
// One short-lived session per poll tick. Connection reuse is a
// follow-up if poll rate exceeds the server's idle timeout.
// =================================================================

enum Pop3Error: Error, LocalizedError {
    case session(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .session(let s): return "POP3: \(s)"
        case .parse(let s):   return "POP3 parse: \(s)"
        }
    }
}

struct Pop3Message {
    let index: Int
    /// The server's stable id for this message, when it supports UIDL.
    /// `nil` means the caller must fall back to a content hash.
    let uid: String?
    let body: Data
}

struct Pop3Client {
    let host: String
    let port: Int
    let mailbox: String
    let password: String
    let useTLS: Bool
    let timeoutSecs: Double

    init(host: String, port: Int, mailbox: String,
         password: String = "x",
         useTLS: Bool = false,
         timeoutSecs: Double = 30) {
        self.host = host
        self.port = port
        self.mailbox = mailbox
        self.password = password
        self.useTLS = useTLS
        self.timeoutSecs = timeoutSecs
    }

    /// Collect pending messages, letting the CALLER decide what may be
    /// deleted and what has already been delivered.
    ///
    /// Three closures, each with one job, and no policy in this file:
    ///
    /// - `alreadyDelivered(key)` — consulted BEFORE the download, so a
    ///   message already handed to the wallet costs nothing but its UIDL
    ///   line. Only possible when the server supports UIDL; without one
    ///   there is no id until we hold the bytes.
    /// - `mayDeleteDelivered(key)` — the message is on the server and the
    ///   wallet already has it. This is the arm that actually deletes under
    ///   `.axiomOnly`, because "the wallet used it" can only become true on
    ///   a tick AFTER the one that delivered it.
    /// - `mayDeleteFresh(message)` — just downloaded, so the wallet cannot
    ///   have used it yet. Only `.deleteAll` says yes here.
    ///
    /// Returns the messages newly downloaded this session, in receipt order.
    func fetch(alreadyDelivered: (String) -> Bool,
               mayDeleteDelivered: (String) -> Bool,
               mayDeleteFresh: (Pop3Message) -> Bool) throws -> [Pop3Message] {
        let conn = TcpConn(host: host, port: port,
                           useTLS: useTLS, timeoutSecs: timeoutSecs)
        try conn.connect()
        defer { conn.close() }

        try expectOk(try conn.readLine())                      // +OK ready
        try send(conn, "USER \(mailbox)\r\n")
        try send(conn, "PASS \(password)\r\n")

        // Count messages via STAT — cheaper than LIST when we don't
        // need per-msg sizes.
        try conn.writeAll(Data("STAT\r\n".utf8))
        let stat = try conn.readLine()
        let count = try parseStatCount(stat)

        // Empty mailbox — skip the RETR loop. We can't use `1...count`
        // when count == 0 because `1...0` is an invalid Range and traps
        // at construction time (before any `if count == 0 { break }`
        // inside the loop could fire).
        guard count > 0 else {
            try conn.writeAll(Data("QUIT\r\n".utf8))
            _ = try? conn.readLine()
            return []
        }

        // UIDL gives every message a stable id, so a mailbox we are NOT
        // draining can still be polled without re-delivering. Best-effort:
        // a server that refuses the verb leaves the map empty and the
        // caller hashes the bytes instead.
        let uids = (try? fetchUidl(conn)) ?? [:]

        var out: [Pop3Message] = []
        for n in 1...count {
            // Already delivered, and we can name it without downloading:
            // the only thing left to decide is whether it may go.
            if let uid = uids[n] {
                let key = "u:\(uid)"
                if alreadyDelivered(key) {
                    if mayDeleteDelivered(key) {
                        try send(conn, "DELE \(n)\r\n")
                    }
                    continue
                }
            }

            try conn.writeAll(Data("RETR \(n)\r\n".utf8))
            // RETR response: "+OK ..." then multiline body terminated
            // by "\r\n.\r\n", with byte-stuffing per §3.
            let head = try conn.readLine()
            try expectOk(head)
            let body = try conn.readMultiline()
            let msg = Pop3Message(index: n, uid: uids[n], body: body)
            out.append(msg)
            if mayDeleteFresh(msg) {
                try send(conn, "DELE \(n)\r\n")
            }
        }

        // QUIT commits the DELEs.
        try conn.writeAll(Data("QUIT\r\n".utf8))
        _ = try? conn.readLine()
        return out
    }

    /// Connect, log in, ask for the message count, disconnect. Nothing is
    /// downloaded and nothing is deleted.
    ///
    /// Exists so "does this account work?" can be answered in a second by a
    /// button, instead of saving and waiting for a background tick that
    /// reports only into the menu-bar UI.
    ///
    /// Throws `Pop3Error.session` carrying the SERVER's own words on a
    /// refused login — that string is what the user needs, and it is how the
    /// caller tells an auth rejection from a network failure.
    func verifyLogin() throws -> Int {
        let conn = TcpConn(host: host, port: port,
                           useTLS: useTLS, timeoutSecs: timeoutSecs)
        try conn.connect()
        defer { conn.close() }
        try expectOk(try conn.readLine())
        try send(conn, "USER \(mailbox)\r\n")
        try send(conn, "PASS \(password)\r\n")
        try conn.writeAll(Data("STAT\r\n".utf8))
        let count = try parseStatCount(try conn.readLine())
        try conn.writeAll(Data("QUIT\r\n".utf8))
        _ = try? conn.readLine()
        return count
    }

    // MARK: -

    /// `UIDL` with no argument: "+OK" then `<index> <uid>` lines to ".".
    /// Throws if the server rejects the verb, which the caller treats as
    /// "no ids available" rather than a failed poll.
    private func fetchUidl(_ conn: TcpConn) throws -> [Int: String] {
        try conn.writeAll(Data("UIDL\r\n".utf8))
        try expectOk(try conn.readLine())
        let listing = try conn.readMultiline()
        guard let text = String(data: listing, encoding: .utf8) else { return [:] }
        var map: [Int: String] = [:]
        for line in text.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ", maxSplits: 1)
            if parts.count == 2, let n = Int(parts[0]) {
                map[n] = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return map
    }

    private func send(_ conn: TcpConn, _ cmd: String) throws {
        try conn.writeAll(Data(cmd.utf8))
        try expectOk(try conn.readLine())
    }

    private func expectOk(_ line: String) throws {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.hasPrefix("+OK") {
            throw Pop3Error.session(trimmed)
        }
    }

    private func parseStatCount(_ line: String) throws -> Int {
        // "+OK <count> <total_octets>"
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        guard parts.count >= 2, parts[0] == "+OK", let n = Int(parts[1]) else {
            throw Pop3Error.parse("STAT: \(line)")
        }
        return n
    }
}
