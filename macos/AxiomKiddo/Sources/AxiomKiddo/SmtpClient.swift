import Foundation
import Network

// =================================================================
// SmtpClient — minimal RFC 5321 SMTP client.
//
// Two configurations live behind the same struct:
//
//   - Dev / FATMAMA: plain TCP, no AUTH. Pass `useTLS: false`,
//     username/password nil. Behaviour unchanged from v0.
//   - Real email: implicit TLS on connect (port 465 SMTPS-style),
//     AUTH PLAIN after EHLO. Pass `useTLS: true` + non-nil
//     username/password.
//
// STARTTLS (port 587 "plain then upgrade") is NOT supported here —
// Network.framework can't swap an existing NWConnection's protocol
// stack to add TLS mid-session. Users with STARTTLS-only providers
// must pick a port their server also publishes implicit TLS on
// (Gmail/Fastmail accept 465). A future iteration can drop down to
// SecureTransport for a real STARTTLS path.
//
// Synchronous TCP via Network.framework — one short-lived
// NWConnection per deliver call. Errors throw `SmtpError` with the
// SMTP response or I/O reason that broke the session.
// =================================================================

enum SmtpError: Error, LocalizedError {
    case connectFailed(String)
    case readTimeout
    case writeError(String)
    case badResponse(Int, String)
    case malformedMessage

    var errorDescription: String? {
        switch self {
        case .connectFailed(let s): return "connect failed: \(s)"
        case .readTimeout:           return "read timeout"
        case .writeError(let s):     return "write error: \(s)"
        case .badResponse(let c, let s): return "SMTP \(c): \(s)"
        case .malformedMessage:      return "outbox message missing From: or To:"
        }
    }
}

struct SmtpClient {
    let host: String
    let port: Int
    let useTLS: Bool
    /// Optional AUTH PLAIN credentials. When both username and
    /// password are non-empty, an AUTH PLAIN command is issued after
    /// EHLO. Either empty → no auth (the FATMAMA / dev path).
    let username: String?
    let password: String?
    let timeoutSecs: Double

    init(host: String, port: Int,
         useTLS: Bool = false,
         username: String? = nil,
         password: String? = nil,
         timeoutSecs: Double = 30) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.username = username
        self.password = password
        self.timeoutSecs = timeoutSecs
    }

    /// Deliver a single RFC 5321 message to the relay. The body bytes
    /// are sent verbatim — the caller must produce a complete email
    /// (which the SDK's outbox writer does, see
    /// `sdk/client/src/outbox.rs::write_outbox_eml`).
    func deliver(envelope: Envelope, body: Data) throws {
        let conn = TcpConn(host: host, port: port,
                           useTLS: useTLS, timeoutSecs: timeoutSecs)
        try conn.connect()
        defer { conn.close() }

        try expect(220, smtpRead(conn))
        try writeAndCheck(conn, "EHLO axiomkiddo\r\n", expect: 250)

        // AUTH PLAIN per RFC 4616: base64("\0<user>\0<pass>"). Only
        // attempted when both credentials are non-empty; the FATMAMA
        // path leaves them nil/empty and skips auth entirely.
        if let u = username, let p = password,
           !u.isEmpty, !p.isEmpty {
            var blob = Data()
            blob.append(0)
            blob.append(contentsOf: u.utf8)
            blob.append(0)
            blob.append(contentsOf: p.utf8)
            try writeAndCheck(
                conn,
                "AUTH PLAIN \(blob.base64EncodedString())\r\n",
                expect: 235
            )
        }

        try writeAndCheck(conn, "MAIL FROM:<\(envelope.from)>\r\n", expect: 250)
        try writeAndCheck(conn, "RCPT TO:<\(envelope.to)>\r\n", expect: 250)
        try writeAndCheck(conn, "DATA\r\n", expect: 354)

        // Body goes straight onto the wire. The caller's bytes already
        // include CRLF line endings (the SDK builds them that way); we
        // tack on a trailing CRLF if missing, then the terminator.
        try conn.writeAll(body)
        if !body.suffix(2).elementsEqual([0x0D, 0x0A]) {
            try conn.writeAll(Data([0x0D, 0x0A]))
        }
        try writeAndCheck(conn, ".\r\n", expect: 250)
        // QUIT is best-effort — relay may close immediately.
        _ = try? conn.writeAll(Data("QUIT\r\n".utf8))
    }

    // MARK: - SMTP plumbing

    private func writeAndCheck(_ conn: TcpConn, _ cmd: String, expect: Int) throws {
        try conn.writeAll(Data(cmd.utf8))
        try self.expect(expect, smtpRead(conn))
    }

    /// Read a single SMTP response, which may span multiple lines.
    /// Continuation lines start with "XXX-"; the final line starts
    /// with "XXX " (space). Real SMTP servers reply to EHLO with one
    /// `250-...` line per advertised capability followed by a `250 ...`
    /// terminator; reading just one line of that response (the v0
    /// behaviour) left the rest of the capability list in the socket
    /// buffer, where it'd be misread as the response to the next
    /// command. Returns the code from the first line and the *last*
    /// line's text (which carries any human-readable error).
    private func smtpRead(_ conn: TcpConn) throws -> (code: Int, last: String) {
        var firstCode = 0
        var lastLine = ""
        while true {
            let raw = try conn.readLine()
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            lastLine = trimmed
            if firstCode == 0 {
                firstCode = Int(trimmed.prefix(3)) ?? 0
            }
            // Continuation marker is exactly one '-' at index 3; any
            // other 4th character (space, end-of-line, garbage) means
            // we've reached the final line and should stop reading.
            guard trimmed.count >= 4 else { break }
            let sepIdx = trimmed.index(trimmed.startIndex, offsetBy: 3)
            if trimmed[sepIdx] != "-" { break }
        }
        return (firstCode, lastLine)
    }

    private func expect(_ wanted: Int, _ resp: (code: Int, last: String)) throws {
        if resp.code != wanted {
            throw SmtpError.badResponse(resp.code, resp.last)
        }
    }
}

// =================================================================
// TcpConn — Network.framework wrapper that exposes blocking
// `writeAll` / `readLine` for the SMTP / POP3 clients. Each
// connection is short-lived (one SMTP delivery / one POP3 session),
// so we don't bother with async streams — semaphores give clean
// blocking semantics that line up with the line-protocol shape.
// =================================================================

final class TcpConn {
    let host: String
    let port: Int
    /// When `true`, the connection negotiates TLS at handshake time —
    /// "implicit TLS", as used by SMTPS port 465 and POP3S port 995.
    /// STARTTLS (port 587-style "upgrade an existing plain connection
    /// to TLS") is **not** supported: Network.framework doesn't expose
    /// an in-place protocol-stack swap, so we'd need a SecureTransport
    /// rewrite. Deferred to a future iteration.
    let useTLS: Bool
    let timeoutSecs: Double
    private var connection: NWConnection?
    private var readBuffer = Data()

    init(host: String, port: Int, useTLS: Bool = false, timeoutSecs: Double = 30) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.timeoutSecs = timeoutSecs
    }

    func connect() throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!
        )
        // `.tls` gives a default TLS-over-TCP parameter set whose
        // sec_protocol_options apply ATS-style trust evaluation
        // (system trust store, hostname check against `host`). That's
        // the right default — letting users add Gmail-style providers
        // with no extra config.
        let params: NWParameters = useTLS ? .tls : .tcp
        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        let sem = DispatchSemaphore(value: 0)
        var error: Error?
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                sem.signal()
            case .failed(let e):
                error = SmtpError.connectFailed(String(describing: e))
                sem.signal()
            case .cancelled:
                error = SmtpError.connectFailed("cancelled")
                sem.signal()
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))

        if sem.wait(timeout: .now() + timeoutSecs) == .timedOut {
            conn.cancel()
            throw SmtpError.connectFailed("timeout connecting to \(host):\(port)")
        }
        if let e = error { throw e }
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    func writeAll(_ data: Data) throws {
        guard let conn = connection else {
            throw SmtpError.writeError("connection closed")
        }
        let sem = DispatchSemaphore(value: 0)
        var error: Error?
        conn.send(content: data, completion: .contentProcessed { e in
            if let e = e { error = SmtpError.writeError(String(describing: e)) }
            sem.signal()
        })
        if sem.wait(timeout: .now() + timeoutSecs) == .timedOut {
            throw SmtpError.writeError("write timeout")
        }
        if let e = error { throw e }
    }

    /// Reads bytes until we have a complete CRLF-terminated line.
    /// Returns the line including the trailing CRLF.
    func readLine() throws -> String {
        while true {
            if let range = readBuffer.range(of: Data([0x0D, 0x0A])) {
                let lineEnd = range.upperBound
                let line = readBuffer.subdata(in: 0..<lineEnd)
                readBuffer.removeSubrange(0..<lineEnd)
                return String(data: line, encoding: .utf8) ?? ""
            }
            try readMore()
        }
    }

    /// Read until we hit the multi-line POP3 terminator (`\r\n.\r\n`).
    /// Returns everything before the terminator with byte-stuffing
    /// reversed (lines starting with `..` become `.`). RFC 1939 §3.
    func readMultiline() throws -> Data {
        let terminator = Data([0x0D, 0x0A, 0x2E, 0x0D, 0x0A]) // \r\n.\r\n
        // Edge case: response could start with ".\r\n" with no preceding
        // content — that's the empty case. We watch for either pattern.
        while true {
            if let range = readBuffer.range(of: terminator) {
                let body = readBuffer.subdata(in: 0..<range.lowerBound)
                readBuffer.removeSubrange(0..<range.upperBound)
                return unstuff(body)
            }
            // Also accept a leading ".\r\n" (zero-content case).
            if readBuffer.starts(with: Data([0x2E, 0x0D, 0x0A])) {
                readBuffer.removeSubrange(0..<3)
                return Data()
            }
            try readMore()
        }
    }

    private func unstuff(_ data: Data) -> Data {
        // Replace "\r\n.." with "\r\n." per RFC 1939 §3.
        var out = Data()
        out.reserveCapacity(data.count)
        var i = data.startIndex
        let crlfDotDot = Data([0x0D, 0x0A, 0x2E, 0x2E])
        while i < data.endIndex {
            if i + 4 <= data.endIndex && data[i..<i+4] == crlfDotDot {
                out.append(contentsOf: [0x0D, 0x0A, 0x2E])
                i += 4
            } else {
                out.append(data[i])
                i += 1
            }
        }
        // Leading ".." → "." at the very start (no preceding CRLF)
        if out.count >= 2 && out[0] == 0x2E && out[1] == 0x2E {
            out.remove(at: 0)
        }
        return out
    }

    private func readMore() throws {
        guard let conn = connection else {
            throw SmtpError.writeError("connection closed")
        }
        let sem = DispatchSemaphore(value: 0)
        var error: Error?
        var got: Data?
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, e in
            if let e = e { error = SmtpError.writeError(String(describing: e)) }
            got = data
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeoutSecs) == .timedOut {
            throw SmtpError.readTimeout
        }
        if let e = error { throw e }
        guard let chunk = got, !chunk.isEmpty else {
            throw SmtpError.readTimeout // peer closed mid-response
        }
        readBuffer.append(chunk)
    }

    /// Read every remaining byte until the peer closes the connection,
    /// returning the full accumulated buffer. For HTTP/1.x responses
    /// with `Connection: close`, the body length is delimited by EOF,
    /// so this is the right way to slurp status line + headers + body
    /// in one shot (a JSON body has no CRLF terminator, so `readLine`
    /// can't frame it). Any read error (peer close, timeout) ends the
    /// loop and returns whatever arrived — the caller validates.
    func readUntilClose() -> Data {
        while true {
            do { try readMore() } catch { break }
        }
        let out = readBuffer
        readBuffer.removeAll()
        return out
    }
}
