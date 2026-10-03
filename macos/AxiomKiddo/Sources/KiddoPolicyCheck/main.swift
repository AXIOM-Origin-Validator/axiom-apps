import Foundation
import KiddoPolicy

// =================================================================
// KiddoPolicyCheck — the retention gate.
//
// `swift run KiddoPolicyCheck` · exits 0 when every case holds, 1 with the
// failures listed otherwise. Not a `.testTarget`: XCTest and swift-testing
// both require a full Xcode, and this machine has CommandLineTools, so
// `swift test` cannot build here.
//
// Covers the irreversible half of docs/AXIOM_DESIGN_CarrierHandoff.md §5:
// the decision matrix, the header test that feeds it, the seen-store that
// carries a landed filename across ticks, and the SDK status file's tolerance
// for junk. Per §8.2 each arm is asserted, not sampled — a wrong delete takes
// someone's mail and cannot be undone.
// =================================================================

var failures: [String] = []

func check(_ cond: Bool, _ what: String) {
    if !cond { failures.append(what) }
}

func checkEqual<T: Equatable>(_ got: T, _ want: T, _ what: String) {
    if got != want { failures.append("\(what) — expected \(want), got \(got)") }
}

// ── The decision matrix, exhaustive ──────────────────────────────────────
// All twelve (mode × isAxiom × wasConsumed). Written out rather than looped:
// when someone changes the rule, the failure names the case that moved.
let matrix: [(RetentionMode, Bool, Bool, Bool)] = [
    // Leave everything — nothing is ever deleted, whatever else is true.
    (.leaveEverything, false, false, false),
    (.leaveEverything, false, true,  false),
    (.leaveEverything, true,  false, false),
    (.leaveEverything, true,  true,  false),

    // AXIOM only — both conditions, and only both.
    (.axiomOnly, false, false, false),
    (.axiomOnly, false, true,  false),   // someone else's mail the SDK never saw
    (.axiomOnly, true,  false, false),   // our cheque, unused — may still be needed
    (.axiomOnly, true,  true,  true),    // the single true in this mode

    // Delete all — the behaviour every account had before this existed.
    (.deleteAll, false, false, true),
    (.deleteAll, false, true,  true),
    (.deleteAll, true,  false, true),
    (.deleteAll, true,  true,  true),
]
for (mode, axiom, consumed, want) in matrix {
    checkEqual(
        mayDeleteFromServer(mode: mode, isAxiomMail: axiom, wasConsumed: consumed),
        want,
        "matrix mode=\(mode.rawValue) axiom=\(axiom) consumed=\(consumed)"
    )
}

// The two cases that cost a user their mail if they are wrong, called out
// separately so a failure reads as what it is rather than as a table row.
check(!mayDeleteFromServer(mode: .axiomOnly, isAxiomMail: false, wasConsumed: true),
      "axiomOnly must never delete someone else's mail")
check(!mayDeleteFromServer(mode: .axiomOnly, isAxiomMail: true, wasConsumed: false),
      "axiomOnly must not delete AXIOM mail the wallet has not used")

// ── The header test ──────────────────────────────────────────────────────
func m(_ s: String) -> Data { Data(s.utf8) }

check(messageIsAxiomMail(m("From: alpha@axiom\r\nTo: w@axiom.internal\r\nSubject: AXIOM/cheque/abc-123\r\n\r\nYm9keQ==\r\n")),
      "a cheque's own subject must be recognised")
check(messageIsAxiomMail(m("subject: AXIOM/witness_response/x\r\nFrom: beta@axiom\r\n\r\nbody")),
      "header name is case-insensitive and order must not matter")

// The false positives. Each one, if it flipped, would delete ordinary mail.
check(!messageIsAxiomMail(m("From: bank@example.com\r\nSubject: Your statement\r\n\r\nSubject: AXIOM/cheque/x\r\n")),
      "a body that quotes the marker is not ours")
check(!messageIsAxiomMail(m("Subject: Re: about AXIOM/cheque\r\n\r\nbody")),
      "the marker must be at the START of the subject")
check(!messageIsAxiomMail(m("From: a@b.c\r\nSubject: holiday photos\r\n\r\nhello")),
      "ordinary mail is not ours")
check(!messageIsAxiomMail(m("")), "empty input is not ours")
check(!messageIsAxiomMail(m("\r\nSubject: AXIOM/cheque/x\r\n")),
      "a subject after the header block has ended is not a header")

// ── Which addresses FATMAMA will register ────────────────────────────────
// Wrong in the permissive direction = a button that always fails and a 30s
// auto-register loop swallowing 550s forever. Wrong the other way = a dev
// wallet that cannot receive at all.
for (addr, want, why) in [
    ("alice@axiom.internal", true,  "the dev wallet class"),
    ("alpha@axiom",          true,  "validators live here — registerable, though NOT dev-class"),
    ("ALICE@AXIOM.INTERNAL", true,  "domain match is case-insensitive"),
    ("  bob@axiom  ",        true,  "surrounding whitespace is not part of the address"),
    ("someone@mac.com",      false, "a real (non-@axiom) address — the shape that was live in accounts.json"),
    ("x@axiom.internal.example.com", false, "a subdomain is someone else's host, not ours"),
    ("x@notaxiom",           false, "near-miss domain"),
    ("@axiom.internal",      false, "no local part is not an address"),
    ("noatsign",             false, "not an address"),
    ("",                     false, "empty"),
    ("a@axiom@axiom",        false, "the care-of form is deliberately not a legal address"),
] {
    checkEqual(fatmamaAcceptsAddress(addr), want, "fatmamaAcceptsAddress(\(addr.isEmpty ? "<empty>" : addr)) — \(why)")
}

// ── Seen-store ───────────────────────────────────────────────────────────
// Its job is to remember the filename the SDK will name on a LATER tick.
// Lose the name and a message can never be matched to a status entry, so
// axiomOnly would keep it forever.
let acct = UUID()
var store = SeenStore(accountID: acct)
store.record(key: "u:UID-1", name: "1757568000.42.host.abc", axiom: true)
store.save()

let reloaded = SeenStore(accountID: acct)
checkEqual(reloaded.entry("u:UID-1")?.name, "1757568000.42.host.abc",
           "the landed name must survive a reload")
checkEqual(reloaded.entry("u:UID-1")?.axiom, true, "and so must the AXIOM verdict")
check(reloaded.entry("u:UID-2") == nil, "a key never recorded must not resolve")

// Without UIDL there is no server id, so the key comes from the bytes —
// otherwise "leave everything" re-delivers forever on exactly the servers
// that cannot help us.
let body = m("Subject: AXIOM/cheque/x\r\n\r\nbody")
checkEqual(SeenStore.key(uid: "UID-9", body: body), "u:UID-9", "a UIDL is used verbatim")
check(SeenStore.key(uid: nil, body: body).hasPrefix("h:"), "no UIDL falls back to a hash")
checkEqual(SeenStore.key(uid: nil, body: body), SeenStore.key(uid: nil, body: body),
           "the hash must be stable")
check(SeenStore.key(uid: nil, body: body) != SeenStore.key(uid: nil, body: m("different")),
      "different bytes must not collide")
check(SeenStore.key(uid: "", body: body).hasPrefix("h:"), "an empty uid is not an id")

// IMAP keys (2026-09-13): stable, namespaced, and never a POP3 key — a UID
// alone is not an identity (it resets with UIDVALIDITY).
checkEqual(SeenStore.imapKey(uidValidity: 7, uid: 42), "i:7/42", "imap key shape")
check(SeenStore.imapKey(uidValidity: 7, uid: 42) != SeenStore.imapKey(uidValidity: 8, uid: 42),
      "the same UID under a new UIDVALIDITY is a different message")
check(SeenStore.imapKey(uidValidity: 7, uid: 42) != SeenStore.key(uid: "7/42", body: body),
      "an IMAP key must never collide with a POP3 UIDL of the same digits")
check(SeenStore.imapKey(uidValidity: 7, uid: 42).hasPrefix("i:"), "imap namespace")

// ── The SDK's status file ────────────────────────────────────────────────
let tmp = NSTemporaryDirectory() + "/kiddo-policy-check-\(UUID().uuidString)"
let carrier = tmp + "/carrier"
try? FileManager.default.createDirectory(atPath: carrier, withIntermediateDirectories: true)

// Absent file → nothing known → nothing deletable. The fail-closed property
// the whole design rests on (§7).
let emptyDir = NSTemporaryDirectory() + "/kiddo-policy-empty-\(UUID().uuidString)"
try? FileManager.default.createDirectory(atPath: emptyDir, withIntermediateDirectories: true)
check(CarrierStatus.read(walletDir: emptyDir).consumed.isEmpty,
      "a missing status file must report nothing consumed")

// A torn tail, a blank line and a verdict from a newer SDK must not take the
// file down with them — and an unknown verdict must not license a delete.
let jsonl = """
{"file":"good-1","verdict":"consumed","at":1}

not json at all
{"file":"future-1","verdict":"settled","at":2}
{"file":"good-2","verdict":"consumed","at":3}
{"file":"torn-1","verd
"""
try? jsonl.write(toFile: carrier + "/status.jsonl", atomically: true, encoding: .utf8)
let consumed = CarrierStatus.read(walletDir: tmp).consumed
checkEqual(consumed, Set(["good-1", "good-2"]), "only well-formed consumed lines count")
check(!consumed.contains("future-1"), "an unknown verdict must not license a delete")
check(!consumed.contains("torn-1"), "a torn line must be skipped")

// ── Report ───────────────────────────────────────────────────────────────
if failures.isEmpty {
    print("KiddoPolicyCheck: OK — \(matrix.count) matrix cases + header, seen-store (POP3 + IMAP keys), status-file and FATMAMA-address checks")
    exit(0)
} else {
    print("KiddoPolicyCheck: \(failures.count) FAILED")
    for f in failures { print("  ✗ \(f)") }
    exit(1)
}
