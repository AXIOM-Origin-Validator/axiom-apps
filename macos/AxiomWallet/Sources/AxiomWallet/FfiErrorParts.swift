import Foundation
import AxiomSdk

/// Pull the `(code, message, recovery, isWalletTerminal)` parts out of
/// an `FfiError` raised across the uniffi bridge.
///
/// Recovery + isWalletTerminal are populated for `FfiError.Other`
/// (the catch-all that most SDK errors go through, including every
/// genesis-claim and send/redeem failure mode the UI dispatches on).
/// For the typed variants (`WalletNotFound`, `InvalidRecipient`,
/// etc.) we hardcode the canonical recovery and terminal flag — these
/// variants are stable in their disposition (per
/// `ErrorCode::canonical_recovery` / `is_wallet_terminal` in
/// sdk/core/src/errors.rs) and a hardcoded map here is cheaper than
/// pushing the strings across the FFI for every typed variant.
///
/// For non-FfiError throws (rare — SDK internal panics, Swift-side
/// runtime errors), fall back to a string-parse of
/// `localizedDescription`. The parse handles uniffi's `Other` Display
/// format `"Other: <code> — <message>"`.
///
/// Shared by SendView, RedeemConfirmSheet (BundleDetailView),
/// GenesisClaimSheet, HealConfirmSheet, and SendCoordinator so the
/// dispatch logic isn't duplicated.
struct FfiErrorParts {
    let code: String?
    let message: String
    /// Canonical recovery action as a wire-stable string from the
    /// Rust SDK. Values: `"Retry"`, `"RetryAfter:<secs>"`, `"Heal"`,
    /// `"CheckInbox"`, `"CompleteRegistration"`, `"Fatal"`. `nil`
    /// only when the error isn't an `FfiError` (rare).
    let recovery: String?
    /// True iff this error indicates the wallet identity is
    /// permanently unusable (YP §17.11.7.2 terminal cases). UI uses
    /// this to discriminate "create new keypair" from "internal
    /// bug, please report" — both are Fatal recoveries but the
    /// user-facing action differs.
    let isWalletTerminal: Bool
}

/// Tier 1 FACT-chain corruption surface — shared copy so the
/// "discovered while sending/redeeming" path (ErrorCode
/// `FactChainCorrupted`, recovery Fatal) and the "discovered while idle"
/// path (`diagnose()` action `fact_chain_broken`) read identically.
///
/// Disposition: Fatal but NOT wallet-terminal. The keypair is fine
/// (`isWalletTerminal` is false → never show "create new keypair"); the
/// on-disk FACT chain is structurally broken. The wallet can still
/// RECEIVE but cannot SEND. No automatic recovery yet (PR2) — do NOT
/// offer heal/burn, those re-ship the broken chain and Core rejects them.
enum FactChainCorruption {
    static let code = "FactChainCorrupted"
    static let diagnoseAction = "fact_chain_broken"
    static let title = "Wallet structurally corrupted"
    static let body =
        "This wallet's transaction history (FACT chain) has a continuity "
        + "break that can't be recovered automatically yet. It can still "
        + "RECEIVE, but cannot SEND. Don't delete or wipe this wallet — its "
        + "history is needed for recovery. For help, ask the AXIOM community "
        + "on GitHub (there is no support desk — AXIOM is decentralized)."
}

/// AXIOM has no operator / support desk — it's a decentralized, community-run
/// network. Anywhere the wallet would once have said "contact the operator,"
/// it points here: the public repo the wallet already uses for releases +
/// seeds, whose Issues/Discussions are the community support venue.
enum CommunitySupport {
    static let url = URL(string: "https://github.com/AXIOM-Origin-Validator/axiom-dist")!
    static let label = "AXIOM community on GitHub"
}

// =================================================================
// YPX-020 HAL — dead-overlap + hibernation classification.
//
// Two transient, wallet-HEALTHY conditions the recovery UX keys on.
// Neither leaves persistent on-disk state (unlike a scar / partial
// commit), so `diagnose()` reports nothing — they can only be read
// off a send/redeem failure as it happens.
// =================================================================
enum HalRecovery {

    /// Dead-overlap: the wallet's prior witnesses have all gone away, so
    /// it can no longer meet the `k-1` S-ABR overlap on an ordinary
    /// send/redeem (a liveness failure, never a double-spend). `heal()`
    /// does NOT recover this — the recovery is `hal_reanchor()`. Core /
    /// Lambda surface it as `SABRInsufficientOverlap`; older / wire
    /// paths phrase it "insufficient overlap".
    static func isDeadOverlap(code: String?, message: String) -> Bool {
        if let code, code == "SABRInsufficientOverlap" { return true }
        let m = message.lowercased()
        return m.contains("insufficient overlap")
    }

    /// Hibernating: after a re-anchor the wallet is frozen for the
    /// convergence window. Core rejects an in-window spend with
    /// `E_WALLET_HIBERNATING` / `WalletHibernating`; Nabla rejects an
    /// in-window cheque-claim (redeem) with a bare "HIBERNATING". In the
    /// binary model this does NOT auto-clear — the wallet stays
    /// hibernating until the user finishes recovery (`hal_complete`).
    static func isHibernating(code: String?, message: String) -> Bool {
        if let code,
           code == "WalletHibernating"
            || code == "E_WALLET_HIBERNATING"
            || code.uppercased().contains("HIBERNAT") { return true }
        return message.uppercased().contains("HIBERNAT")
    }

    /// Human estimate label for the convergence window — UX only (an
    /// upper-bound; see AppSession.hibernationConvergenceEstimateSecs).
    /// "~25h" / "~30m" / "~45s" / "elapsed".
    static func estimateLabel(_ secs: UInt64) -> String {
        if secs == 0 { return "elapsed" }
        if secs < 90 { return "~\(secs)s" }
        let mins = (secs + 59) / 60
        if mins < 90 { return "~\(mins)m" }
        let hours = Double(secs) / 3600.0
        return String(format: "~%.1fh", hours)
    }

    /// Friendly hibernation message for any failure surface (banner /
    /// sheet). Binary model: the lock clears only on completion, so the
    /// guidance is "finish recovery", never "wait for a timer".
    static func hibernatingMessage() -> String {
        "Wallet is hibernating after a re-anchor. Send and redeem stay "
            + "paused until you finish recovery (Complete HAL) — it does "
            + "not clear on its own."
    }
}

// =================================================================
// YPX-001 §1.5.1 — scar-consent gate classification.
//
// A send whose FACT chain carries unresolved scar(s) pauses at the
// overlapped validator with `ScarConsentRequired` (Recovery::Fatal —
// the SDK never retries; consent is a user decision). The same code
// carries three distinct flavors, distinguished by message content
// (the witness error path forwards only the message — see the scar
// dispatch in sdk/client/src/send.rs):
//   1. initial pause   — the gate fired; receiver was notified
//   2. wrong passcode  — "Scar passcode rejected by validator …";
//                        record + stored passcode SURVIVE, re-enter
//   3. transient hop   — "… was not selectable for this round";
//                        retry shortly, non-destructive
// =================================================================
enum ScarConsent {
    static let code = "ScarConsentRequired"

    static func isScarConsent(code: String?) -> Bool {
        code == ScarConsent.code
    }

    /// Flavor 2 — the validator rejected the entered passcode. The
    /// pending record and the validator's stored passcode both survive
    /// (deleted only on a match): let the user re-enter.
    static func isWrongPasscode(message: String) -> Bool {
        message.contains("rejected by validator")
            || message.contains("Invalid scar passcode")
    }

    /// Flavor 3 — the passcode-storing validator wasn't selectable for
    /// this round. Nothing was lost; retry shortly.
    static func isTransientHop(message: String) -> Bool {
        message.contains("not selectable for this round")
    }

    /// Friendly copy for the initial pause (flavor 1).
    static let pausedTitle = "Payment paused — receiver consent required"
    static let pausedBody =
        "This money carries unverified provenance link(s), so the validator "
            + "paused the payment and notified the receiver with a 6-digit "
            + "passcode. The payment completes only when the receiver shares "
            + "that passcode with you — ask them directly. Nothing has moved. "
            + "If the receiver declines, simply do nothing."
}

func extractFfiErrorParts(_ error: any Error) -> FfiErrorParts {
    if let ffiError = error as? FfiError {
        switch ffiError {
        case .Other(let code, let message, let recovery, let isWalletTerminal):
            return FfiErrorParts(
                code: code,
                message: message,
                recovery: recovery,
                isWalletTerminal: isWalletTerminal
            )
        case .WalletNotFound(let message):
            return FfiErrorParts(code: "WalletNotFound", message: message, recovery: "Fatal", isWalletTerminal: false)
        case .WalletAlreadyExists(let message):
            return FfiErrorParts(code: "WalletAlreadyExists", message: message, recovery: "Fatal", isWalletTerminal: false)
        case .WalletLocked(let message):
            return FfiErrorParts(code: "WalletLocked", message: message, recovery: "Retry", isWalletTerminal: false)
        case .WalletVersionMismatch(let message):
            return FfiErrorParts(code: "WalletVersionMismatch", message: message, recovery: "Fatal", isWalletTerminal: false)
        case .InvalidRecipient(let message):
            return FfiErrorParts(code: "InvalidRecipient", message: message, recovery: "Fatal", isWalletTerminal: false)
        case .StorageError(let message):
            return FfiErrorParts(code: "StorageError", message: message, recovery: "Fatal", isWalletTerminal: false)
        }
    }
    // Fallback for non-FfiError throws — parse the Display string.
    // FfiError.Other formats as: "Other: <code> — <message>"
    let desc = error.localizedDescription
    if desc.hasPrefix("Other: "),
       let dashRange = desc.range(of: " — ") {
        let after = desc.index(desc.startIndex, offsetBy: "Other: ".count)
        let code = String(desc[after..<dashRange.lowerBound])
        let message = String(desc[dashRange.upperBound...])
        return FfiErrorParts(code: code, message: message, recovery: nil, isWalletTerminal: false)
    }
    return FfiErrorParts(code: nil, message: desc, recovery: nil, isWalletTerminal: false)
}
