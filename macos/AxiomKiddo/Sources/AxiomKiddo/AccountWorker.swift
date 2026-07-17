import Foundation
import Combine

// =================================================================
// AccountWorker — one running instance per configured KiddoAccount.
//
// Owns two background loops:
//
//   1. Outbox watcher — DispatchSource on <walletDir>/outbox/new/.
//      Wakes on filesystem events, scans for new .eml files, parses
//      envelope, SMTP-delivers, moves to outbox/sent/ on success or
//      outbox/failed/ on error.
//
//   2. POP3 poller — Timer every `pop3PollSecs` that opens a session
//      against the configured POP3 server, drains all pending
//      messages into <walletDir>/maildir/inbox/new/, DELE+QUIT.
//
// Status (last send/pull time, totals, last error) is exposed via
// @Published properties for the menu-bar UI to observe.
//
// Threading: the worker class itself is @MainActor for SwiftUI
// observability. Background I/O (FS scan, SMTP send, POP3 fetch)
// runs on `workQueue`. Cross-thread state is passed via plain
// `Snapshot` value-typed copies captured at start() / update() time
// — never by reaching back into @MainActor state from the background
// queue, which would trap as a precondition violation on Swift 5.9+.
// =================================================================

/// Plain-value snapshot of everything the background loops need.
/// Captured on main when the worker starts (or when its account is
/// updated); the workers use this directly without touching @MainActor.
private struct WorkerSnapshot {
    let walletEmail: String
    let smtpHost: String
    let smtpPort: Int
    let pop3Host: String
    let pop3Port: Int
    // Transport profile copied off the account at snapshot time.
    // `.axiomDev` accounts leave TLS off + username/password empty,
    // so the SMTP/POP3 clients silently skip AUTH and use plain TCP
    // — the dev env keeps working unchanged.
    let smtpUseTLS: Bool
    let pop3UseTLS: Bool
    let username: String
    let password: String
    let outboxNewPath: String
    let outboxSendingPath: String
    let outboxSentPath: String
    let outboxFailedPath: String
    let inboxNewPath: String
    let inboxCurPath: String
    let inboxTmpPath: String

    init(account: KiddoAccount) {
        self.walletEmail = account.walletEmail
        self.smtpHost = account.smtpHost
        self.smtpPort = account.smtpPort
        self.pop3Host = account.pop3Host
        self.pop3Port = account.pop3Port
        self.smtpUseTLS = account.smtpUseTLS
        self.pop3UseTLS = account.pop3UseTLS
        self.username = account.username
        // Phase 3: password lives in the Keychain only. If the
        // in-memory account still carries a non-empty plaintext value
        // (a fresh edit that hasn't been committed-and-scrubbed yet),
        // honour it — otherwise fall back to whatever's in the
        // keychain. Empty string when neither path produces a value;
        // SmtpClient will then skip AUTH PLAIN (FATMAMA path).
        if !account.password.isEmpty {
            self.password = account.password
        } else {
            self.password = PasswordKeychain.get(id: account.id) ?? ""
        }
        self.outboxNewPath = "\(account.walletDir)/outbox/new"
        // Claim dir for exactly-once dispatch: drainOutbox atomically
        // renames new/<f> → sending/<f> BEFORE the SMTP deliver, so a
        // second worker (or an overlapping drain) can never send the same
        // file twice — the losing rename fails and that drain skips it.
        self.outboxSendingPath = "\(account.walletDir)/outbox/sending"
        self.outboxSentPath = "\(account.walletDir)/outbox/sent"
        self.outboxFailedPath = "\(account.walletDir)/outbox/failed"
        self.inboxNewPath = "\(account.walletDir)/maildir/inbox/new"
        // `cur/` is where the SDK moves consumed inbox files (per
        // maildir convention: `inbox/cur/<name>:2,S` after the wallet
        // reads + processes a cheque). The wallet expects this dir
        // to exist when it tries the rename — missing cur/ causes
        // `StorageError("rename failed: no such file or directory")`.
        self.inboxCurPath = "\(account.walletDir)/maildir/inbox/cur"
        self.inboxTmpPath = "\(account.walletDir)/maildir/inbox/tmp"
        self.isAxiomDev = account.kind == .axiomDev
    }

    /// True for `.axiomDev` (FATMAMA) accounts — drives the automatic
    /// XAXIOM-REGISTER. `.email` accounts skip it (a real SMTP server
    /// would reject the verb).
    let isAxiomDev: Bool
}

@MainActor
final class AccountWorker: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var account: KiddoAccount
    @Published var lastSendAt: Date?
    @Published var lastPullAt: Date?
    @Published var queueDepth: Int = 0
    @Published var totalSent: Int = 0
    @Published var totalPulled: Int = 0
    @Published var lastError: String?
    @Published var running: Bool = false

    private var outboxSource: DispatchSourceFileSystemObject?
    private var outboxFd: Int32 = -1
    private var pollTimer: Timer?
    private var registerTimer: Timer?
    private let workQueue = DispatchQueue(label: "kiddo.worker", qos: .userInitiated)

    init(account: KiddoAccount) {
        self.id = account.id
        self.account = account
    }

    func update(_ account: KiddoAccount) {
        // No-op when nothing relevant changed. WorkerRegistry.syncWith
        // calls update() on every @Published accounts mutation (e.g.
        // every 30 s when AccountStore.reconcileWalletDirs ticks even
        // if nothing changed); without this guard each tick would
        // pointlessly stop + start the worker, dropping the
        // DispatchSource fd, the POP3 timer, and the FATMAMA register
        // timer for a fresh round.
        if self.account == account { return }
        let restart = running
        if restart { stop() }
        self.account = account
        if restart { start() }
    }

    func start() {
        guard !running else { return }
        running = true
        let snap = WorkerSnapshot(account: account)
        ensureDirs(snap)
        startOutboxWatcher(snap)
        startPop3Poller(snap)
        startFatmamaAutoRegister(snap)
        // Kick once on startup so any backlog from before Kiddo was
        // running gets processed.
        workQueue.async { [weak self] in
            self?.drainOutbox(snap)
        }
    }

    func stop() {
        running = false
        pollTimer?.invalidate()
        pollTimer = nil
        registerTimer?.invalidate()
        registerTimer = nil
        outboxSource?.cancel()
        outboxSource = nil
        if outboxFd >= 0 { close(outboxFd); outboxFd = -1 }
    }

    /// Force an immediate scan of `outbox/new/`. Useful after the
    /// user fixes a config issue and wants to see the queue drain
    /// without waiting for the next FS event.
    func forceDrain() {
        guard running else { return }
        let snap = WorkerSnapshot(account: account)
        workQueue.async { [weak self] in
            self?.drainOutbox(snap)
        }
    }

    /// Move every file from `outbox/failed/` back into `outbox/new/`,
    /// then trigger a drain. Useful after fixing a parser bug, a
    /// wrong SMTP host, or any other class of error that quarantined
    /// otherwise-valid UMPs.
    func retryFailed() {
        guard running else { return }
        let snap = WorkerSnapshot(account: account)
        workQueue.async { [weak self] in
            self?.moveFailedToNew(snap)
            self?.drainOutbox(snap)
        }
    }

    nonisolated private func moveFailedToNew(_ snap: WorkerSnapshot) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: snap.outboxFailedPath)) ?? []
        var moved = 0
        for name in names {
            let src = "\(snap.outboxFailedPath)/\(name)"
            let dst = "\(snap.outboxNewPath)/\(name)"
            do {
                try fm.moveItem(atPath: src, toPath: dst)
                moved += 1
            } catch {
                // Skip silently — usually a same-name collision; the
                // user can investigate manually.
            }
        }
        if moved > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = nil
            }
        }
    }

    deinit {
        // Cancel synchronously without touching @MainActor state.
        pollTimer?.invalidate()
        registerTimer?.invalidate()
        outboxSource?.cancel()
        if outboxFd >= 0 { close(outboxFd) }
    }

    // MARK: - Setup

    nonisolated private func ensureDirs(_ snap: WorkerSnapshot) {
        let fm = FileManager.default
        for p in [snap.outboxNewPath, snap.outboxSentPath, snap.outboxFailedPath,
                  snap.inboxNewPath, snap.inboxCurPath, snap.inboxTmpPath] {
            try? fm.createDirectory(atPath: p, withIntermediateDirectories: true)
        }
    }

    private func startOutboxWatcher(_ snap: WorkerSnapshot) {
        let fd = open(snap.outboxNewPath, O_EVTONLY)
        guard fd >= 0 else {
            lastError = "watch outbox/new: errno \(errno)"
            return
        }
        outboxFd = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: workQueue
        )
        src.setEventHandler { [weak self] in
            self?.drainOutbox(snap)
        }
        outboxSource = src
        src.resume()
    }

    private func startPop3Poller(_ snap: WorkerSnapshot) {
        let secs = TimeInterval(max(1, account.pop3PollSecs))
        let timer = Timer.scheduledTimer(withTimeInterval: secs, repeats: true) { [weak self] _ in
            self?.workQueue.async {
                // Drain the outbox on every tick — NOT only on the
                // DispatchSource FS event. The FS watcher
                // (`startOutboxWatcher`) is a fast-path optimisation
                // and is not reliable on its own: a directory-fd
                // event source can miss writes when the watched
                // inode is replaced, when events coalesce, or when
                // the source is registered before the directory sees
                // traffic. When it misses, the outbox silently never
                // relays and every witness/redeem round-trip times
                // out — observed exactly that (1200 POP3 polls, zero
                // SMTP sends, envelope wedged in outbox/new). The
                // periodic drain is the reliable backstop: worst-case
                // relay latency is one poll interval.
                self?.drainOutbox(snap)
                self?.pop3Tick(snap)
            }
        }
        pollTimer = timer
    }

    /// Keep this wallet's address registered with FATMAMA.
    ///
    /// FATMAMA's route table is dev-scoped and in-memory — it forgets
    /// every XAXIOM-REGISTER when the dev env restarts. With no route
    /// for the wallet's address, inbound witness/cheque mail can't be
    /// delivered back, and every claim/send times out waiting for a
    /// response that physically can't arrive.
    ///
    /// So `.axiomDev` accounts re-assert their registration on worker
    /// start and on a 30s timer. XAXIOM-REGISTER is idempotent, so a
    /// FATMAMA restart self-heals within one interval — no manual
    /// "Register with FATMAMA" click required.
    private func startFatmamaAutoRegister(_ snap: WorkerSnapshot) {
        guard snap.isAxiomDev, !snap.walletEmail.isEmpty else { return }
        // Register immediately on startup.
        workQueue.async { [weak self] in
            self?.registerFatmama(snap)
        }
        // Re-assert periodically so a FATMAMA restart self-heals.
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.workQueue.async {
                self?.registerFatmama(snap)
            }
        }
        registerTimer = timer
    }

    nonisolated private func registerFatmama(_ snap: WorkerSnapshot) {
        do {
            try FatmamaRegister.register(
                host: snap.smtpHost,
                port: snap.smtpPort,
                email: snap.walletEmail
            )
        } catch {
            // FATMAMA may be down / restarting — the next 30s tick
            // retries. Deliberately NOT surfaced to `lastError`: the
            // SMTP/POP3 loops already report a dead FATMAMA, and a
            // re-register failure every 30s would just spam it.
            NSLog("AxiomKiddo: FATMAMA auto-register for \(snap.walletEmail) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Outbox drain (background)

    nonisolated private func drainOutbox(_ snap: WorkerSnapshot) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: snap.outboxSendingPath,
                                withIntermediateDirectories: true)

        // Crash recovery: a claim (rename into sending/) whose worker died
        // mid-SMTP leaves the file stranded. Anything older than the stale
        // threshold goes back to new/ for a retry — at-least-once is
        // preserved; a LIVE claim is always younger than this (one SMTP
        // deliver), so we never steal an in-flight file.
        let staleClaimSecs: TimeInterval = 120
        let leftovers = (try? fm.contentsOfDirectory(atPath: snap.outboxSendingPath)) ?? []
        for name in leftovers {
            let path = "\(snap.outboxSendingPath)/\(name)"
            let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
            if let m = mtime, Date().timeIntervalSince(m) > staleClaimSecs {
                NSLog("AxiomKiddo: recovering stale claim %@ (crashed mid-send) → outbox/new", name)
                try? fm.moveItem(atPath: path, toPath: "\(snap.outboxNewPath)/\(name)")
            }
        }

        let entries = (try? fm.contentsOfDirectory(atPath: snap.outboxNewPath)) ?? []
        // Process oldest first — filenames are unix_micros prefixed.
        let sorted = entries.sorted()

        publishDepth(sorted.count)

        for name in sorted {
            let src = "\(snap.outboxNewPath)/\(name)"
            // CLAIM before send (exactly-once dispatch): atomically rename
            // new/<f> → sending/<f>. If a second worker (duplicate account
            // on the same walletDir) or an overlapping drain already
            // claimed it, the rename fails and we skip — pre-fix both
            // workers read + SMTP-delivered the file before either moved
            // it, so every message went out twice; the duplicated redeem
            // then hit consume-once at the validators and stranded the
            // redeem (remote-tester incident, 2026-07-06).
            let claimed = "\(snap.outboxSendingPath)/\(name)"
            do {
                try fm.moveItem(atPath: src, toPath: claimed)
            } catch {
                continue // someone else claimed it — not ours to send
            }
            guard let data = fm.contents(atPath: claimed) else { continue }
            guard let env = EnvelopeParser.parse(data) else {
                let dst = "\(snap.outboxFailedPath)/\(name)"
                try? fm.moveItem(atPath: claimed, toPath: dst)
                publishError("\(name): missing From: / To: header")
                continue
            }

            do {
                let smtp = SmtpClient(
                    host: snap.smtpHost,
                    port: snap.smtpPort,
                    useTLS: snap.smtpUseTLS,
                    username: snap.username.isEmpty ? nil : snap.username,
                    password: snap.password.isEmpty ? nil : snap.password
                )
                try smtp.deliver(envelope: env, body: data)
                let dst = "\(snap.outboxSentPath)/\(name)"
                try? fm.moveItem(atPath: claimed, toPath: dst)
                publishSendSuccess()
            } catch {
                // Transient error: release the claim back to outbox/new/
                // so the next FS event or restart retries it. Only hard
                // parse errors go to failed/ (above).
                try? fm.moveItem(atPath: claimed, toPath: src)
                publishError("send \(name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - POP3 tick (background)

    nonisolated private func pop3Tick(_ snap: WorkerSnapshot) {
        // No mailbox yet = nothing to poll. (Setup in progress.)
        guard !snap.walletEmail.isEmpty else { return }

        let fm = FileManager.default
        do {
            // Real-email providers identify the mailbox by the
            // provider-side username (often the email address you
            // log in with — not necessarily the "wallet email" that
            // mail is addressed *to*). FATMAMA / dev uses the
            // wallet's own email since the dev SMTP relays per
            // address with no auth.
            let pop3Mailbox = snap.username.isEmpty
                ? snap.walletEmail
                : snap.username
            // Empty password = dev path; Pop3Client's "x" default is
            // what FATMAMA accepts.
            let pop3Password = snap.password.isEmpty
                ? "x"
                : snap.password
            let pop = Pop3Client(
                host: snap.pop3Host,
                port: snap.pop3Port,
                mailbox: pop3Mailbox,
                password: pop3Password,
                useTLS: snap.pop3UseTLS
            )
            let msgs = try pop.fetchAll()
            if msgs.isEmpty { return }

            for m in msgs {
                // Maildir tmp+rename — same shape as FATMAMA's
                // deliver_to_maildir helper (scripts/fatmama.py).
                let host = ProcessInfo.processInfo.hostName
                    .split(separator: ".").first ?? "host"
                let now = Date().timeIntervalSince1970
                let name = "\(String(format: "%.6f", now)).\(getpid()).\(host).\(UUID().uuidString)"
                let tmpPath = "\(snap.inboxTmpPath)/\(name)"
                let newPath = "\(snap.inboxNewPath)/\(name)"
                if fm.createFile(atPath: tmpPath, contents: m.body) {
                    do {
                        try fm.moveItem(atPath: tmpPath, toPath: newPath)
                    } catch {
                        publishError("land inbox: \(error.localizedDescription)")
                    }
                }
            }
            publishPullSuccess(count: msgs.count)
        } catch {
            // POP3 connection errors are routine when env is down.
            publishError("pop3: \(error.localizedDescription)")
        }
    }

    // MARK: - Publishing back to @MainActor

    // These helpers are the ONLY way background threads update the
    // @MainActor-isolated @Published state. They dispatch back to
    // main; never reach across the actor boundary synchronously.

    nonisolated private func publishDepth(_ n: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.queueDepth = n
        }
    }
    nonisolated private func publishSendSuccess() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.totalSent += 1
            self.lastSendAt = Date()
            self.lastError = nil
            self.queueDepth = max(0, self.queueDepth - 1)
        }
    }
    nonisolated private func publishPullSuccess(count: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.totalPulled += count
            self.lastPullAt = Date()
            self.lastError = nil
        }
    }
    nonisolated private func publishError(_ msg: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = msg
        }
    }
}
