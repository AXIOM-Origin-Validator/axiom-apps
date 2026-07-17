import Foundation
import SwiftUI
import AppKit
import AxiomSdk

// =================================================================
// ScarConsentStore — receiver-side retention of scar-consent
// notifications (YPX-001 §1.5.1).
//
// `wallet.recvScarConsents()` is CONSUME-ONCE: the SDK moves each
// AXIOM/scar_consent email from inbox/new → inbox/cur and returns it
// exactly once. The UI must therefore retain what it was handed or
// the passcode is lost on the next refresh tick. JSON-backed at
// ~/Library/Application Support/Axiom/scar_consents.json (the
// ContactsStore pattern) so a notification survives an app restart —
// losing it would strand the sender's paused payment until they
// start a fresh send.
//
// Purely client-side bookkeeping. Consent itself is the HUMAN
// hand-off of the passcode to the sender — there is deliberately no
// network action in this store (YPX-001: "REJECT = do nothing").
// =================================================================

struct ScarConsentEntry: Codable, Hashable, Identifiable {
    /// Txid of the paused incoming payment (hex) — unique per pause.
    var txidHex: String
    var sender: String
    var receiver: String
    var amount: UInt64
    var scarCount: UInt32
    var passcode: UInt32
    var receivedAt: Date

    var id: String { txidHex }

    init(row: ScarConsentRow) {
        self.txidHex = row.txidHex
        self.sender = row.sender
        self.receiver = row.receiver
        self.amount = row.amount
        self.scarCount = row.scarCount
        self.passcode = row.passcode
        self.receivedAt = Date()
    }
}

/// One permanent Activity-log record of a consent-gated payment this
/// device took part in — either side. Written once, never removed:
/// the Activity view keys off it to label the row ("scarred send,
/// completed with passcode" / "you consented via passcode") long
/// after the active consent card is gone.
struct ConsentLedgerRecord: Codable, Hashable {
    /// Txid of the consent-gated payment (matches the history row's txid
    /// on both sides — the receiver's redeem row carries the send txid).
    var txidHex: String
    /// "sender" (completed a paused send with the receiver's passcode)
    /// or "receiver" (was notified; sharing the passcode was consent).
    var role: String
    var passcode: UInt32
    var counterparty: String
    var at: Date
}

/// On-disk shape: active cards + the permanent ledger.
private struct ScarConsentFile: Codable {
    var active: [ScarConsentEntry]
    var ledger: [ConsentLedgerRecord]
}

@MainActor
final class ScarConsentStore: ObservableObject {
    @Published private(set) var entries: [ScarConsentEntry] = []
    /// Permanent per-txid records for Activity decoration. Append-only.
    @Published private(set) var ledger: [ConsentLedgerRecord] = []

    /// Mirror of ContactsStore.loadFailed: when the file existed but
    /// couldn't decode, refuse to overwrite it (a save from an empty
    /// in-memory list would silently destroy pending passcodes).
    private(set) var loadFailed: Bool = false

    private let fileURL: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("Axiom")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scar_consents.json")
    }()

    init() {
        load()
    }

    /// Fold freshly-consumed notifications in, deduplicated by txid
    /// (a re-gated send after a stale pause produces a NEW txid, so
    /// txid identity is exact). Returns true if anything new landed.
    @discardableResult
    func ingest(_ rows: [ScarConsentRow]) -> Bool {
        var added = false
        for row in rows where !entries.contains(where: { $0.txidHex == row.txidHex }) {
            entries.append(ScarConsentEntry(row: row))
            // Permanent receiver-side record from the moment of
            // notification: if the user later consents, the redeem row
            // for this txid gets the "you consented via passcode"
            // Activity label; if they decline, the txid never appears
            // in history and the record simply never matches.
            if !ledger.contains(where: { $0.txidHex == row.txidHex && $0.role == "receiver" }) {
                ledger.append(ConsentLedgerRecord(
                    txidHex: row.txidHex,
                    role: "receiver",
                    passcode: row.passcode,
                    counterparty: row.sender,
                    at: Date()
                ))
            }
            added = true
        }
        if added { save() }
        return added
    }

    /// Sender side: a paused send just completed with the receiver's
    /// passcode. Permanent record for the Activity label.
    func recordSenderCompletion(txidHex: String, passcode: UInt32, counterparty: String) {
        guard !ledger.contains(where: { $0.txidHex == txidHex && $0.role == "sender" }) else { return }
        ledger.append(ConsentLedgerRecord(
            txidHex: txidHex,
            role: "sender",
            passcode: passcode,
            counterparty: counterparty,
            at: Date()
        ))
        save()
    }

    /// Ledger lookup for Activity decoration (case-insensitive txid).
    func consentRecord(txidHex: String) -> ConsentLedgerRecord? {
        let needle = txidHex.lowercased()
        return ledger.first { $0.txidHex.lowercased() == needle }
    }

    /// The user chose to ignore (= decline) or is simply done with the
    /// card. Local removal only — declining a scar-consent is defined
    /// as doing nothing on the network.
    func dismiss(txidHex: String) {
        entries.removeAll { $0.txidHex == txidHex }
        save()
    }

    /// Entries addressed to any of the given wallet addresses (the
    /// active wallet's tier addresses). Other wallets' notifications
    /// stay held for when the user switches to that wallet.
    func entries(for addresses: [String]) -> [ScarConsentEntry] {
        entries
            .filter { e in addresses.contains(where: { $0 == e.receiver }) }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    private func load() {
        let path = fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            loadFailed = false
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            if let file = try? JSONDecoder().decode(ScarConsentFile.self, from: data) {
                entries = file.active
                ledger = file.ledger
            } else {
                // One-time shape migration: the first shipped format was a
                // bare [ScarConsentEntry] with no ledger. Backfill receiver
                // ledger records from the active cards — they ARE receiver
                // notifications, and the new invariant is "receiver role
                // recorded at ingest".
                entries = try JSONDecoder().decode([ScarConsentEntry].self, from: data)
                ledger = entries.map { e in
                    ConsentLedgerRecord(
                        txidHex: e.txidHex,
                        role: "receiver",
                        passcode: e.passcode,
                        counterparty: e.sender,
                        at: e.receivedAt
                    )
                }
            }
            loadFailed = false
        } catch {
            NSLog("[ScarConsentStore] load failed (mutations blocked): \(error)")
            loadFailed = true
        }
    }

    private func save() {
        guard !loadFailed else {
            NSLog("[ScarConsentStore] save refused — a previous load failed; not overwriting on-disk state")
            return
        }
        do {
            let data = try JSONEncoder().encode(ScarConsentFile(active: entries, ledger: ledger))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[ScarConsentStore] save failed: \(error)")
        }
    }
}

// =================================================================
// ScarConsentInboxCard — one incoming-payment consent request.
//
// The decision surface: amount + sender + scar count, the passcode
// rendered large and copyable, and the two documented outcomes —
// share the passcode out-of-band (ACCEPT) or ignore (DECLINE). There
// is deliberately NO network-touching accept button: the hand-off IS
// the consent.
// =================================================================

struct ScarConsentInboxCard: View {
    let entry: ScarConsentEntry
    var onDismiss: () -> Void = {}

    @State private var copied: Bool = false

    private var passcodeDisplay: String {
        String(format: "%06u", entry.passcode)
    }

    private var explanation: String {
        let links = entry.scarCount == 1
            ? "1 unverified link"
            : "\(entry.scarCount) unverified links"
        return "Incoming payment of \(formatAxcOnly(entry.amount)) from "
            + "\(entry.sender) has \(links) in its history, so it is paused "
            + "until you consent. Accept: share the passcode below with the "
            + "sender (out-of-band — telling them IS the consent; your wallet "
            + "will inherit the unverified links when the payment completes). "
            + "Decline: do nothing and ignore this — nothing happens, no funds "
            + "move either way."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "hand.raised.circle.fill")
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Text("INCOMING PAYMENT — YOUR CONSENT REQUIRED")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(DesignTokens.Typography.chip)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Remove this request. Declining is doing nothing — the paused payment simply never completes.")
            }

            Text(explanation)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(passcodeDisplay)
                    .font(Font.system(size: 28, weight: .semibold, design: .monospaced))
                    .tracking(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.vertical, DesignTokens.Spacing.xxs)
                    .background(DesignTokens.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
                Button(copied ? "Copied" : "Copy passcode") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(passcodeDisplay, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.md, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.md))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusScarredBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }
}
