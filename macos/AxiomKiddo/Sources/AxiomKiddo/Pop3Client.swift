import Foundation

// =================================================================
// Pop3Client — minimal RFC 1939 POP3 client.
//
// Drains a mailbox: USER, PASS, STAT, RETR <n>, DELE <n>, QUIT.
// No APOP, no UIDL-based dedup (every fetch drains the server-side
// spool, the wallet's inbox/new/ is the dedup boundary).
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

    /// Pull all pending messages from the server, mark each for delete,
    /// QUIT to commit. Returns the message bodies in receipt order.
    func fetchAll() throws -> [Pop3Message] {
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

        var out: [Pop3Message] = []
        for n in 1...count {
            try conn.writeAll(Data("RETR \(n)\r\n".utf8))
            // RETR response: "+OK ..." then multiline body terminated
            // by "\r\n.\r\n", with byte-stuffing per §3.
            let head = try conn.readLine()
            try expectOk(head)
            let body = try conn.readMultiline()
            out.append(Pop3Message(index: n, body: body))
            try send(conn, "DELE \(n)\r\n")
        }

        // QUIT commits the DELEs.
        try conn.writeAll(Data("QUIT\r\n".utf8))
        _ = try? conn.readLine()
        return out
    }

    // MARK: -

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
