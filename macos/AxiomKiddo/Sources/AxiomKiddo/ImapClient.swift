import Foundation
import KiddoPolicy

// =================================================================
// ImapClient — minimal RFC 3501 IMAP client, the folder-scoped sibling of
// Pop3Client. Built 2026-09-13 (docs/AXIOM_DESIGN_CarrierHandoff.md §9.5:
// "POP3 drains a mailbox and cannot scope to a folder, so 'leave everything'
// stays expensive and a shared mailbox stays risky").
//
// SAME CONTRACT AS Pop3Client.fetch — three closures, no policy here:
//   alreadyDelivered(key)   consulted before the download (UIDs are free)
//   mayDeleteDelivered(key) the wallet already has it; may it go now?
//   mayDeleteFresh(msg)     just downloaded; only `.deleteAll` says yes
// "Delete" on IMAP is `UID STORE +FLAGS (\Deleted)` followed by ONE `EXPUNGE`
// at the end of the session — nothing is removed until then, and a session
// that fails midway removes nothing (RFC 3501 §6.4.3).
//
// Keys are `i:<UIDVALIDITY>/<UID>` (SeenStore.imapKey): a UID is only stable
// within one UIDVALIDITY, so both are part of the identity. Namespaced `i:`
// so an IMAP key can never be mistaken for a POP3 UIDL (`u:`).
//
// Scope: LOGIN (no SASL), SELECT one folder, UID SEARCH ALL, UID FETCH
// BODY.PEEK[] (PEEK — reading must not set \Seen behind the user's back),
// literals, STORE/EXPUNGE, LOGOUT. Implicit TLS on 993 for real accounts;
// plain TCP is allowed for a dev server. One session per poll tick.
// =================================================================

enum ImapError: Error, LocalizedError {
    case session(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .session(let s): return "IMAP: \(s)"
        case .parse(let s):   return "IMAP parse: \(s)"
        }
    }
}

struct ImapMessage {
    let uid: UInt32
    let uidValidity: UInt32
    let body: Data
    var key: String { SeenStore.imapKey(uidValidity: uidValidity, uid: uid) }
}

struct ImapClient {
    let host: String
    let port: Int
    let username: String
    let password: String
    let useTLS: Bool
    let folder: String
    let timeoutSecs: Double

    init(host: String, port: Int, username: String, password: String,
         useTLS: Bool = true, folder: String = "INBOX", timeoutSecs: Double = 30) {
        self.host = host; self.port = port
        self.username = username; self.password = password
        self.useTLS = useTLS
        self.folder = folder.isEmpty ? "INBOX" : folder
        self.timeoutSecs = timeoutSecs
    }

    /// Collect pending messages from `folder`, letting the CALLER decide what
    /// may be deleted and what has already been delivered. Returns the
    /// messages newly downloaded this session, in UID order.
    func fetch(alreadyDelivered: (String) -> Bool,
               mayDeleteDelivered: (String) -> Bool,
               mayDeleteFresh: (ImapMessage) -> Bool) throws -> [ImapMessage] {
        let conn = TcpConn(host: host, port: port, useTLS: useTLS, timeoutSecs: timeoutSecs)
        try conn.connect()
        defer { conn.close() }
        var s = Session(conn: conn)
        try s.greeting()
        try s.login(username, password)
        let validity = try s.select(folder)
        let uids = try s.searchAll()

        var out: [ImapMessage] = []
        var flagged = 0
        for uid in uids {
            let key = SeenStore.imapKey(uidValidity: validity, uid: uid)
            if alreadyDelivered(key) {
                if mayDeleteDelivered(key) { try s.flagDeleted(uid); flagged += 1 }
                continue
            }
            let body = try s.fetchBody(uid)
            let msg = ImapMessage(uid: uid, uidValidity: validity, body: body)
            out.append(msg)
            if mayDeleteFresh(msg) { try s.flagDeleted(uid); flagged += 1 }
        }
        // EXPUNGE commits every \Deleted at once — the IMAP counterpart of
        // POP3's QUIT committing the DELEs.
        if flagged > 0 { try s.expunge() }
        try s.logout()
        return out
    }

    /// Connect, log in, select the folder, disconnect. Nothing downloaded,
    /// nothing deleted. Returns the folder's message count (EXISTS).
    func verifyLogin() throws -> Int {
        let conn = TcpConn(host: host, port: port, useTLS: useTLS, timeoutSecs: timeoutSecs)
        try conn.connect()
        defer { conn.close() }
        var s = Session(conn: conn)
        try s.greeting()
        try s.login(username, password)
        _ = try s.select(folder)
        let n = s.lastExists
        try s.logout()
        return n
    }

    // MARK: - protocol session

    /// One tagged-command session. Untagged replies are collected per
    /// command so callers can pull `* N EXISTS`, `* SEARCH …`, `UIDVALIDITY`.
    private struct Session {
        let conn: TcpConn
        private var tagN = 0
        private(set) var lastExists = 0

        init(conn: TcpConn) { self.conn = conn }

        mutating func greeting() throws {
            let g = try conn.readLine()
            guard g.hasPrefix("* OK") || g.hasPrefix("* PREAUTH") else {
                throw ImapError.session(g.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        /// Send one command and read until its tagged completion. Returns the
        /// untagged lines. Throws with the server's own words on NO / BAD —
        /// that string is what a user needs to see for a refused login.
        mutating func command(_ text: String) throws -> [String] {
            tagN += 1
            let tag = String(format: "A%03d", tagN)
            try conn.writeAll(Data("\(tag) \(text)\r\n".utf8))
            var untagged: [String] = []
            while true {
                let line = try conn.readLine()
                if line.hasPrefix("\(tag) ") {
                    let rest = line.dropFirst(tag.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                    if rest.hasPrefix("OK") { return untagged }
                    throw ImapError.session(rest)
                }
                // A literal announces N bytes follow the CRLF; keep them
                // attached to their line so fetchBody can find them.
                if let n = Session.literalLength(line) {
                    let bytes = try conn.readExact(n)
                    untagged.append(line)
                    untagged.append(Session.literalMarker + bytes.base64EncodedString())
                    continue
                }
                untagged.append(line)
            }
        }

        static let literalMarker = "\u{0}LITERAL:"

        static func literalLength(_ line: String) -> Int? {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasSuffix("}"), let open = t.lastIndex(of: "{") else { return nil }
            return Int(t[t.index(after: open)..<t.index(before: t.endIndex)])
        }

        mutating func login(_ user: String, _ pass: String) throws {
            _ = try command("LOGIN \(Session.quote(user)) \(Session.quote(pass))")
        }

        /// SELECT; returns UIDVALIDITY (required by RFC 3501 §6.3.1).
        mutating func select(_ folder: String) throws -> UInt32 {
            let lines = try command("SELECT \(Session.quote(folder))")
            var validity: UInt32? = nil
            for l in lines {
                if let r = l.range(of: "[UIDVALIDITY "), let end = l[r.upperBound...].firstIndex(of: "]") {
                    validity = UInt32(l[r.upperBound..<end])
                }
                let parts = l.split(separator: " ")
                if parts.count >= 3, parts[0] == "*", parts[2].hasPrefix("EXISTS"), let n = Int(parts[1]) {
                    lastExists = n
                }
            }
            guard let v = validity else { throw ImapError.parse("SELECT: no UIDVALIDITY") }
            return v
        }

        mutating func searchAll() throws -> [UInt32] {
            let lines = try command("UID SEARCH ALL")
            var uids: [UInt32] = []
            for l in lines where l.hasPrefix("* SEARCH") {
                uids += l.dropFirst("* SEARCH".count).split(separator: " ").compactMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            return uids.sorted()
        }

        mutating func fetchBody(_ uid: UInt32) throws -> Data {
            let lines = try command("UID FETCH \(uid) (BODY.PEEK[])")
            for l in lines where l.hasPrefix(Session.literalMarker) {
                guard let d = Data(base64Encoded: String(l.dropFirst(Session.literalMarker.count))) else {
                    throw ImapError.parse("FETCH \(uid): bad literal")
                }
                return d
            }
            throw ImapError.parse("FETCH \(uid): no literal in reply")
        }

        mutating func flagDeleted(_ uid: UInt32) throws {
            _ = try command("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
        }

        mutating func expunge() throws { _ = try command("EXPUNGE") }
        mutating func logout() throws { _ = try? command("LOGOUT") }

        /// IMAP quoted-string: escape backslash and double quote.
        static func quote(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
    }
}
