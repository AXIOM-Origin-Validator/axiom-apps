import Foundation

// =================================================================
// ConnectionTest — "does this account actually work?", answered in a second.
//
// Before this, the only way to find out was to save the account and wait for
// a background tick whose verdict went to the menu-bar UI and nowhere else.
// A wrong password looked exactly like a wrong host, which looked exactly
// like the app being wedged (2026-09-11 / 09-12: an evening of `sample`,
// `lsof` and hand-replayed POP3 to establish "the login is being refused").
//
// Sends nothing and deletes nothing: SMTP connects, EHLOs, authenticates and
// quits; POP3 connects, logs in, asks for a message count and quits.
//
// EVERY FAILURE COUNTS, including timeouts — corrected 2026-09-12 (the owner:
// "a ban can be a network timeout.. it was banned from firewall"). An earlier
// draft counted only refused logins on the theory that a timeout is merely a
// network problem. That is backwards: a provider that has blocked your IP
// DROPS the packets, so the ban itself presents as a timeout. Counting only
// rejections would stop counting at the exact moment the block took effect.
//
// The KIND is still recorded, because the advice differs — a refusal means
// fix the password, a timeout after refusals means you may already be
// blocked — but both move the same counter.
// =================================================================

/// One leg's outcome.
enum LegResult: Equatable {
    case ok(String)             // human-readable detail, e.g. "3 messages waiting"
    case authRejected(String)   // the server said no
    case failed(String)         // never reached the server — counts too (a block looks like this)

    var isOK: Bool { if case .ok = self { return true }; return false }
    var isAuthRejected: Bool { if case .authRejected = self { return true }; return false }

    var detail: String {
        switch self {
        case .ok(let d), .authRejected(let d), .failed(let d): return d
        }
    }
}

struct ConnectionTestResult {
    let sending: LegResult
    let receiving: LegResult

    var allOK: Bool { sending.isOK && receiving.isOK }
    /// True when either leg was REFUSED (as opposed to unreachable).
    var anyAuthRejected: Bool { sending.isAuthRejected || receiving.isAuthRejected }
    /// True when either leg never reached the server. A block looks like this.
    var anyUnreachable: Bool {
        if case .failed = sending { return true }
        if case .failed = receiving { return true }
        return false
    }
}

enum ConnectionTest {

    /// After this many consecutive refused logins, warn before trying again.
    ///
    /// Three is deliberately below every provider threshold worth guessing at:
    /// the warning has to arrive while the next attempt is still safe, not
    /// after the ban. The owner, 2026-09-12: "once achieve 3rd fail, pop a warning
    /// to warn user his ip may get banned if fail again".
    static let warnAfterFailures = 3

    /// Run both legs. BLOCKING — call from a background queue.
    static func run(account: KiddoAccount) -> ConnectionTestResult {
        ConnectionTestResult(sending: testSending(account),
                             receiving: testReceiving(account))
    }

    private static func testSending(_ a: KiddoAccount) -> LegResult {
        guard !a.smtpHost.isEmpty else { return .failed("No sending server set.") }
        let secret = resolveOutbound(a)
        let client = SmtpClient(
            host: a.smtpHost, port: a.smtpPort,
            useTLS: a.smtpUseTLS,
            username: a.username.isEmpty ? nil : a.username,
            password: secret.isEmpty ? nil : secret
        )
        do {
            try client.verifyLogin()
            return .ok(a.username.isEmpty ? "Connected (no sign-in needed)."
                                          : "Signed in as \(a.username).")
        } catch {
            return classify(error, what: "sending")
        }
    }

    private static func testReceiving(_ a: KiddoAccount) -> LegResult {
        guard !a.pop3Host.isEmpty else { return .failed("No receiving server set.") }
        let user = !a.pop3Username.isEmpty ? a.pop3Username
                 : (a.username.isEmpty ? a.walletEmail : a.username)
        let secret = resolveInbound(a)
        do {
            let n: Int
            if a.inboundProtocol == .imap {
                n = try ImapClient(host: a.pop3Host, port: a.pop3Port,
                                   username: user, password: secret,
                                   useTLS: a.pop3UseTLS, folder: a.imapFolder).verifyLogin()
                return .ok("Signed in as \(user) — \(n) message\(n == 1 ? "" : "s") in \(a.imapFolder.isEmpty ? "INBOX" : a.imapFolder).")
            }
            n = try Pop3Client(host: a.pop3Host, port: a.pop3Port,
                               mailbox: user,
                               password: secret.isEmpty ? "x" : secret,
                               useTLS: a.pop3UseTLS).verifyLogin()
            return .ok("Signed in as \(user) — \(n) message\(n == 1 ? "" : "s") waiting.")
        } catch {
            return classify(error, what: "receiving")
        }
    }

    /// Refused-by-the-server vs couldn't-get-there. The distinction drives the
    /// counter, so it is made on the server's own reply rather than on a guess.
    private static func classify(_ error: Error, what: String) -> LegResult {
        let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        let lower = text.lowercased()

        // Reached the server and it said no.
        let refused = lower.contains("-err")           // POP3
            || lower.contains("535") || lower.contains("534") || lower.contains("538")
            || lower.contains("authentication") || lower.contains("password")
            || lower.contains("credential") || lower.contains("login")
        // Never got that far.
        let unreachable = lower.contains("timeout") || lower.contains("connect failed")
            || lower.contains("cancelled") || lower.contains("tls")

        if refused && !unreachable { return .authRejected(text) }
        return .failed(text)
    }

    private static func resolveOutbound(_ a: KiddoAccount) -> String {
        if !a.password.isEmpty { return a.password }
        guard a.hasKeychainPassword else { return "" }
        return PasswordKeychain.get(id: a.id) ?? ""
    }

    private static func resolveInbound(_ a: KiddoAccount) -> String {
        if !a.pop3Password.isEmpty { return a.pop3Password }
        if a.hasPop3KeychainPassword,
           let s = PasswordKeychain.get(id: a.id, slot: "pop3"), !s.isEmpty { return s }
        return resolveOutbound(a)
    }
}

/// Consecutive FAILED attempts per account, across launches.
///
/// Persisted because the risk it tracks lives at the PROVIDER, not in this
/// process: quitting the app does not un-ring five failed sign-ins. Reset to
/// zero the moment a test succeeds — the count means "in a row".
enum AuthFailureCount {
    private static func key(_ id: UUID) -> String { "authFailures.\(id.uuidString)" }
    private static func kindKey(_ id: UUID) -> String { "authFailureKind.\(id.uuidString)" }

    static func get(_ id: UUID) -> Int {
        UserDefaults.standard.integer(forKey: key(id))
    }

    /// What the most recent failure looked like — "rejected" or "unreachable".
    /// Kept because the same count means different things: refusals say the
    /// credentials are wrong, and a timeout arriving AFTER refusals is what a
    /// block looks like from the outside.
    static func lastKind(_ id: UUID) -> String {
        UserDefaults.standard.string(forKey: kindKey(id)) ?? ""
    }

    static func record(_ id: UUID, result: ConnectionTestResult) {
        guard !result.allOK else { reset(id); return }
        UserDefaults.standard.set(get(id) + 1, forKey: key(id))
        // A refusal is the more actionable of the two, so it wins the label
        // when a run produced both.
        UserDefaults.standard.set(result.anyAuthRejected ? "rejected" : "unreachable",
                                  forKey: kindKey(id))
    }

    static func reset(_ id: UUID) {
        UserDefaults.standard.removeObject(forKey: key(id))
        UserDefaults.standard.removeObject(forKey: kindKey(id))
    }

    /// The warning shown at the threshold. Says what is actually at stake and
    /// what to change — never just "try again".
    static func warning(_ count: Int, kind: String) -> String {
        let base = "\(count) attempts in a row have failed. Providers block an IP address after repeated failures, and a block looks exactly like a timeout — so trying again can make things worse rather than tell you more."
        switch kind {
        case "rejected":
            return base + " The server is refusing the sign-in: check the password (most providers need an app password, not your account password) and the username."
        case "unreachable":
            return base + " The server isn't answering at all. If earlier attempts were refused, you may already be blocked — wait before retrying, and check the host and port."
        default:
            return base
        }
    }
}
