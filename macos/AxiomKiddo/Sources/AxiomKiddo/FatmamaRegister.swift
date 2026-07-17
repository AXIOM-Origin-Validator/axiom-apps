import Foundation

// =================================================================
// FatmamaRegister — one-shot dev-environment account provisioning.
//
// FATMAMA (scripts/fatmama.py on the dev box) is the loopback / LAN
// SMTP+POP3 relay that fronts the dev AXIOM env. Per-tester wallet
// emails have to be registered there before SMTP delivery + POP3
// polling will work — historically by hand-editing
// `fatmama-routes.json` on the dev box and restarting.
//
// To skip the manual step, FATMAMA accepts a non-standard SMTP verb
// `XAXIOM-REGISTER <email>` (the `X` prefix is RFC 5321 §2.2.2's
// reserved namespace for site-local extensions). This module is the
// Kiddo-side sender:
//
//     220 fatmama.dev ready
//     > EHLO axiomkiddo
//     250 ok
//     > XAXIOM-REGISTER alice@axiom
//     250 OK — alice@axiom registered
//     > QUIT
//     221 bye
//
// **Dev-only by design.** Real SMTP servers reject unknown verbs
// with 500/502, which is fine — the button is only ever surfaced in
// the `.axiomDev` Kiddo flow.
// =================================================================

enum FatmamaRegisterError: Error, LocalizedError {
    case connectFailed(String)
    case badResponse(Int, String)

    var errorDescription: String? {
        switch self {
        case .connectFailed(let s):
            return "connect: \(s)"
        case .badResponse(let code, let line):
            return "FATMAMA \(code): \(line)"
        }
    }
}

enum FatmamaRegister {
    /// Open one connection to FATMAMA's SMTP port, register `email`,
    /// QUIT. Throws on any non-2xx response. Idempotent on the
    /// server side — re-registering the same address returns 250 OK.
    static func register(host: String, port: Int, email: String,
                         timeoutSecs: Double = 10) throws {
        let conn = TcpConn(host: host, port: port,
                           useTLS: false, timeoutSecs: timeoutSecs)
        do {
            try conn.connect()
        } catch {
            throw FatmamaRegisterError.connectFailed(
                error.localizedDescription
            )
        }
        defer { conn.close() }

        // 220 banner. Greet even if FATMAMA's banner format drifts —
        // we only care that the first digit is 2.
        let greet = try readResponse(conn)
        guard greet.code / 100 == 2 else {
            throw FatmamaRegisterError.badResponse(greet.code, greet.last)
        }

        try writeAndCheck(conn, "EHLO axiomkiddo\r\n", expected: 250)
        try writeAndCheck(conn,
                          "XAXIOM-REGISTER \(email)\r\n",
                          expected: 250)

        // QUIT is best-effort — FATMAMA may close immediately after
        // the 221 / on shutdown. Ignore any error here so a missing
        // QUIT response doesn't mask the successful register.
        _ = try? conn.writeAll(Data("QUIT\r\n".utf8))
    }

    /// Drain one SMTP response (may span multiple `XXX-…` continuation
    /// lines before the `XXX …` terminator) and return the code from
    /// the first line plus the text of the last line. Duplicates
    /// SmtpClient's helper deliberately — keeps the two clients
    /// independent so a future TCP-only register doesn't have to drag
    /// the full SMTP code along.
    private static func readResponse(_ conn: TcpConn) throws
        -> (code: Int, last: String) {
        var firstCode = 0
        var lastLine = ""
        while true {
            let raw = try conn.readLine()
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            lastLine = trimmed
            if firstCode == 0 {
                firstCode = Int(trimmed.prefix(3)) ?? 0
            }
            guard trimmed.count >= 4 else { break }
            let sepIdx = trimmed.index(trimmed.startIndex, offsetBy: 3)
            if trimmed[sepIdx] != "-" { break }
        }
        return (firstCode, lastLine)
    }

    private static func writeAndCheck(_ conn: TcpConn, _ cmd: String,
                                       expected: Int) throws {
        try conn.writeAll(Data(cmd.utf8))
        let resp = try readResponse(conn)
        if resp.code != expected {
            throw FatmamaRegisterError.badResponse(resp.code, resp.last)
        }
    }
}
