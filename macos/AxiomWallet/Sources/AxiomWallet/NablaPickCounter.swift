import Foundation
import AxiomSdk

// =================================================================
// NablaPickCounter — per-wallet, per-Nabla "picks" tally. The Nabla
// analogue of ValidatorPickCounter, but built ENTIRELY locally from
// the data the SDK already exposes — no SDK/FFI addition needed.
//
// Validators record their k-witness set on the receipt, so the
// validator counter reads `lastReceiptWitnessIds()`. Nabla has no such
// per-op record, BUT the SDK's Nabla picker already tracks, per node,
// the unix-second of the last SUCCESSFUL contact (`lastOkSecs`,
// surfaced by `sdkNablaPickerSnapshot()`). We use that as the "this
// node was reached by this wallet's activity" signal: at each broadcast
// finalize (send / redeem / claim — the points that consult Nabla for
// §4.6 verify + register), any node whose `lastOkSecs` advanced since
// the previous finalize is counted as one pick.
//
// Honest scope: `lastOkSecs` advances on ANY successful contact
// (an op's consultation OR a periodic liveness probe), so the count is
// "times this node was used/reached by this wallet's activity," not a
// strict per-payment-check count. That's the right granularity for an
// informational indicator — same spirit as the validator picks column.
//
// Storage: UserDefaults, per wallet (keyed by address) — counts +
// a per-node `lastOkSecs` watermark so the increment is idempotent
// (a re-render or a finalize with no new contact can't double-count).
// The picker is process-global; attribution stays per-wallet because we
// only fold a delta in at the ACTIVE wallet's own finalize.
// =================================================================
enum NablaPickCounter {
    private static let countsKeyFmt = "nabla_pick_counts.%@"
    private static let markKeyFmt = "nabla_pick_lastok.%@"   // address -> last_ok_secs watermark

    private static func walletKey(_ w: AxiomWallet) -> String {
        (try? w.address()) ?? w.email()
    }
    private static func countsKey(_ w: AxiomWallet) -> String {
        String(format: countsKeyFmt, walletKey(w))
    }
    private static func markKey(_ w: AxiomWallet) -> String {
        String(format: markKeyFmt, walletKey(w))
    }

    /// Stored tally (nabla address -> pick count) for a wallet. Read-only;
    /// use for display (Settings table) without mutating the watermark.
    static func counts(for w: AxiomWallet) -> [String: Int] {
        (UserDefaults.standard.dictionary(forKey: countsKey(w)) as? [String: Int]) ?? [:]
    }

    private static func watermark(for w: AxiomWallet) -> [String: UInt64] {
        let raw = (UserDefaults.standard.dictionary(forKey: markKey(w)) as? [String: NSNumber]) ?? [:]
        return raw.mapValues { $0.uint64Value }
    }

    /// Fold the picker's current per-node last-success timestamps into the
    /// wallet's tally: any node whose `lastOkSecs` advanced past the stored
    /// watermark gets +1. Call from every broadcast-success path. Idempotent
    /// between contacts (the watermark gates re-counts). Returns the updated
    /// counts so callers can bind directly.
    @discardableResult
    static func record(wallet w: AxiomWallet) -> [String: Int] {
        let snap = sdkNablaPickerSnapshot()   // [.address, .lastOkSecs, ...]
        var counts = counts(for: w)
        let mark = watermark(for: w)
        // First observation for this wallet: seed the watermark WITHOUT
        // counting pre-existing contacts, so the tally reflects activity from
        // here forward (mirrors the validator counter starting from empty).
        let firstRun = UserDefaults.standard.object(forKey: markKey(w)) == nil

        var newMark: [String: NSNumber] = [:]
        for e in snap {
            newMark[e.address] = NSNumber(value: e.lastOkSecs)
            guard e.lastOkSecs > 0 else { continue }
            if !firstRun, e.lastOkSecs > (mark[e.address] ?? 0) {
                counts[e.address, default: 0] += 1
            }
        }
        UserDefaults.standard.set(newMark, forKey: markKey(w))
        UserDefaults.standard.set(counts, forKey: countsKey(w))
        return counts
    }
}
