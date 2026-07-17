import Foundation

// =================================================================
// FatmamaRoutes — dev-environment route teardown.
//
// Companion to FatmamaRegister. Where registration rides the SMTP
// `XAXIOM-REGISTER` verb (port 2525), route *deletion* is only
// exposed over FATMAMA's HTTP management port (scripts/fatmama.py
// `DEFAULT_HTTP_PORT = 2526`, `POST /routes/delete`). This module is
// the Kiddo-side sender for that one endpoint.
//
//     POST /routes/delete HTTP/1.1
//     Content-Type: application/json
//     { "addrs": ["alice@axiom.internal"], "with_maildir": true }
//
//     → 200 { "deleted": [...], "protected": [...], "remaining": N }
//
// **Dev-only by design.** Only ever called against the FATMAMA dev
// relay, and only for `@axiom.internal` addresses (the caller in
// SettingsView filters to the dev class before invoking). Validator
// routes are additionally hard-protected server-side
// (`_is_protected_route` — `axiom-first-penguin-*`) and skipped even
// if an address for one is passed, so this can never knock a
// validator's mailbox offline.
// =================================================================

enum FatmamaRoutesError: Error, LocalizedError {
    case connectFailed(String)
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .connectFailed(let s):
            return "connect: \(s)"
        case .badStatus(let code, let line):
            return "FATMAMA HTTP \(code): \(line)"
        }
    }
}

/// Parsed `POST /routes/delete` result — the counts FATMAMA reports
/// back, so the caller (and the user) can see exactly what happened.
struct FatmamaDeleteSummary {
    var deleted: Int
    var notFound: Int
    var protectedCount: Int
    var remaining: Int
}

enum FatmamaRoutes {
    /// FATMAMA's HTTP management port (`scripts/fatmama.py`
    /// `DEFAULT_HTTP_PORT`). Not stored per-account — a KiddoAccount
    /// only carries SMTP (2525) + POP3 (2527) — because route
    /// management is a fixed property of the dev relay, not something
    /// a tester reconfigures.
    static let defaultHttpPort = 2526

    /// `POST /routes/delete` — drop `addrs` from FATMAMA's route
    /// table. With `withMaildir`, also purges each address's
    /// `fatmama-mailbox-<slug>` directory (a full state reset, which
    /// is the point of a clean-up). Returns the parsed summary counts;
    /// throws on connect failure or any non-2xx status. Logs the raw
    /// exchange to the unified log (`log stream --predicate 'process
    /// == "AxiomKiddo"'`) so a failed clean-up is diagnosable.
    @discardableResult
    static func delete(host: String, httpPort: Int = defaultHttpPort,
                       addrs: [String], withMaildir: Bool = true,
                       timeoutSecs: Double = 10) throws -> FatmamaDeleteSummary {
        // Hand-roll the JSON. The only values are email addresses
        // (no embedded quotes / backslashes) and a bool, so a minimal
        // encoder is safe and keeps Kiddo dependency-free — same
        // spirit as the copied SMTP/conf parsers elsewhere in the app.
        let jsonAddrs = addrs
            .map { "\"\($0)\"" }
            .joined(separator: ",")
        let body = "{\"addrs\":[\(jsonAddrs)],\"with_maildir\":\(withMaildir)}"
        let bodyData = Data(body.utf8)

        NSLog("[Kiddo] FATMAMA delete → %@:%d addrs=%@",
              host, httpPort, addrs.joined(separator: ","))

        let conn = TcpConn(host: host, port: httpPort,
                           useTLS: false, timeoutSecs: timeoutSecs)
        do {
            try conn.connect()
        } catch {
            NSLog("[Kiddo] FATMAMA delete connect FAILED: %@",
                  error.localizedDescription)
            throw FatmamaRoutesError.connectFailed(error.localizedDescription)
        }
        defer { conn.close() }

        var req = "POST /routes/delete HTTP/1.1\r\n"
        req += "Host: \(host):\(httpPort)\r\n"
        req += "Content-Type: application/json\r\n"
        req += "Content-Length: \(bodyData.count)\r\n"
        req += "Connection: close\r\n"
        req += "\r\n"
        try conn.writeAll(Data(req.utf8))
        try conn.writeAll(bodyData)

        // FATMAMA sends `Connection: close`, so slurp the whole
        // response (status line + headers + JSON body) until EOF.
        let respData = conn.readUntilClose()
        let text = String(decoding: respData, as: UTF8.self)

        let statusLine = text
            .split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = statusLine.split(separator: " ")
        let code = parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
        NSLog("[Kiddo] FATMAMA delete ← %@", statusLine.isEmpty ? "(no status line)" : statusLine)
        guard (200..<300).contains(code) else {
            throw FatmamaRoutesError.badStatus(code, statusLine.isEmpty ? "no response" : statusLine)
        }

        // Body is after the blank line. Parse the summary counts;
        // absence just yields zeros (still a success).
        var summary = FatmamaDeleteSummary(deleted: 0, notFound: 0,
                                           protectedCount: 0, remaining: 0)
        if let sep = text.range(of: "\r\n\r\n") {
            let jsonBody = String(text[sep.upperBound...])
            if let obj = try? JSONSerialization.jsonObject(with: Data(jsonBody.utf8)) as? [String: Any] {
                summary.deleted = (obj["deleted"] as? [Any])?.count ?? 0
                summary.notFound = (obj["not_found"] as? [Any])?.count ?? 0
                summary.protectedCount = (obj["protected"] as? [Any])?.count ?? 0
                summary.remaining = obj["remaining"] as? Int ?? 0
            }
            NSLog("[Kiddo] FATMAMA delete summary: deleted=%d not_found=%d protected=%d remaining=%d",
                  summary.deleted, summary.notFound, summary.protectedCount, summary.remaining)
        }
        return summary
    }
}
