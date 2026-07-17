import Foundation
import AxiomSdk

// =================================================================
// ValidatorPickCounter — per-wallet, per-validator pick tally.
//
// Counts how many times each validator has appeared in this wallet's
// witness set. The count is incremented at BROADCAST FINALIZE — the
// success path of send / redeem / claim — where the just-written
// `last_receipt` carries that transaction's exact k-witness set.
//
// This replaces the earlier Settings-only reconstruction, which only
// sampled the latest receipt when the user happened to open Settings →
// Network. That approach structurally under-counted: a wallet that sent
// ten times but opened Settings once saw "1×", and a wallet whose owner
// never opened Settings saw "—" forever. Hooking the count to the
// finalize paths means every transaction is counted exactly once,
// whether or not any view is on screen.
//
// Storage: UserDefaults, keyed by wallet address (each wallet keeps its
// own tally, validator_id → count). A wallet_seq watermark makes the
// increment idempotent — re-renders, retries, and the Settings
// catch-up call can't double-count the same TX.
//
// Join key is validator_id (hex `blake3(sphincs_pk)`) throughout — the
// validator's immutable identity, the same key the picker renders by
// (`pickCounts[validator.validatorId]`) and the SDK hint cache merges by.
// =================================================================
enum ValidatorPickCounter {
    private static let countsKeyFmt = "validator_pick_counts.%@"
    private static let lastSeqKeyFmt = "validator_pick_counts.last_seq.%@"

    private static func walletKey(_ w: AxiomWallet) -> String {
        (try? w.address()) ?? w.email()
    }
    private static func countsKey(_ w: AxiomWallet) -> String {
        String(format: countsKeyFmt, walletKey(w))
    }
    private static func lastSeqKey(_ w: AxiomWallet) -> String {
        String(format: lastSeqKeyFmt, walletKey(w))
    }

    /// Stored tally (validator_id hex → pick count) for a wallet.
    static func counts(for w: AxiomWallet) -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: countsKey(w)) as? [String: Int]) ?? [:]
    }

    /// Fold the wallet's most-recent witnessed TX into the tally, IFF
    /// `wallet_seq` has advanced past the last-counted watermark. Returns
    /// the up-to-date counts so callers (e.g. the Settings table) can
    /// bind the result directly. Idempotent per `wallet_seq`: safe to
    /// call from every broadcast-success path AND as an onAppear catch-up.
    @discardableResult
    static func record(wallet w: AxiomWallet) -> [String: Int] {
        var counts = counts(for: w)
        let seqKey = lastSeqKey(w)
        let currentSeq = w.walletSeq()
        // NSNumber round-trip — `as? UInt64` on a UserDefaults value is
        // unreliable; go through NSNumber explicitly.
        let lastSeen = (UserDefaults.standard.object(forKey: seqKey) as? NSNumber)?.uint64Value ?? 0
        guard currentSeq > lastSeen else { return counts }   // this TX already counted

        let ids = w.lastReceiptWitnessIds()
        // Advance the watermark even when there are no witness ids yet
        // (fresh wallet / genesis) so we don't re-scan the same state.
        UserDefaults.standard.set(NSNumber(value: currentSeq), forKey: seqKey)
        guard !ids.isEmpty else { return counts }

        for id in ids { counts[id, default: 0] += 1 }
        UserDefaults.standard.set(counts, forKey: countsKey(w))
        return counts
    }
}
