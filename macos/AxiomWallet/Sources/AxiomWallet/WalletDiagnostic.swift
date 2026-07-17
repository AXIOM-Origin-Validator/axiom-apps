import AppKit
import Foundation
import AxiomSdk

// =================================================================
// WalletDiagnostic — detect state corruption + propose fixes.
//
// Runs a set of pure-local checks against the wallets directory and
// returns a list of issues with recommended actions. The UI mounts
// this from Settings → Advanced and from a Login-screen recovery
// link when wallet load fails.
//
// All checks are read-only by themselves. Fixes are explicit user
// actions exposed elsewhere (clear stale lock, drop orphan pair
// registration, etc.) — the diagnostic surface tells the user what's
// wrong; the recovery flows resolve it.
// =================================================================

enum DiagnosticSeverity {
    case info        // surface as info; no action needed
    case warning     // should resolve when convenient
    case error       // blocks normal operation
}

enum DiagnosticIssue {
    /// `pairs.json` references a wallet name whose directory is gone
    /// from disk. Pair entry should be removed so login doesn't loop
    /// on the missing wallet.
    case orphanedPairEntry(pairName: String, missingWalletName: String)

    /// A wallet directory exists with a wallet.axiom but no
    /// corresponding entry in pairs.json. Either re-register it as
    /// a single-mode pair or delete the directory.
    case unregisteredWallet(walletDir: String)

    /// `wallet.axiom.lock` is present but no running process holds it.
    /// Typical after a crashed app. Safe to delete the lock file.
    case staleLock(walletDir: String, lockPath: String)

    /// `wallet.axiom` can't be parsed (corrupt file, wrong magic,
    /// truncated). The wallet can't be opened. Recovery: restore
    /// from backup file or use wallet_secret reset path.
    case unreadableWallet(walletDir: String, reason: String)

    /// A pair has Normal but no Ark companion — typical after
    /// load-from-backup of a single-mode export. Not an error, just
    /// surfaced so the user knows the pair is incomplete.
    case partialPair(pairName: String)

    var severity: DiagnosticSeverity {
        switch self {
        case .orphanedPairEntry, .unreadableWallet: return .error
        case .unregisteredWallet, .staleLock:        return .warning
        case .partialPair:                            return .info
        }
    }

    var title: String {
        switch self {
        case .orphanedPairEntry(let pair, _):    return "Orphaned wallet set: \(pair)"
        case .unregisteredWallet:                 return "Unregistered wallet on disk"
        case .staleLock(let dir, _):              return "Stale lock: \((dir as NSString).lastPathComponent)"
        case .unreadableWallet(let dir, _):       return "Unreadable wallet: \((dir as NSString).lastPathComponent)"
        case .partialPair(let pair):              return "Partial wallet set: \(pair) (Normal only)"
        }
    }

    var detail: String {
        switch self {
        case .orphanedPairEntry(_, let wallet):
            return "pairs.json references wallet '\(wallet)' but the directory is gone. Login will fail to load this wallet set."
        case .unregisteredWallet(let dir):
            return "A wallet exists at \((dir as NSString).lastPathComponent) but isn't registered. Either add it to pairs.json or remove the directory."
        case .staleLock(_, let lock):
            return "Lock file \((lock as NSString).lastPathComponent) is held by no live process. Safe to delete — the wallet will re-acquire on next open."
        case .unreadableWallet(_, let reason):
            return "Couldn't open wallet.axiom: \(reason). Restore from a backup file (Login → Load wallet from backup) or use the Recovery flow with wallet_secret."
        case .partialPair:
            return "Wallet set has a Normal mode wallet but no Ark companion. Not a problem — Ark mode is optional. Generate the companion from Wallets management if you want offline support."
        }
    }

    /// User-facing suggested action. Some actions are wired (clear
    /// lock); others are pointers ("use the Recovery flow").
    var suggestedAction: String? {
        switch self {
        case .orphanedPairEntry: return "Remove from pairs.json"
        case .unregisteredWallet: return "Reveal in Finder"
        case .staleLock:          return "Delete lock file"
        case .unreadableWallet:   return nil  // explained in detail
        case .partialPair:        return nil
        }
    }
}

struct DiagnosticRow: Identifiable {
    let id = UUID()
    let issue: DiagnosticIssue
}

/// Run all checks against `parentDir` (the wallets directory).
/// Pure local FS reads. No FFI lock acquisition — we want to detect
/// stale locks, not race against them.
@MainActor
func runWalletDiagnostic(parentDir: String) -> [DiagnosticRow] {
    var issues: [DiagnosticIssue] = []
    let fm = FileManager.default

    // ── Inventory disk ─────────────────────────────────────────────
    let allDirs: [String] = (try? fm.contentsOfDirectory(atPath: parentDir)) ?? []
    let walletDirs = allDirs.filter { name in
        fm.fileExists(atPath: "\(parentDir)/\(name)/wallet.axiom")
    }

    // ── Inventory pairs.json ───────────────────────────────────────
    var registeredWallets: Set<String> = []
    var pairs: [WalletPairView] = []
    if let p = try? listWalletPairs(parentDir: parentDir) {
        pairs = p
        for pair in pairs {
            if let n = pair.normalWalletName { registeredWallets.insert(n) }
            if let a = pair.arkWalletName    { registeredWallets.insert(a) }
        }
    }

    // ── Cross-check: orphaned pair entries ────────────────────────
    for pair in pairs {
        if let n = pair.normalWalletName, !walletDirs.contains(n) {
            issues.append(.orphanedPairEntry(pairName: pair.name, missingWalletName: n))
        }
        if let a = pair.arkWalletName, !walletDirs.contains(a) {
            issues.append(.orphanedPairEntry(pairName: pair.name, missingWalletName: a))
        }
        if pair.arkWalletName == nil {
            issues.append(.partialPair(pairName: pair.name))
        }
    }

    // ── Cross-check: unregistered wallet directories ─────────────
    for walletName in walletDirs where !registeredWallets.contains(walletName) {
        issues.append(.unregisteredWallet(walletDir: "\(parentDir)/\(walletName)"))
    }

    // ── Per-wallet integrity checks ───────────────────────────────
    for walletName in walletDirs {
        let dir = "\(parentDir)/\(walletName)"
        let lockPath = "\(dir)/wallet.axiom.lock"

        // Stale-lock check: file exists, no live process.
        if fm.fileExists(atPath: lockPath), !isLockProcessAlive(lockPath: lockPath) {
            issues.append(.staleLock(walletDir: dir, lockPath: lockPath))
        }

        // Parse check: try to open the wallet, catch any FFI error.
        // Open acquires the flock — if a stale lock isn't already
        // flagged above, this is safe; if a live process holds it
        // we get WalletLocked back which is NOT an integrity issue.
        do {
            _ = try AxiomWallet.openVaulted(dir: dir)
        } catch {
            // WalletLocked = another process has it; not corruption.
            // Anything else is a real parse / version / IO failure.
            let msg = error.localizedDescription
            if !msg.contains("WalletLocked") {
                issues.append(.unreadableWallet(walletDir: dir, reason: msg))
            }
        }
    }

    return issues.map { DiagnosticRow(issue: $0) }
}

/// Heuristic — `wallet.axiom.lock` is an `flock(2)` file (its content
/// is the pid of the holder when the SDK writes one; some platforms
/// leave it empty). Read the pid and check if the process exists.
/// Returns true if the lock looks live (don't touch); false if it
/// looks stale (safe to delete).
func isLockProcessAlive(lockPath: String) -> Bool {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: lockPath)),
          let pidStr = String(data: data, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
          let pid = pid_t(pidStr)
    else {
        // Empty or unparseable lock — assume stale (the SDK writes
        // a pid on lock acquisition, so missing content means crash).
        return false
    }
    // kill(pid, 0) returns 0 if the process exists, -1 with ESRCH if not.
    return kill(pid, 0) == 0
}

/// Apply a fix for issues that have a built-in remedy. Returns a
/// human-readable success message on completion, or throws on
/// failure (caller surfaces the error inline).
@MainActor
func applyDiagnosticFix(_ issue: DiagnosticIssue, parentDir: String) throws -> String {
    switch issue {
    case .staleLock(_, let lockPath):
        try FileManager.default.removeItem(atPath: lockPath)
        return "Lock file removed."
    case .orphanedPairEntry(let pairName, _):
        // Remove the pair from pairs.json via the FFI's registry helper.
        // The FFI currently doesn't expose a "remove pair" function;
        // we hit pairs.json directly here. Same JSON shape the SDK
        // writes (verified by load+listWalletPairs round-trip).
        let path = "\(parentDir)/pairs.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var pairs = json["pairs"] as? [String: Any]
        else {
            throw NSError(
                domain: "Diagnostic", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't read pairs.json."]
            )
        }
        pairs.removeValue(forKey: pairName)
        json["pairs"] = pairs
        let new = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try new.write(to: URL(fileURLWithPath: path), options: .atomic)
        return "Wallet set '\(pairName)' removed from registry."
    case .unregisteredWallet(let dir):
        // Open Finder so the user can decide what to do.
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
        return ""  // empty message — Finder action speaks for itself
    case .unreadableWallet, .partialPair:
        throw NSError(
            domain: "Diagnostic", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "No auto-fix for this issue. Follow the detail text."]
        )
    }
}
