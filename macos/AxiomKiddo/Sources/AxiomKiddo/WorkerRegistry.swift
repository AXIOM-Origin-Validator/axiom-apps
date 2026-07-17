import Foundation
import Combine

// =================================================================
// WorkerRegistry — owns the live AccountWorker instances and re-publishes
// their @Published state so SwiftUI updates when any of them change.
//
// One worker per configured account. Lifecycle: started on app launch
// (`startAll`), updated when the account edits in Settings (`refresh`),
// stopped on account deletion (`stop`).
// =================================================================

@MainActor
final class WorkerRegistry: ObservableObject {
    @Published private(set) var workers: [UUID: AccountWorker] = [:]
    private var observations: [UUID: AnyCancellable] = [:]

    /// Duplicate-dispatch guard: at most ONE live worker per walletDir.
    /// Two workers on one outbox both SMTP-deliver every .eml before either
    /// moves it (drainOutbox is read → send → move) — the duplicated redeem
    /// request then hits consume-once at validators and strands the redeem
    /// (remote-tester incident, 2026-07-06). First account in list order
    /// wins; later same-dir accounts are skipped (and their stale worker,
    /// if any, stopped by the caller's diff pass).
    private func dedupeByWalletDir(_ accounts: [KiddoAccount]) -> [KiddoAccount] {
        var seen = Set<String>()
        var out: [KiddoAccount] = []
        for acct in accounts {
            let dir = (acct.walletDir as NSString).standardizingPath
            if seen.contains(dir) {
                NSLog("[WorkerRegistry] duplicate-dispatch guard: account '%@' "
                    + "shares walletDir %@ with an earlier account — NOT "
                    + "starting a second worker (remove the duplicate in "
                    + "Settings)", acct.label, acct.walletDir)
                continue
            }
            seen.insert(dir)
            out.append(acct)
        }
        return out
    }

    func startAll(_ accounts: [KiddoAccount]) {
        for acct in dedupeByWalletDir(accounts) {
            start(account: acct)
        }
    }

    func start(account: KiddoAccount) {
        if workers[account.id] != nil { return }
        let w = AccountWorker(account: account)
        workers[account.id] = w
        // Re-publish per-worker @Published changes so the registry-level
        // objectWillChange fires for any worker state change.
        observations[account.id] = w.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        w.start()
    }

    func refresh(account: KiddoAccount) {
        if let w = workers[account.id] {
            w.update(account)
        } else {
            start(account: account)
        }
    }

    /// Diff the live worker set against an authoritative `accounts`
    /// list (typically `store.accounts`): stop workers whose account
    /// is gone, start workers for new accounts, refresh workers whose
    /// account fields changed. `AccountWorker.update` is no-op on
    /// equality so frequent calls (e.g. AccountStore's 30 s reconcile
    /// tick) are cheap when nothing actually changed.
    ///
    /// Wired in `AppDelegate` to `store.$accounts.dropFirst().sink`:
    /// reconcile re-pointing `walletDir` after a wallet reset goes
    /// through @Published → here → `Worker.update` → fresh snapshot
    /// with correct paths.
    func syncWith(_ accounts: [KiddoAccount]) {
        // Duplicate-dispatch guard: only the first account per walletDir
        // stays live; a later same-dir account's worker (started before the
        // collision existed, e.g. after a reconcile repoint) is stopped by
        // the diff pass below because it's excluded from `deduped`.
        let deduped = dedupeByWalletDir(accounts)
        let live: Set<UUID> = Set(deduped.map { $0.id })
        for id in Array(workers.keys) where !live.contains(id) {
            stop(id: id)
        }
        let fm = FileManager.default
        for acct in deduped {
            // Stop the worker if its walletDir was deleted out from
            // under us in AxiomWallet. Without this check the worker
            // keeps polling POP3, lands fresh mail in a phantom
            // maildir, sets `lastError = "land inbox: …"` every tick,
            // and surfaces in the UI as "POP3 disconnected" even
            // though the POP3 socket is fine. Stopping the worker
            // makes the broken state visible (no activity, no
            // misleading error). User re-binds via Settings if they
            // want to reconnect to a new wallet.
            //
            // AccountStore.reconcileWalletDirs already tried to
            // re-point this account to a replacement wallet with the
            // matching envelope email; if walletDir is STILL stale
            // by the time we get here, no replacement exists.
            if !fm.fileExists(atPath: acct.walletDir + "/wallet.axiom") {
                if workers[acct.id] != nil {
                    NSLog("[WorkerRegistry] stopping worker for '%@' "
                        + "— walletDir is gone (%@)",
                          acct.label, acct.walletDir)
                    stop(id: acct.id)
                }
                continue
            }
            refresh(account: acct)
        }
    }

    func stop(id: UUID) {
        workers[id]?.stop()
        observations[id]?.cancel()
        observations.removeValue(forKey: id)
        workers.removeValue(forKey: id)
    }

    /// Stop every worker + drop every observation. Used by the
    /// dev "factory reset" path before AccountStore.removeAll wipes
    /// the on-disk + keychain state.
    func stopAll() {
        for id in Array(workers.keys) {
            stop(id: id)
        }
    }

    func worker(for id: UUID) -> AccountWorker? { workers[id] }

    var summary: (sent: Int, pulled: Int, queue: Int, hasError: Bool) {
        var s = 0, p = 0, q = 0, err = false
        for w in workers.values {
            s += w.totalSent
            p += w.totalPulled
            q += w.queueDepth
            if w.lastError != nil { err = true }
        }
        return (s, p, q, err)
    }
}
