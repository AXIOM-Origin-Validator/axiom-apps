import Foundation
import Combine

// =================================================================
// AccountStore — JSON persistence for KiddoAccount list +
// keychain hand-off for `.email` passwords.
//
// Lives at ~/Library/Application Support/AxiomKiddo/accounts.json.
// First-run creates the dir but leaves the list empty — the user
// adds accounts from Settings.
//
// Phase 3 split: passwords go into `PasswordKeychain` keyed by
// account UUID; `accounts.json` only persists a `hasKeychainPassword`
// flag. Any non-empty `account.password` arriving through
// add / update is treated as "save this new password" — written to
// the keychain, then scrubbed from the in-memory struct before the
// JSON is written.
// =================================================================

@MainActor
final class AccountStore: ObservableObject {
    @Published var accounts: [KiddoAccount] = []

    /// Ticks every time `reconcileWalletDirs()` runs, regardless of
    /// whether any account field changed. Lets `WorkerRegistry`
    /// re-sweep workers for filesystem-only state — specifically,
    /// detecting that an account's `walletDir/wallet.axiom` was
    /// deleted out from under us in AxiomWallet (no account field
    /// changes, so `$accounts` wouldn't fire on its own). Subscribers
    /// re-run their per-account sweep on every tick.
    @Published var reconcileGeneration: Int = 0

    private let fileURL: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("AxiomKiddo")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }()

    /// Periodic wallet-dir reconcile timer — see `reconcileWalletDirs()`.
    /// 30 s cadence matches the FATMAMA auto-register loop so the two
    /// per-account maintenance ticks run on the same rhythm.
    private var reconcileTimer: Timer?

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([KiddoAccount].self, from: data) {
            self.accounts = decoded
        }
        migratePlaintextPasswords()
        reconcileWalletDirs()
        // Re-check periodically so wallet creates / renames / deletes
        // performed in AxiomWallet take effect without a Kiddo restart.
        // 30 s is bounded work: a FileManager listdir of wallets/ plus
        // an envelope-header parse per candidate.
        reconcileTimer = Timer.scheduledTimer(
            withTimeInterval: 30, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcileWalletDirs() }
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(accounts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func add(_ account: KiddoAccount) {
        var a = account
        commitPassword(&a)
        accounts.append(a)
        save()
    }

    func update(_ account: KiddoAccount) {
        var a = account
        commitPassword(&a)
        if let i = accounts.firstIndex(where: { $0.id == a.id }) {
            accounts[i] = a
            save()
        }
    }

    func remove(_ id: UUID) {
        PasswordKeychain.delete(id: id)
        accounts.removeAll { $0.id == id }
        save()
    }

    /// Wipe every account + its keychain entry. Used by the dev
    /// "factory reset" affordance — completely returns Kiddo to a
    /// fresh-install state so the kiddo-cheque-drop investigation can
    /// repro from a known-clean baseline. Returns the number of
    /// accounts removed so the UI can report it.
    @discardableResult
    func removeAll() -> Int {
        let count = accounts.count
        for a in accounts {
            PasswordKeychain.delete(id: a.id)
        }
        accounts.removeAll()
        save()
        return count
    }

    // MARK: - Password ↔ keychain plumbing

    /// Move a non-empty `account.password` into the keychain, clear
    /// the in-memory field, mark `hasKeychainPassword = true`.
    /// Empty password = "no change" — keychain entry untouched, flag
    /// preserved. Best-effort: on keychain failure we leave the
    /// plaintext in memory so the worker can still authenticate from
    /// this session; the next save attempt will retry.
    private func commitPassword(_ a: inout KiddoAccount) {
        guard !a.password.isEmpty else { return }
        do {
            try PasswordKeychain.set(id: a.id, password: a.password)
            a.password = ""
            a.hasKeychainPassword = true
        } catch {
            // Keep the plaintext in memory — better than losing it.
            // Next save retries.
        }
    }

    /// Auto-fix `walletDir` for accounts whose configured path is stale
    /// (wallet was deleted, renamed, or recreated in a new dir with the
    /// same email). Re-points an account to a wallet whose envelope
    /// history shows the matching `walletEmail`. Conservative — never
    /// drops an account, never overwrites a still-valid walletDir,
    /// never invents an email.
    ///
    /// Triggered on AccountStore init and every 30 s (see `reconcileTimer`),
    /// because the user can create / delete / rename wallets in
    /// AxiomWallet without ever telling Kiddo. Limitation: a brand-new
    /// pristine wallet with no .eml in `outbox/` or `maildir/inbox/`
    /// can't be matched by envelope scan — that edge still needs a
    /// manual Settings add. The common case (a wallet that's at least
    /// queued one outbound) auto-resolves.
    private func reconcileWalletDirs() {
        let fm = FileManager.default
        var dirty = false
        // Cache the candidate scan so we only walk wallets/ once even
        // when several accounts need re-pointing.
        var candidateCache: [WalletCandidate]? = nil
        for i in 0..<accounts.count {
            let acct = accounts[i]
            if acct.walletEmail.isEmpty { continue }
            let walletGone = !fm.fileExists(atPath: acct.walletDir + "/wallet.axiom")
            // Current walletDir is fine if it exists AND its envelope
            // email matches (or no envelopes yet — give it the benefit
            // of the doubt; this wallet hasn't done anything).
            if !walletGone {
                let detected = KiddoAccount.detectWalletEmail(walletDir: acct.walletDir)
                if detected == nil
                    || detected?.caseInsensitiveCompare(acct.walletEmail) == .orderedSame
                {
                    continue
                }
                // walletDir exists but its envelope email is for a
                // different wallet — fall through and look for the right
                // dir.
            }
            if candidateCache == nil {
                candidateCache = KiddoAccount.scanAvailableWallets(excluding: [])
            }
            // Dirs already owned by OTHER accounts — a repoint must never
            // land two accounts on one walletDir. Two workers on one outbox
            // SMTP-deliver every .eml twice (drainOutbox is read → send →
            // move), and the duplicated redeem request hits consume-once at
            // the validators and strands the redeem (remote-tester incident,
            // 2026-07-06). Recomputed per account so an earlier repoint in
            // this same pass is respected.
            let ownedByOthers: Set<String> = Set(
                accounts.enumerated()
                    .filter { $0.offset != i }
                    .map { ($0.element.walletDir as NSString).standardizingPath }
            )
            var repointed = false
            for cand in candidateCache ?? [] {
                guard let candEmail = cand.walletEmail else { continue }
                if candEmail.caseInsensitiveCompare(acct.walletEmail) == .orderedSame
                    && cand.walletDir != acct.walletDir
                {
                    if ownedByOthers.contains((cand.walletDir as NSString).standardizingPath) {
                        NSLog("[Kiddo] reconcile: NOT repointing '%@' to %@ — "
                            + "another account already owns that walletDir "
                            + "(duplicate-dispatch guard)",
                              acct.label, cand.walletDir)
                        continue
                    }
                    NSLog("[Kiddo] reconcile: account '%@' walletDir -> %@",
                          acct.label, cand.walletDir)
                    accounts[i].walletDir = cand.walletDir
                    dirty = true
                    repointed = true
                    break
                }
            }
            if walletGone && !repointed {
                // Wallet was deleted in AxiomWallet (or never created
                // at this path) AND no replacement with the same
                // envelope email exists. The worker — if running —
                // is now writing fetched POP3 mail into a phantom
                // maildir, which fails every poll and surfaces as
                // "POP3 broken" in the UI even though the POP3
                // connection itself is fine. Log once per tick;
                // WorkerRegistry's next syncWith pass (triggered by
                // the `reconcileGeneration` tick below) stops the
                // orphaned worker.
                NSLog("[Kiddo] reconcile: account '%@' walletDir gone, "
                    + "no replacement — worker will be stopped (re-add "
                    + "via Settings to bind this account to a new wallet)",
                      acct.label)
            }
        }
        if dirty { save() }
        // Always tick — even when no account field changed, so
        // WorkerRegistry re-evaluates orphan-walletDir state.
        // The work is cheap (Worker.update no-ops on equality;
        // WorkerRegistry only stop()s workers whose walletDir is
        // actually gone).
        reconcileGeneration &+= 1
    }

    /// One-shot migration for accounts.json files written under
    /// Phase 1/2, where `password` lived as plaintext on disk. Move
    /// each non-empty password into the keychain and rewrite the
    /// file without it. Idempotent — files already migrated have
    /// empty passwords + the flag set, so this is a no-op.
    private func migratePlaintextPasswords() {
        var dirty = false
        for i in 0..<accounts.count {
            if !accounts[i].password.isEmpty {
                do {
                    try PasswordKeychain.set(
                        id: accounts[i].id,
                        password: accounts[i].password
                    )
                    accounts[i].password = ""
                    accounts[i].hasKeychainPassword = true
                    dirty = true
                } catch {
                    // Leave it; next launch retries. Doing nothing is
                    // strictly safer than nuking the password.
                }
            }
        }
        if dirty {
            save()
        }
    }
}
