import Foundation

// =================================================================
// Contacts — purely client-side, JSON-backed.
//
// Stored at ~/Library/Application Support/Axiom/contacts.json. No
// protocol involvement, no FFI surface. The protocol does NOT have
// a "verified contact" concept — `priorSendCount` is a local
// heuristic that lets the UI show a ✓ marker when the user has
// successfully transacted with this counterparty before. That's
// also a follow-up; for now we just store a count the user can
// optionally bump on successful send (future commit wires it).
// =================================================================

struct Contact: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var address: String
    /// Optional cheque delivery override — populates `receiver_address`
    /// on outgoing TXs to this contact (YP §16.14.11). When the
    /// contact's wallet_id local-part email becomes stale (job change,
    /// domain retired, etc.), the wallet owner publishes their current
    /// delivery email out-of-band; senders save it here so cheques land
    /// in the right inbox while the wallet_id itself remains immutable.
    /// Signature covers `receiver_wallet_id`, NOT `receiver_address` —
    /// only the routing differs, never the binding.
    var deliveryEmail: String
    var notes: String
    var priorSendCount: Int
    var addedAt: Date
    /// True for rows auto-created by `ContactsStore.syncOwnWallets` — one of
    /// THIS Mac's own wallets, not a counterparty. Drives the "your wallet"
    /// badge, and marks the row as ours to re-title on a pair rename. A row
    /// the user typed themselves always stays `false`, even if it happens to
    /// hold an address we'd otherwise auto-add.
    var isOwnWallet: Bool
    /// For an own-wallet row: the Ark keypair rather than the Normal one.
    /// Stored rather than parsed back out of the display name, and it drives
    /// the avatar colour (see ContactsView) — Normal red / Ark neutral, the
    /// same mapping as WalletsView's per-wallet tag chips. Always false on a
    /// counterparty row.
    var ownWalletIsArk: Bool

    init(name: String, address: String, deliveryEmail: String = "", notes: String = "", priorSendCount: Int = 0, isOwnWallet: Bool = false, ownWalletIsArk: Bool = false) {
        self.id = UUID()
        self.name = name
        self.address = address
        self.deliveryEmail = deliveryEmail
        self.notes = notes
        self.priorSendCount = priorSendCount
        self.addedAt = Date()
        self.isOwnWallet = isOwnWallet
        self.ownWalletIsArk = ownWalletIsArk
    }

    // Hand-written decode so a contacts.json from <= 2.23.0 (no `isOwnWallet`
    // key) still loads. Swift's synthesized decoder does NOT fall back to a
    // property's default value — it throws `keyNotFound` — and load() treats a
    // decode throw as `loadFailed`, which then REFUSES every subsequent save().
    // A synthesized decoder here would therefore freeze the address book of
    // every existing user: contacts unreadable, adds silently discarded.
    //
    // CLAUDE.md §13 (no back-compat bandaids) governs pre-mainnet protocol and
    // wire formats; it explicitly exempts shipped on-disk data that must keep
    // loading, which is exactly what contacts.json is.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        address = try c.decode(String.self, forKey: .address)
        deliveryEmail = try c.decodeIfPresent(String.self, forKey: .deliveryEmail) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        priorSendCount = try c.decodeIfPresent(Int.self, forKey: .priorSendCount) ?? 0
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        isOwnWallet = try c.decodeIfPresent(Bool.self, forKey: .isOwnWallet) ?? false
        ownWalletIsArk = try c.decodeIfPresent(Bool.self, forKey: .ownWalletIsArk) ?? false
    }
}

/// One of this Mac's own wallets, flattened to what the address book needs.
/// Keeps `ContactsStore` free of any SDK/FFI dependency — the caller resolves
/// `wallet.address()` and hands over plain strings.
struct OwnWalletEntry {
    let name: String
    let address: String
    let isArk: Bool
}

/// THE rule for how one wallet pair becomes address-book rows. Pure: the caller
/// (`ownWalletEntries`) does the throwing `address()` resolution and hands the
/// results here, which keeps this free of the SDK and therefore testable.
///
/// ONE row per DISTINCT address, not one per pair member:
///
/// - **Single-keypair pair** (Ark convergence): both members share one Ed25519
///   keypair, and `address()` derives from (email, salt(pk), pk) with NO tier
///   input, so both resolve to the SAME string. That is one wallet — it gets one
///   row named for the pair, no mode suffix. Two rows would collide in the store
///   (which keys by address): the Ark entry would rename the Normal row and
///   re-flag it Ark, leaving a single grey row whose label lies, since the
///   address it holds is the Standard-tier one, not an Ark-tier one.
/// - **Legacy pair** (minted pre-convergence, two independent keypairs): two
///   genuinely different addresses, so two suffixed rows, as before.
///
/// The DATA decides which shape applies, not a build date or a migration flag —
/// both kinds of pair can sit on the same Mac at once.
func ownWalletRows(pairName: String, normalAddress: String?, arkAddress: String?) -> [OwnWalletEntry] {
    let normal = normalAddress?.trimmingCharacters(in: .whitespaces)
    let ark = arkAddress?.trimmingCharacters(in: .whitespaces)

    if let n = normal, let a = ark, n == a, !n.isEmpty {
        return [OwnWalletEntry(name: pairName, address: n, isArk: false)]
    }

    var out: [OwnWalletEntry] = []
    if let n = normal, !n.isEmpty {
        out.append(OwnWalletEntry(name: "\(pairName) (Normal)", address: n, isArk: false))
    }
    if let a = ark, !a.isEmpty {
        out.append(OwnWalletEntry(name: "\(pairName) (Ark)", address: a, isArk: true))
    }
    return out
}

@MainActor
final class ContactsStore: ObservableObject {
    @Published private(set) var contacts: [Contact] = []

    /// True iff the most recent `load()` either read + decoded the file
    /// successfully OR confirmed the file doesn't exist. False when the
    /// file existed but couldn't be decoded — in that case `save()`
    /// REFUSES to overwrite (the alternative is silently destroying
    /// the user's contacts on a transient read failure: empty
    /// in-memory + any add/update/delete writes a fresh file that
    /// has only the new entry, wiping whatever was there).
    ///
    /// Surfacing this as a flag rather than a hard fail keeps the UI
    /// alive — the user can still browse the (empty) in-memory list
    /// — but any attempt to mutate is blocked at the storage layer
    /// until the next load() succeeds.
    private(set) var loadFailed: Bool = false

    private let fileURL: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("Axiom")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("contacts.json")
    }()

    init() {
        NSLog("[ContactsStore] init — fileURL=\(fileURL.path)")
        load()
    }

    func load() {
        let path = fileURL.path
        let fm = FileManager.default

        if !fm.fileExists(atPath: path) {
            // First-run / post-erase case. Nothing on disk; nothing
            // to load. Future save() is fine — there's nothing to
            // accidentally overwrite.
            NSLog("[ContactsStore] load: no file at \(path); starting empty")
            contacts = []
            loadFailed = false
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            // File exists but we can't read its bytes — refuse to
            // save until next load() succeeds.
            NSLog("[ContactsStore] load: file exists at \(path) but read failed; loadFailed=true")
            loadFailed = true
            return
        }

        do {
            // CRITICAL: match the encoder's dateEncodingStrategy
            // (.iso8601, see save() below). Without this, every
            // relaunch silently lost contacts — load() saw a
            // String where Date's default decoder expected a
            // Double-seconds-since-2001, threw, and the catch
            // branch left contacts empty. Same Mac → next add()
            // overwrote the file with just the new entry. Was
            // baked into the original ContactsStore commit; the
            // bug only surfaced consistently once a tester ran
            // multiple launches with persistent contacts.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode([Contact].self, from: data)
            contacts = decoded.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            loadFailed = false
            NSLog("[ContactsStore] load: ok — \(contacts.count) contact(s) at \(path)")
        } catch {
            NSLog("[ContactsStore] load: decode failed at \(path): \(error). loadFailed=true; not touching file")
            loadFailed = true
        }
    }

    func save() {
        if loadFailed {
            NSLog("[ContactsStore] save: REFUSED — last load() failed; existing file preserved")
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(contacts)
            try data.write(to: fileURL, options: .atomic)
            NSLog("[ContactsStore] save: wrote \(contacts.count) contact(s)")
        } catch {
            NSLog("[ContactsStore] save: failed: \(error)")
        }
    }

    func add(_ contact: Contact) {
        contacts.append(contact)
        contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func update(_ contact: Contact) {
        guard let idx = contacts.firstIndex(where: { $0.id == contact.id }) else { return }
        contacts[idx] = contact
        contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func delete(_ contact: Contact) {
        contacts.removeAll { $0.id == contact.id }
        save()
    }

    /// Mirror this Mac's own wallet addresses into the address book so a
    /// send between your own wallets doesn't need copy/paste.
    ///
    /// ADDITIVE ONLY — this never deletes. `desired` covers only the pairs
    /// unlocked THIS session, so a wallet set the user didn't unlock is simply
    /// absent from it; pruning own-rows that aren't in `desired` would wipe the
    /// other sets' entries on every launch. The cost of never pruning is a
    /// stale row after a wallet is deleted, which the user can remove by hand.
    ///
    /// A row the user typed themselves is left completely alone even when it
    /// holds an address we'd otherwise add — their name wins, and we never
    /// silently retitle or re-own a row we didn't create.
    func syncOwnWallets(_ desired: [OwnWalletEntry]) {
        // Same guard as save(): if the last load() couldn't decode the file,
        // the in-memory list is NOT the user's real address book, and appending
        // to it would be building on sand. save() would refuse anyway — bail
        // early so the reason lands in the log.
        if loadFailed {
            NSLog("[ContactsStore] syncOwnWallets: SKIPPED — last load() failed")
            return
        }

        var changed = false
        for entry in desired {
            let addr = entry.address.trimmingCharacters(in: .whitespaces)
            guard !addr.isEmpty else { continue }

            if let idx = contacts.firstIndex(where: { $0.address == addr }) {
                // Only ever touch a row we created (e.g. the user renamed the
                // pair in WalletsView). A user-added row is untouchable.
                guard contacts[idx].isOwnWallet else { continue }
                if contacts[idx].name != entry.name {
                    contacts[idx].name = entry.name
                    changed = true
                }
                // Also repairs rows written by 2.24.1, which predates the flag
                // and decodes it as false — an Ark row would otherwise keep a
                // Normal-red avatar until the file was rewritten.
                if contacts[idx].ownWalletIsArk != entry.isArk {
                    contacts[idx].ownWalletIsArk = entry.isArk
                    changed = true
                }
            } else {
                contacts.append(Contact(name: entry.name, address: addr, isOwnWallet: true, ownWalletIsArk: entry.isArk))
                changed = true
            }
        }

        if changed {
            contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            save()
            NSLog("[ContactsStore] syncOwnWallets: \(contacts.filter(\.isOwnWallet).count) own-wallet row(s) of \(contacts.count)")
        }
    }
}
