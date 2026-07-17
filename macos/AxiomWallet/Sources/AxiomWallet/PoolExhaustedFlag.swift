import Foundation

// =================================================================
// PoolExhaustedFlag — persistent "free AXC claim is over forever" flag.
//
// Per YP §17.11.7.2, Airdrop pool exhaustion
// (`ErrorCode::AirdropPoolExhausted`) is the ONE genuinely-terminal
// failure for a fresh-wallet claim: the pool has no refill mechanism,
// so once any wallet on this Mac sees the code, every subsequent
// wallet (including brand-new ones created after) should have the
// Claim CTA suppressed.
//
// Storage: a hidden file at `~/.axiom_airdrop_pool_exhausted`.
// Deliberately OUTSIDE the app's standard data directories
// (`~/Library/Application Support/Axiom/`) so:
//
//   - Dragging AxiomWallet.app to the Trash doesn't clear it.
//   - Dragging `Application Support/Axiom/` to the Trash doesn't
//     clear it.
//   - AppCleaner-style uninstall utilities don't catch it (they
//     scan paths derived from the bundle ID).
//
// A user who wants to clear it can `rm ~/.axiom_airdrop_pool_exhausted`
// in Terminal. That's intentional friction — the flag isn't a security
// lockout, just a "don't keep dangling the free-AXC UI in the user's
// face after the pool is permanently drained" affordance.
// =================================================================

enum PoolExhaustedFlag {
    /// Absolute path to the persistent flag file (hidden dotfile in
    /// the user's real home directory; AxiomWallet is not sandboxed,
    /// so `NSHomeDirectory()` resolves to the real `~`).
    static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".axiom_airdrop_pool_exhausted")
    }

    /// True iff the flag file exists. Synchronous `fileExists` — fast
    /// enough for SwiftUI body evaluation. Callers that re-poll on
    /// every render should cache the result for the lifetime of the
    /// containing view if churn becomes a problem.
    static var isSet: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Set the flag. Idempotent — re-setting is a no-op. Best-effort:
    /// silently swallows write failures (the SDK already surfaced the
    /// AirdropPoolExhausted error to the user; UI suppression of the
    /// Claim CTA is the only downstream effect the flag drives, and
    /// missing it just means the next wallet sees the CTA + fails the
    /// same way + sets the flag again).
    static func set() {
        guard !isSet else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let body = """
        AXIOM Airdrop pool exhausted (YP §17.11.7.2).
        First observed: \(timestamp)

        This flag suppresses the "Claim 1 AXC" CTA in every AXIOM Wallet
        on this Mac, including newly-created wallets. To clear:
        rm \(path)
        """
        FileManager.default.createFile(
            atPath: path,
            contents: Data(body.utf8),
            attributes: nil
        )
    }
}
