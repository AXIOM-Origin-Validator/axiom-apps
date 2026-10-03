import Foundation

// =================================================================
// Which addresses FATMAMA will register.
//
// `XAXIOM-REGISTER <email>` is accepted ONLY for the cluster domains —
// `@axiom` and `@axiom.internal`. Anything else is refused with
// `550 5.7.1 cluster domain only` (scripts/fatmama.py, is_cluster_recipient).
//
// WHY THIS IS ITS OWN RULE, and not `KiddoAccount.isDevEmail`. That predicate
// is Core's DEV-CLASS rule (`is_dev_wallet` / R1, `@axiom.internal` exactly)
// and it has a different owner and a different job — it decides fee routing
// and wallet class, not what a mail relay will accept. They overlap today;
// binding them together would mean a change to either silently moves the
// other. Validators live at `<node>@axiom`, which is registerable but NOT
// dev-class, so the two already disagree.
//
// WHY IT MATTERS (2026-09-11). Both FATMAMA register paths gated on the
// account's KIND (`.axiomDev`) rather than its ADDRESS, and the two can
// disagree: a real `user@mac.com`-style address sitting on an `.axiomDev` account was
// live in accounts.json. That offered a button which always fails, and armed
// a 30-second auto-register loop whose 550 is swallowed by design — an
// invisible, permanent retry against a server that will never say yes.
// =================================================================

/// True iff FATMAMA would accept `XAXIOM-REGISTER` for this address.
///
/// Domain match is exact and case-insensitive; a subdomain is NOT a cluster
/// address (`x@axiom.internal.example.com` is someone else's host, and
/// treating it as ours would send a stranger's address to the dev relay).
/// Anything without an `@`, or with an empty local part, is not an address.
public func fatmamaAcceptsAddress(_ email: String) -> Bool {
    let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let atIdx = trimmed.firstIndex(of: "@") else { return false }
    let local = trimmed[trimmed.startIndex..<atIdx]
    let domain = trimmed[trimmed.index(after: atIdx)...].lowercased()
    guard !local.isEmpty else { return false }
    // A second `@` means this is not a plain address — FATMAMA's care-of form
    // is deliberately not a legal address, and it is not registerable either.
    guard !domain.contains("@") else { return false }
    return domain == "axiom" || domain == "axiom.internal"
}
