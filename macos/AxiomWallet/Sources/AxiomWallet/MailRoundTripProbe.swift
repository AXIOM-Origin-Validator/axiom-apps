import Foundation
import SwiftUI

// =================================================================
// MailRoundTripProbe — "check it works" before the claim can run.
//
// Part 3 of docs/AXIOM_DESIGN_CarrierHandoff.md. Replaces a check that
// cannot fail: onboarding gated on "AxiomKiddo is running and has an account
// for this wallet's email", which an account satisfies while being completely
// unreachable — wrong password, wrong server, mail filtered before the inbox.
// The failure then surfaced two steps later as a 60-second claim timeout with
// no explanation. Only a round trip means anything.
//
// HOW IT ROUND-TRIPS WITHOUT THE PROTOCOL. The probe is an ordinary email the
// wallet addresses to ITSELF, written into `<walletDir>/outbox/new/` exactly
// the way the SDK writes a witness request. Whatever agent is configured —
// AxiomKiddo here — ships it, the mail comes back through the user's mailbox,
// and the agent lands it in `<walletDir>/maildir/inbox/new/`. Seeing our own
// token arrive proves BOTH legs and every hop between them.
//
// No validator is involved, no protocol message is constructed, no wallet
// state is touched. This file talks to two directories and nothing else.
// =================================================================

@MainActor
final class MailRoundTripProbe: ObservableObject {

    enum State: Equatable {
        case idle
        /// Sent, waiting for it to come back.
        case running
        /// Came back. `seconds` is the observed round trip, which is worth
        /// showing — it is the user's first evidence of how fast their
        /// carrier is.
        case passed(seconds: Double)
        /// Did not come back inside the window.
        case failed(reason: String)
    }

    @Published private(set) var state: State = .idle

    /// How long to wait. Matched to the SDK's own witness-round timeout, so a
    /// probe that passes means a claim has a comparable budget to work in.
    private let windowSecs: TimeInterval = 60

    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    func cancel() {
        task?.cancel()
        task = nil
        if case .running = state { state = .idle }
    }

    /// Send one probe and wait for it.
    ///
    /// `walletDir` is the wallet's own directory — `outbox/new` sits directly
    /// under it, while the inbox is under `maildir/`. That asymmetry is real
    /// (`sdk/client/src/outbox.rs` writes the former, `AccountWorker` lands
    /// the latter) and getting it wrong makes a probe that can never pass.
    func start(walletDir: String, walletEmail: String) {
        guard !walletEmail.isEmpty else {
            state = .failed(reason: "This wallet has no email address yet.")
            return
        }
        task?.cancel()
        state = .running

        let token = UUID().uuidString
        let started = Date()
        let window = windowSecs

        task = Task.detached(priority: .utility) { [weak self] in
            do {
                try Self.writeProbe(walletDir: walletDir, email: walletEmail, token: token)
            } catch {
                await self?.finish(.failed(reason:
                    "Couldn't write the test message: \(error.localizedDescription)"))
                return
            }

            let deadline = started.addingTimeInterval(window)
            while Date() < deadline {
                if Task.isCancelled { return }
                if Self.consumeArrival(walletDir: walletDir, token: token) {
                    let secs = Date().timeIntervalSince(started)
                    await self?.finish(.passed(seconds: secs))
                    await self?.remember(walletEmail: walletEmail)
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await self?.finish(.failed(reason: Self.timeoutReason(window)))
        }
    }

    /// The three things it actually is, in the order they actually happen.
    /// No error code here — the code belongs in the diagnostic report, not in
    /// the first thing a new user reads.
    nonisolated static func timeoutReason(_ window: TimeInterval) -> String {
        "The message went out, but nothing came back within \(Int(window)) seconds."
    }

    private func finish(_ s: State) { state = s; task = nil }

    private func remember(walletEmail: String) {
        MailCheckRecord.recordPass(walletEmail: walletEmail)
    }

    // MARK: - The two directory operations

    /// Write a self-addressed message into the outbox, tmp-then-rename so the
    /// agent never sees a partial file — the same ordering, and for the same
    /// reason, as `write_outbox_eml` in the SDK.
    nonisolated private static func writeProbe(walletDir: String, email: String, token: String) throws {
        let fm = FileManager.default
        let newDir = "\(walletDir)/outbox/new"
        let tmpDir = "\(walletDir)/outbox/tmp"
        try fm.createDirectory(atPath: newDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

        // `AXIOM/mailcheck/<token>` so any agent can see whose message this
        // is — an agent set to "delete AXIOM mail only" recognises it rather
        // than treating it as the user's own mail. The SDK ignores it: its
        // inbox sweep matches on request id, and this has none.
        let body = """
        From: \(email)\r
        To: \(email)\r
        Subject: AXIOM/mailcheck/\(token)\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        AxiomWallet is checking that mail reaches this address. Nothing to do.\r
        """
        let name = "\(Int(Date().timeIntervalSince1970 * 1_000_000)).\(token).eml"
        let tmpPath = "\(tmpDir)/\(name)"
        try Data(body.utf8).write(to: URL(fileURLWithPath: tmpPath))
        try fm.moveItem(atPath: tmpPath, toPath: "\(newDir)/\(name)")
    }

    /// Look for our token in the inbox and take it back out again.
    ///
    /// Deleting it is this probe's own housekeeping — the message is ours,
    /// the wallet has no use for it, and leaving it would make every later
    /// inbox scan step over it. The SERVER-side copy is the agent's business,
    /// governed by its retention mode.
    nonisolated private static func consumeArrival(walletDir: String, token: String) -> Bool {
        let fm = FileManager.default
        let inbox = "\(walletDir)/maildir/inbox/new"
        guard let names = try? fm.contentsOfDirectory(atPath: inbox) else { return false }
        for name in names {
            let path = "\(inbox)/\(name)"
            guard let data = fm.contents(atPath: path),
                  // Header-sized read: the token sits in the Subject line, and
                  // a cheque body can be ~127 KB of base64 we have no reason
                  // to scan.
                  let text = String(data: data.prefix(8 * 1024), encoding: .utf8),
                  text.contains(token) else { continue }
            try? fm.removeItem(atPath: path)
            return true
        }
        return false
    }
}

// MARK: - Remembering that it passed

/// Whether this wallet's mail has ever been proven to work, and when.
///
/// Stored per wallet EMAIL rather than per wallet directory: the address is
/// what the mailbox is for, and it is what the user changes when they change
/// providers. A pass is deliberately not given an expiry — a stale pass is
/// still evidence the setup was once correct, and the claim's own failure is
/// the signal when it stops being true.
enum MailCheckRecord {
    private static func key(_ walletEmail: String) -> String {
        "mailCheckPassedAt.\(walletEmail.lowercased())"
    }

    static func recordPass(walletEmail: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key(walletEmail))
    }

    /// When this wallet's mail last round-tripped, or nil if it never has.
    static func passedAt(walletEmail: String) -> Date? {
        let t = UserDefaults.standard.double(forKey: key(walletEmail))
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func hasPassed(walletEmail: String) -> Bool {
        passedAt(walletEmail: walletEmail) != nil
    }

    /// "2 minutes ago" — shown next to an unlocked Claim so the user can see
    /// how fresh the evidence is.
    static func passedAgoDescription(walletEmail: String) -> String? {
        guard let at = passedAt(walletEmail: walletEmail) else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: at, relativeTo: Date())
    }
}
