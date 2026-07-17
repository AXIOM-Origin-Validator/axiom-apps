import Foundation
import SwiftUI
import AxiomSdk

// =================================================================
// MessageStore — the central observable store for every payment
// message tracked by the UNCLE SAM operator. Replaces the prior
// mock-arrays scattered across views with a single source of truth
// for the queue tabs, dashboard counters, audit detail, and
// maker-checker workflow.
//
// The store is in-memory only for the design preview; the structure
// (immutable record + appended lifecycle events) is what a real
// UNCLE backend would mirror in its audit DB (per
// docs/AXIOM_DESIGN_UNCLE.md §9).
// =================================================================

/// Canonical lifecycle state of an outbound (or inbound) message.
/// Matches the banker-familiar SWIFT operator vocabulary:
///
///   draft                 — operator typing; not yet submitted
///   pendingAuthorization  — submitted by maker; awaiting checker
///   authorized            — checker approved; queued for send
///   sent                  — handed to UNCLE gateway
///   ack                   — gateway ACK received
///   nack                  — gateway NACK / rejection received
///   rejected              — checker rejected during authorization
///   received              — inbound (used for Inbox-side rows)
enum MessageStatus: String, CaseIterable, Codable {
    case draft
    case pendingAuthorization
    case authorized
    case sent
    case ack
    case nack
    case rejected
    case received
}

/// Direction of a message — outbound (we sent it) or inbound
/// (we received it). The queue's Inbox tab shows .inbound;
/// Outbox + Pending Authorization show .outbound.
enum MessageDirection: String, Codable {
    case outbound
    case inbound
}

/// Which SWIFT-aligned format the envelope is in. Mirrors the
/// `WireFormat` enum used by the composer — duplicated here so
/// the store doesn't depend on view code.
enum MessageFormat: String, Codable {
    case pacs008
    case mt103

    var display: String {
        switch self {
        case .pacs008: return "pacs.008"
        case .mt103:   return "MT103"
        }
    }
}

/// One lifecycle event — every state change records who, when,
/// what. This is the substance of the audit trail the regulator
/// queries. Append-only; never mutated.
struct LifecycleEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let actor: String
    let kind: Kind
    let note: String?

    enum Kind: String, Codable {
        case created
        case submittedForAuthorization
        case sanctionsScreened          // OFAC pre-flight verdict
        case authorized
        case rejected
        case sentToGateway
        case ackReceived
        case nackReceived
        case axiomWitnessQuorum         // k-of-n validator signatures collected
        case nablaConfirmed             // mesh-level txid notarisation
        case received                   // inbound — first appearance from gateway
    }

    init(actor: String, kind: Kind, note: String? = nil, at: Date = Date()) {
        self.id = UUID()
        self.timestamp = at
        self.actor = actor
        self.kind = kind
        self.note = note
    }
}

/// A payment message tracked by the operator console. Holds the
/// SWIFT-aligned envelope (raw body) plus the metadata the queue
/// tables, dashboard counters, and audit detail consume.
struct MessageRecord: Identifiable, Codable {
    let id: UUID

    // ── Identification ───────────────────────────────────────
    /// SWIFT Field 20 / pacs.008 EndToEndId — the human-visible
    /// reference. 16 chars for MT103, up to 35 for pacs.008.
    let reference: String
    let format: MessageFormat
    let direction: MessageDirection

    // ── Payment fields (mirrored from WireDraft for queue display) ──
    let settlementCurrency: String
    let settlementAmount: String
    let orderingCustomerName: String
    let beneficiaryName: String
    let beneficiaryBIC: String
    let valueDate: Date

    // ── Envelope body (the rendered SWIFT-aligned text) ──────
    /// Full envelope as text — MT103 FIN blocks or pacs.008 XML.
    /// Stored verbatim so the audit-trail view can show exactly
    /// what was authorized + sent.
    let envelopeBody: String

    /// Optional inline reconciliation summary — the
    /// "Instructed ... − charges ... × FX ... → Settled ..."
    /// line tying :33B:/:71F:/:71G:/:36: to :32A:. Stored at
    /// submit time so the Detail view can show it without
    /// re-parsing the envelope body.
    let reconciliationLine: String?
    /// True when the reconciliation balances at submit time.
    /// Used to colour the line on the Detail view.
    let reconciliationBalanced: Bool

    // ── AXIOM anchor (the rail side) ───────────────────────────
    //
    // These are the AXIOM-native equivalents to the SWIFT
    // tracking metadata banks expect (UETR, settlement
    // confirmation). Populated post-submit as the AXIOM rail
    // produces them; the Detail view shows them in a panel
    // parallel to the SWIFT envelope.

    /// AXIOM transaction id — hex BLAKE3 hash of the signed
    /// transaction. The wallet's equivalent of UETR. Populated
    /// after a real `wallet.send()` returns its `SendResultRow`.
    private(set) var axiomTxid: String?
    /// Number of validator witness signatures collected
    /// (typical k=3, institutional k=5).
    private(set) var witnessCount: Int
    /// Required quorum (k). Pulled from the receiver tier
    /// address; institutional wallets are k=5.
    let requiredK: Int
    /// FACT chain depth after this TX lands — append-only proof
    /// chain length, audit-grade.
    private(set) var factChainDepth: Int
    /// True when Nabla has notarized the txid (mesh-level
    /// confirmation). Set when `SendResultRow.registration ==
    /// "confirmed"`.
    private(set) var nablaConfirmed: Bool

    // ── Sanctions / OFAC pre-flight ────────────────────────────
    /// Result of the bank's screening engine on the ordering
    /// customer, beneficiary, and BICs against OFAC SDN + UN +
    /// EU + UK HMT sanctions lists. Real implementations call
    /// the bank's screening service (Accuity / Bridger /
    /// FircoSoft); UNCLE SAM uses a stub for the demo.
    let sanctionsResult: SanctionsResult

    // ── Lifecycle ────────────────────────────────────────────
    /// Current state. Updated by store mutators; never set directly.
    private(set) var status: MessageStatus
    /// Append-only event log. Each state transition adds one
    /// entry; the latest entry's actor + timestamp is what the
    /// queue tables show as "last touched by".
    private(set) var lifecycle: [LifecycleEvent]

    /// Operator who created the message (maker). Used to enforce
    /// the maker-checker rule: a checker cannot authorize their
    /// own message.
    let createdBy: String
    /// Operator who authorized (checker). nil until authorized.
    private(set) var authorizedBy: String?

    init(reference: String,
         format: MessageFormat,
         direction: MessageDirection,
         settlementCurrency: String,
         settlementAmount: String,
         orderingCustomerName: String,
         beneficiaryName: String,
         beneficiaryBIC: String,
         valueDate: Date,
         envelopeBody: String,
         reconciliationLine: String? = nil,
         reconciliationBalanced: Bool = true,
         axiomTxid: String? = nil,
         witnessCount: Int = 0,
         requiredK: Int = 3,
         factChainDepth: Int = 0,
         nablaConfirmed: Bool = false,
         sanctionsResult: SanctionsResult = .clear,
         status: MessageStatus,
         createdBy: String,
         initialLifecycle: [LifecycleEvent] = [])
    {
        self.id = UUID()
        self.reference = reference
        self.format = format
        self.direction = direction
        self.settlementCurrency = settlementCurrency
        self.settlementAmount = settlementAmount
        self.orderingCustomerName = orderingCustomerName
        self.beneficiaryName = beneficiaryName
        self.beneficiaryBIC = beneficiaryBIC
        self.valueDate = valueDate
        self.envelopeBody = envelopeBody
        self.reconciliationLine = reconciliationLine
        self.reconciliationBalanced = reconciliationBalanced
        self.axiomTxid = axiomTxid
        self.witnessCount = witnessCount
        self.requiredK = requiredK
        self.factChainDepth = factChainDepth
        self.nablaConfirmed = nablaConfirmed
        self.sanctionsResult = sanctionsResult
        self.status = status
        self.lifecycle = initialLifecycle
        self.createdBy = createdBy
        self.authorizedBy = nil
    }

    fileprivate mutating func setNablaConfirmed(_ v: Bool) {
        self.nablaConfirmed = v
    }

    fileprivate mutating func appendLifecycle(_ evt: LifecycleEvent) {
        self.lifecycle.append(evt)
    }

    /// Stamp the AXIOM-side anchor onto the record after a real
    /// `wallet.send()` returns. Called by MessageStore after the
    /// SDK reports witness-quorum completion.
    fileprivate mutating func setAxiomAnchor(txid: String, witnesses: Int,
                                              factChainDepth: Int,
                                              nablaConfirmed: Bool) {
        self.axiomTxid = txid
        self.witnessCount = witnesses
        self.factChainDepth = factChainDepth
        self.nablaConfirmed = nablaConfirmed
    }

    /// Date of the last lifecycle event, falling back to the
    /// value date if the lifecycle is somehow empty (shouldn't be).
    var lastTouched: Date {
        lifecycle.last?.timestamp ?? valueDate
    }

    /// Latest event actor — used in the queue's "Last actor" column.
    var lastActor: String {
        lifecycle.last?.actor ?? createdBy
    }

    fileprivate mutating func transition(to status: MessageStatus,
                                         event: LifecycleEvent) {
        self.status = status
        self.lifecycle.append(event)
        if case .authorized = event.kind {
            self.authorizedBy = event.actor
        }
    }
}

/// Observable mock-backed store. In a real deployment this would
/// be backed by the UNCLE audit DB; here it holds an in-memory
/// `[MessageRecord]` seeded with representative rows so the queue
/// tabs + dashboard counters demo without a backend.
@MainActor
final class MessageStore: ObservableObject {

    @Published private(set) var messages: [MessageRecord] = []

    /// Weak reference to the institution session — gives the
    /// store access to the open AxiomWallet on authorize. Bound
    /// once at app launch from UNCLESamApp.body.
    weak var session: InstitutionSession?

    /// Weak reference to NotifyChequesSender — bound at App
    /// init. After a successful wallet.send the store fires a
    /// NotifyCheques to the matched counterparty so the receiver
    /// bank knows to PullCheques. Best-effort: when the
    /// counterparty isn't fully configured for the peer wire
    /// (missing pgpPublicKey / operatorEd25519PubkeyHex / uncle
    /// peer endpoint) we log + skip without failing the send.
    weak var notifyChequesSender: NotifyChequesSender?

    /// Gateway connection state — drives the bottom Connection
    /// Health strip. In-memory only; toggleable from Settings for
    /// the demo.
    @Published var gatewayState: GatewayState = .connected
    @Published var queueDepth: Int = 0
    @Published var lastHeartbeat: Date = Date()

    enum GatewayState: String {
        case connected
        case reconnecting
        case disconnected

        var label: String {
            switch self {
            case .connected:    return "Connected"
            case .reconnecting: return "Reconnecting"
            case .disconnected: return "Disconnected"
            }
        }
    }

    init() {
        seed()
        recomputeQueueDepth()
    }

    // ── Lifecycle mutators ────────────────────────────────────

    /// Submit a freshly-composed message for checker authorization.
    /// Called from the Wire (Send) composer. Returns the new id so
    /// the composer can navigate to the queue and highlight it.
    @discardableResult
    func submitForAuthorization(
        reference: String,
        format: MessageFormat,
        settlementCurrency: String,
        settlementAmount: String,
        orderingCustomerName: String,
        beneficiaryName: String,
        beneficiaryBIC: String,
        valueDate: Date,
        envelopeBody: String,
        reconciliationLine: String? = nil,
        reconciliationBalanced: Bool = true,
        maker: String
    ) -> UUID {
        // Pre-flight sanctions / OFAC screen — runs at submit, the
        // result rides with the record so checker + auditor see it.
        let scrn = SanctionsScreener.screen(
            orderingName: orderingCustomerName,
            beneficiaryName: beneficiaryName,
            beneficiaryBIC: beneficiaryBIC
        )

        let created = LifecycleEvent(actor: maker, kind: .created)
        let submitted = LifecycleEvent(actor: maker, kind: .submittedForAuthorization)
        let screened = LifecycleEvent(
            actor: "sanctions-screener",
            kind: .sanctionsScreened,
            note: "OFAC SDN + UN + EU + UK HMT screening result: \(scrn.rawValue). \(scrn.rationale)"
        )

        // Mock AXIOM anchor — deterministic from reference so the
        // demo is reproducible. Real values come from the SDK +
        // validator response post-broadcast.
        let mockTxid = MessageStore.deterministicTxid(seed: reference)

        let rec = MessageRecord(
            reference: reference,
            format: format,
            direction: .outbound,
            settlementCurrency: settlementCurrency,
            settlementAmount: settlementAmount,
            orderingCustomerName: orderingCustomerName,
            beneficiaryName: beneficiaryName,
            beneficiaryBIC: beneficiaryBIC,
            valueDate: valueDate,
            envelopeBody: envelopeBody,
            reconciliationLine: reconciliationLine,
            reconciliationBalanced: reconciliationBalanced,
            axiomTxid: mockTxid,
            witnessCount: 3,
            requiredK: 3,
            factChainDepth: 8,
            nablaConfirmed: false,
            sanctionsResult: scrn,
            status: .pendingAuthorization,
            createdBy: maker,
            initialLifecycle: [created, submitted, screened]
        )
        messages.insert(rec, at: 0)
        recomputeQueueDepth()
        return rec.id
    }

    /// Checker approves a pending message. Maker-checker rule
    /// enforced in the UI; the store re-enforces it defensively.
    /// Transitions the record to `.authorized` synchronously, then
    /// kicks off a real `wallet.send()` on a background thread.
    /// The send populates the real AXIOM anchor (txid, balance,
    /// registration status) and lands the record at .ack or .nack
    /// depending on the SDK result.
    func authorize(_ id: UUID, by checker: String) -> Result<Void, AuthorizeError> {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            return .failure(.notFound)
        }
        var rec = messages[idx]
        guard rec.status == .pendingAuthorization else {
            return .failure(.wrongState(rec.status))
        }
        guard rec.createdBy != checker else {
            return .failure(.selfAuthorization)
        }
        rec.transition(to: .authorized,
                       event: LifecycleEvent(actor: checker, kind: .authorized))
        messages[idx] = rec

        // Dispatch wallet.send() on a background thread — it
        // blocks for up to 60s on the witness round and would
        // otherwise stall the main thread / @MainActor queue.
        dispatchToAxiom(id: id)

        recomputeQueueDepth()
        return .success(())
    }

    /// Run wallet.send() on a background thread for the just-
    /// authorized message. Updates the record in place with the
    /// txid + balance, or transitions to .nack on failure.
    ///
    /// Computes the AXC amount from the bilateral FX rate stored
    /// on the matched Counterparty:
    ///
    ///   axc_atoms = round(display_amount / counterparty.fxRate * 1e10)
    ///
    /// (1 AXC = 10^10 atoms per the SDK's canonical scale.)
    private func dispatchToAxiom(id: UUID) {
        guard let rec = messages.first(where: { $0.id == id }) else { return }
        guard let wallet = session?.wallet else {
            return
        }
        // Find the counterparty by BIC. Without one we don't have
        // a bilateral FX rate, so we can't compute the AXC amount.
        guard let cp = CounterpartyStore.by(bic: rec.beneficiaryBIC) else {
            failSend(id: id, reason: "Beneficiary BIC \(rec.beneficiaryBIC) has no bilateral arrangement.")
            return
        }
        guard !cp.axiomTierAddress.isEmpty,
              !cp.axiomTierAddress.hasPrefix("(") else {
            failSend(id: id, reason: "Counterparty \(cp.name) has no AXIOM tier address configured. Paste the bank's k=5 address in Counterparty settings.")
            return
        }
        // Parse the display amount (comma OR period decimal — SWIFT
        // wire uses comma; operators sometimes type period).
        let raw = rec.settlementAmount
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let display = Double(raw), display > 0 else {
            failSend(id: id, reason: "Settlement amount \(rec.settlementAmount) is not a valid number.")
            return
        }
        // Bilateral FX: 1 AXC = fxRate counter-ccy. So:
        //   axc = display_counter / fxRate
        // 1 AXC = 10^10 atoms.
        let axcUnits = display / cp.fxRate
        let atoms = UInt64((axcUnits * 1e10).rounded())
        let toAddr = cp.axiomTierAddress
        let reference = rec.reference
        let walletEmail = wallet.email()

        Task { @MainActor in
            self.lastHeartbeat = Date()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                // sendWithProof retains a PQ Send Proof (VBC chain kept) so the
                // bank can export a Core-verifiable certificate of this payment —
                // the cryptographic equivalent of a SWIFT TT slip.
                let r = try wallet.sendWithProof(
                    to: toAddr,
                    amountAtoms: atoms,
                    reference: reference,
                    message: nil,
                    deliveryEmailOverride: nil
                )
                DispatchQueue.main.async {
                    self?.completeSend(id: id, result: r, atoms: atoms,
                                       walletEmail: walletEmail)
                }
            } catch {
                let msg = "\(error)"
                DispatchQueue.main.async {
                    self?.failSend(id: id, reason: msg)
                }
            }
        }
    }

    /// Apply a successful wallet.send result to the record.
    private func completeSend(id: UUID, result: SendResultRow,
                              atoms: UInt64, walletEmail: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        var rec = messages[idx]
        // Stamp real txid + final balance into the record.
        rec.setAxiomAnchor(txid: result.txid,
                           witnesses: Int(rec.requiredK),
                           factChainDepth: rec.factChainDepth + 1,
                           nablaConfirmed: result.registration == "confirmed")
        // .sent (gateway hand-off) → .ack on confirmed
        // registration. "pending" registration means the witness
        // round succeeded but Nabla register hasn't completed →
        // mark as sent, let the caller heal later. "skipped"
        // means no Nabla addresses → still sent.
        rec.transition(to: .sent,
                       event: LifecycleEvent(actor: "AXIOM-SDK",
                                             kind: .sentToGateway,
                                             note: "Witness round complete: \(result.chequesWritten) cheque files, txid \(result.txid). Registration: \(result.registration)."))
        rec.appendLifecycle(LifecycleEvent(
            actor: "AXIOM-validators",
            kind: .axiomWitnessQuorum,
            note: "k=\(rec.requiredK) witness signatures collected; FACT chain advanced."
        ))
        if result.registration == "confirmed" {
            rec.transition(to: .ack,
                           event: LifecycleEvent(actor: "Nabla-mesh",
                                                 kind: .nablaConfirmed,
                                                 note: "Txid notarized across Nabla mesh; cryptographic finality achieved."))
        }
        messages[idx] = rec
        session?.refreshBalance()
        lastHeartbeat = Date()
        NSLog("%@", "[UNCLESam] send ok — txid \(result.txid), \(atoms) atoms, reg=\(result.registration)")
        // Bilateral peer notification — tell the receiver bank
        // (counterparty's UNCLE SAM) about the cheque so they can
        // PullCheques against the validator UNCLEs. Best-effort:
        // we don't fail the send if the counterparty isn't fully
        // configured for the peer wire yet (e.g. demo counterparty
        // without pgpPublicKey set).
        Task { @MainActor [weak self] in
            await self?.fireNotifyChequesIfConfigured(
                id: id, txid: result.txid, atoms: atoms)
        }
    }

    /// After a successful wallet.send, attempt to NotifyCheques the
    /// counterparty. Skips quietly when not fully configured (each
    /// gating field is the legitimate "this counterparty isn't on
    /// UNCLE yet" case bank operators onboard incrementally).
    /// Internal (not `private`) so the smoke harness can drive it
    /// directly with a synthetic record.
    func fireNotifyChequesIfConfigured(id: UUID,
                                        txid: String,
                                        atoms: UInt64) async {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        let rec = messages[idx]
        guard let sender = notifyChequesSender else {
            NSLog("[unclesam.notify-outbound] no sender bound — skip")
            return
        }
        // Counterparty resolution: BIC primary, fall back to
        // self-counterparty's BIC for loopback/self-send.
        let cp: Counterparty?
        if let c = CounterpartyStore.by(bic: rec.beneficiaryBIC) {
            cp = c
        } else if let s = CounterpartyStore.selfEntry,
                  s.bic == rec.beneficiaryBIC {
            cp = s
        } else {
            cp = nil
        }
        guard let cp = cp else {
            recordNotifyChequesSkip(id: id,
                reason: "counterparty for BIC \(rec.beneficiaryBIC) not found")
            return
        }
        guard !cp.pgpPublicKey.isEmpty else {
            recordNotifyChequesSkip(id: id,
                reason: "counterparty \(cp.name) has no PGP public key configured — onboard via bilateral arrangement before NotifyCheques fires")
            return
        }
        // cp.peerEndpoint holds the peer UNCLE SAM endpoint (host:port).
        // Empty → not yet configured for peer wire.
        guard !cp.peerEndpoint.isEmpty else {
            recordNotifyChequesSkip(id: id,
                reason: "counterparty \(cp.name) has no peer UNCLE SAM endpoint configured")
            return
        }
        // Ed25519 secret for signing canonical bytes.
        let edPath = UserDefaults.standard.string(
            forKey: "uncle.sam.self.ed25519_secret_path") ?? ""
        guard !edPath.isEmpty,
              let edSecret = try? Data(contentsOf: URL(fileURLWithPath: edPath))
        else {
            recordNotifyChequesSkip(id: id,
                reason: "self ed25519 secret not configured (Settings → Self identity)")
            return
        }
        // Expected pieces: every validator that witnessed gets a
        // (validator_id, uncle_endpoint) pair. We don't have the
        // validator IDs from wallet.send's SendResultRow today;
        // until that FFI surface lands, use the configured gateway
        // endpoint as a single placeholder pointing at the bank's
        // primary validator UNCLE. Receiver's auto-pull dispatches
        // against this single endpoint — Linux UNCLE serves all
        // matching rows by ACL filter anyway.
        let gatewayEndpoint = UserDefaults.standard.string(
            forKey: "uncle.sam.gateway.endpoint") ?? ""
        let expectedPieces: [(validatorId: Data, uncleEndpoint: String)]
        if !gatewayEndpoint.isEmpty {
            expectedPieces = [(
                validatorId: Data(count: 32),  // zeros — UNCLE doesn't validate
                uncleEndpoint: gatewayEndpoint
            )]
        } else {
            expectedPieces = []
        }
        // wallet.send returns txid as hex string. Decode to 32 raw
        // bytes for cheque_bundle_id. If decode fails, fall back to
        // a random ID with a warn log — keeps the demo unblocked
        // when txid shape is unexpected.
        var bundleIdBytes: Data
        if let decoded = Self.hexToData(txid), decoded.count == 32 {
            bundleIdBytes = decoded
        } else {
            NSLog("[unclesam.notify-outbound] txid \(txid) didn't decode to 32 bytes; falling back to random bundle_id")
            var random = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, &random)
            bundleIdBytes = Data(random)
        }
        // Sender wallet — best-effort lookup of the active account's
        // tier address. Falls back to a synthetic string when no
        // session is bound (smoke / headless paths).
        let senderWalletId = session?.activeAccount?.tierAddress ?? rec.orderingCustomerName
        let receiverWalletId = cp.axiomTierAddress
        NSLog("[unclesam.notify-outbound] firing → \(cp.peerEndpoint) for txid \(txid.prefix(16))…")
        await sender.send(
            senderWalletId: senderWalletId,
            receiverWalletId: receiverWalletId,
            amountAtoms: atoms,
            swiftReference: rec.reference,
            expectedPieces: expectedPieces,
            ed25519SecretBytes: edSecret,
            recipientPubkeyArmored: cp.pgpPublicKey,
            targetEndpoint: cp.peerEndpoint)
        // Re-fetch the record (other transitions may have
        // happened) and record the outcome in lifecycle.
        guard let idx2 = messages.firstIndex(where: { $0.id == id }) else { return }
        var rec2 = messages[idx2]
        if let err = sender.lastError {
            rec2.appendLifecycle(LifecycleEvent(
                actor: "unclesam-notify",
                kind: .nackReceived,
                note: "NotifyCheques to \(cp.name) @ \(cp.peerEndpoint) FAILED: \(err). Receiver may not auto-pull — they fall back to manual PullCheques on their own schedule, so the cheque remains discoverable."
            ))
            NSLog("[unclesam.notify-outbound] FAILED: \(err)")
        } else if let ack = sender.lastAck {
            switch ack.status {
            case .accepted:
                rec2.appendLifecycle(LifecycleEvent(
                    actor: "unclesam-notify",
                    kind: .ackReceived,
                    note: "NotifyCheques accepted by \(cp.name) — bundle_id \(bundleIdBytes.prefix(8).map{String(format:"%02x",$0)}.joined())…. Receiver-side auto-pull will fetch the cheque pieces from the validator UNCLE."
                ))
                NSLog("[unclesam.notify-outbound] ACCEPTED by \(cp.name)")
            case .rejected:
                rec2.appendLifecycle(LifecycleEvent(
                    actor: "unclesam-notify",
                    kind: .nackReceived,
                    note: "NotifyCheques REJECTED by \(cp.name): \(ack.reason ?? "(no reason)"). Receiver explicitly refused — investigate via the bilateral ops channel."
                ))
                NSLog("[unclesam.notify-outbound] REJECTED: \(ack.reason ?? "")")
            }
        }
        messages[idx2] = rec2
    }

    /// Smoke-harness hook: inject a synthetic MessageRecord with
    /// `.sent` status pointing at `beneficiaryBIC`, then drive
    /// fireNotifyChequesIfConfigured against it. The synthetic
    /// record is identifiable in the messages array (its
    /// `reference` is the smoke-supplied label) so the harness
    /// can verify lifecycle events.
    func smokeCompleteSend(reference: String,
                            beneficiaryBIC: String,
                            txidHex: String,
                            atoms: UInt64) async -> UUID {
        let synthetic = MessageRecord(
            reference: reference,
            format: .pacs008,
            direction: .outbound,
            settlementCurrency: "AXC",
            settlementAmount: String(format: "%.10f",
                                      Double(atoms) / 1e10),
            orderingCustomerName: "smoke-sender@selfsend.example",
            beneficiaryName: "smoke-receiver@selfsend.example",
            beneficiaryBIC: beneficiaryBIC,
            valueDate: Date(),
            envelopeBody: "(smoke-driven synthetic outbound)",
            axiomTxid: txidHex,
            witnessCount: 3,
            requiredK: 3,
            factChainDepth: 1,
            nablaConfirmed: true,
            sanctionsResult: .clear,
            status: .sent,
            createdBy: "smoke",
            initialLifecycle: [
                LifecycleEvent(actor: "smoke", kind: .created),
                LifecycleEvent(actor: "smoke", kind: .sentToGateway,
                                note: "(synthetic — bypassed wallet.send)")
            ]
        )
        messages.insert(synthetic, at: 0)
        await fireNotifyChequesIfConfigured(
            id: synthetic.id, txid: txidHex, atoms: atoms)
        return synthetic.id
    }

    private func recordNotifyChequesSkip(id: UUID, reason: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        var rec = messages[idx]
        rec.appendLifecycle(LifecycleEvent(
            actor: "unclesam-notify",
            kind: .sentToGateway,
            note: "NotifyCheques peer-wire fire SKIPPED — \(reason). The cheque is still on-chain and discoverable; receiver bank can PullCheques on their own schedule."
        ))
        messages[idx] = rec
        NSLog("[unclesam.notify-outbound] SKIPPED: \(reason)")
    }

    /// Convert a hex string to bytes. Tolerates upper/lower case,
    /// rejects non-hex characters and odd-length strings.
    private static func hexToData(_ hex: String) -> Data? {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
                         .replacingOccurrences(of: ":", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var out = Data()
        out.reserveCapacity(cleaned.count / 2)
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let next = cleaned.index(i, offsetBy: 2)
            guard let b = UInt8(cleaned[i..<next], radix: 16) else { return nil }
            out.append(b)
            i = next
        }
        return out
    }

    /// Apply a failed wallet.send to the record.
    private func failSend(id: UUID, reason: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        var rec = messages[idx]
        rec.transition(to: .nack,
                       event: LifecycleEvent(actor: "AXIOM-SDK",
                                             kind: .nackReceived,
                                             note: reason))
        messages[idx] = rec
        lastHeartbeat = Date()
        NSLog("%@", "[UNCLESam] send failed — \(reason)")
    }

    /// Checker rejects a pending message. Optional rejection note
    /// is shown in the audit trail.
    func reject(_ id: UUID, by checker: String, note: String?) -> Result<Void, AuthorizeError> {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            return .failure(.notFound)
        }
        var rec = messages[idx]
        guard rec.status == .pendingAuthorization else {
            return .failure(.wrongState(rec.status))
        }
        guard rec.createdBy != checker else {
            return .failure(.selfAuthorization)
        }
        rec.transition(to: .rejected,
                       event: LifecycleEvent(actor: checker, kind: .rejected, note: note))
        messages[idx] = rec
        recomputeQueueDepth()
        return .success(())
    }

    enum AuthorizeError: Error {
        case notFound
        case wrongState(MessageStatus)
        case selfAuthorization
    }

    // (simulateSendAndAck removed — replaced by real wallet.send
    // path in dispatchToAxiom + completeSend / failSend above.)

    private func recomputeQueueDepth() {
        queueDepth = messages.filter {
            $0.status == .pendingAuthorization || $0.status == .authorized
        }.count
    }

    /// Deterministic hex string from any input — used for the
    /// demo's mock AXIOM txid so the same reference always
    /// produces the same txid (reproducible demo).
    private static func deterministicTxid(seed: String) -> String {
        let h1 = abs(seed.hash)
        let h2 = abs((seed + "salt-axiom").hash)
        let h3 = abs((seed + "salt-fact").hash)
        let h4 = abs((seed + "salt-nabla").hash)
        return String(format: "%016x%016x%016x%016x",
                      UInt64(h1), UInt64(h2), UInt64(h3), UInt64(h4))
    }

    // ── Query helpers (used by the queue tabs) ────────────────

    func outbound() -> [MessageRecord] {
        messages.filter { $0.direction == .outbound }
    }
    func inbound() -> [MessageRecord] {
        messages.filter { $0.direction == .inbound }
    }

    // ── Receive-side credit posting (Bucket 5(d)) ────────────────

    /// Total atoms pending credit across all inbound .received
    /// records — every cheque pulled from validator UNCLE that
    /// hasn't been explicitly posted to a bank account yet. This
    /// is the number the treasurer sees when answering "how much
    /// have we received but not yet credited?"
    func pendingCreditAtoms() -> UInt64 {
        var total: UInt64 = 0
        for m in messages
            where m.direction == .inbound && m.status == .received {
            let s = m.settlementAmount.replacingOccurrences(of: ",", with: "")
            if let axc = Double(s) {
                total &+= UInt64(axc * 1e10)
            }
        }
        return total
    }

    /// Total atoms pending credit destined for a specific receiver
    /// wallet (e.g. one of the bank's tier addresses). The receiver
    /// match is exact string equality on
    /// `MessageRecord.beneficiaryName` (which holds the cheque's
    /// receiver_wallet on inbound records). Per-account breakdown
    /// for the multi-treasury display in Settings → Accounts.
    func pendingCreditAtoms(forReceiverWallet wallet: String) -> UInt64 {
        var total: UInt64 = 0
        for m in messages
            where m.direction == .inbound
                && m.status == .received
                && m.beneficiaryName == wallet {
            let s = m.settlementAmount.replacingOccurrences(of: ",", with: "")
            if let axc = Double(s) {
                total &+= UInt64(axc * 1e10)
            }
        }
        return total
    }

    /// Post the cheque's credit to the bank's ledger — transitions
    /// the inbound record from `.received` to `.ack`. Real
    /// deployments would also drive the receiver wallet's
    /// `wallet.redeem()` to move the value on-chain; the demo
    /// records the lifecycle event without the SDK call.
    /// Returns false if the record isn't found or isn't in
    /// `.received` (e.g. already posted).
    @discardableResult
    func postCredit(_ id: UUID,
                     toAccount account: String,
                     by actor: String) -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else {
            return false
        }
        var rec = messages[idx]
        guard rec.status == .received, rec.direction == .inbound else {
            return false
        }
        let evt = LifecycleEvent(
            actor: actor,
            kind: .ackReceived,
            note: "Posted credit to \(account) — \(rec.settlementAmount) \(rec.settlementCurrency)"
        )
        rec.transition(to: .ack, event: evt)
        messages[idx] = rec
        return true
    }
    func pendingAuthorization() -> [MessageRecord] {
        messages.filter { $0.status == .pendingAuthorization }
    }
    func record(_ id: UUID) -> MessageRecord? {
        messages.first(where: { $0.id == id })
    }

    // ── Inbound pull-worker integration (Bucket 4) ───────────────

    /// Ingest cheques pulled from a validator UNCLE via
    /// PullCheques. Each new cheque becomes a MessageRecord with
    /// `direction == .inbound` and `status == .received` so it lands
    /// in the Inbox tab. Dedup is by txid hex — re-pulling the
    /// same cheque (e.g. across multiple PullCheques calls before
    /// the bank acks server-side) is idempotent.
    ///
    /// Returns the count of NEW records added (excluding dedup
    /// matches) so the gateway client can surface "n new cheques
    /// ingested" in the UI.
    @discardableResult
    func ingestReceivedCheques(_ cheques: [UncleInboundCheque])
        -> Int
    {
        var added = 0
        for cheque in cheques {
            let txidHex = cheque.txid
                .map { String(format: "%02x", $0) }
                .joined()
            // Dedup — same cheque pulled twice is the expected
            // outcome of re-running PullCheques before UNCLE marks
            // the row served. Don't insert a duplicate.
            if messages.contains(where: { $0.axiomTxid == txidHex }) {
                continue
            }

            // Bucket 5(c) — structural cross-check between the
            // cheque_blob contents and the InboundCheque envelope
            // metadata. Catches a malicious / corrupted UNCLE that
            // serves wrong-metadata rows. Real ed25519 verify of
            // the validator signature is a deeper integration
            // (needs Core FFI helper or full Core port to Swift)
            // and is deferred — the field cross-check below is
            // a real partial-verification step bank forks can
            // upgrade to full crypto verify later.
            let verification = ChequeBlobVerifier.verify(cheque)

            // Amount surface: cheque carries atoms; 1 AXC = 1e10
            // atoms per the SDK canonical scale. Render as both so
            // the operator sees the raw integer and the human-
            // readable AXC value.
            let amountAxc = Double(cheque.amountAtoms) / 1e10
            let verifyTag: String
            if verification.outcome.passed {
                verifyTag = "✓"
            } else if verification.outcome.isInformational {
                verifyTag = "∙"     // skipped, partial — not a failure
            } else {
                verifyTag = "✗"
            }
            let envelopeBody = """
            ───────────────────────────────────────────────
            PullCheques inbound — pulled from validator UNCLE
            ───────────────────────────────────────────────
            txid:                \(txidHex)
            receiver_wallet:     \(cheque.receiverWallet)
            sender_wallet:       \(cheque.senderWallet)
            amount_atoms:        \(cheque.amountAtoms)
            amount_axc:          \(String(format: "%.10f", amountAxc))
            received_at_tick:    \(cheque.receivedAtTick)
            witness_validators:  \(cheque.validatorIds.count) (k=\(cheque.validatorIds.count))
            cheque_blob:         \(cheque.chequeBlob.count) bytes (raw protocol CBOR)
            structural_verify:   \(verifyTag) \(verification.summary)

            cheque_blob is the raw witness-signed protocol cheque.
            The structural cross-check above confirms its CBOR
            contents agree with what UNCLE's envelope claimed
            (txid, sender, receiver, amount) — catching a
            malicious / corrupted UNCLE that serves rows whose
            metadata doesn't match the payload. Full cryptographic
            verification (validator ed25519 signature against the
            cheque commitment) is a follow-on integration that
            requires Core FFI helpers; bank forks upgrade this
            structural check to full crypto verify when shipping
            to production.
            """

            let received = LifecycleEvent(
                actor: "uncle-pull-worker",
                kind: .received,
                note: "Pulled from validator UNCLE. " +
                      "\(cheque.chequeBlob.count)-byte cheque blob; " +
                      "\(cheque.validatorIds.count) witness validators. " +
                      verification.summary
            )

            let rec = MessageRecord(
                reference: "PULL-\(String(txidHex.prefix(12)))",
                format: .pacs008,
                direction: .inbound,
                settlementCurrency: "AXC",
                settlementAmount: String(format: "%.10f", amountAxc),
                orderingCustomerName: cheque.senderWallet,
                beneficiaryName: cheque.receiverWallet,
                beneficiaryBIC: "",
                valueDate: Date(),
                envelopeBody: envelopeBody,
                reconciliationLine: nil,
                reconciliationBalanced: true,
                axiomTxid: txidHex,
                witnessCount: cheque.validatorIds.count,
                // k=5 institutional grade — every cheque UNCLE
                // returns is k=5 by §5 of AXIOM_DESIGN_UNCLE.md;
                // surface it explicitly here even though we don't
                // re-verify the receipt at ingest time.
                requiredK: 5,
                factChainDepth: 0,
                // Pulled from UNCLE means the cheque already lives
                // in the validator's audit-grade DB — Nabla saw
                // the txid by definition. Render the post-confirm
                // anchor immediately rather than waiting on a
                // separate Nabla probe.
                nablaConfirmed: true,
                sanctionsResult: .clear,
                status: .received,
                createdBy: "uncle-pull-worker",
                initialLifecycle: [received]
            )
            messages.insert(rec, at: 0)
            added += 1
        }
        if added > 0 {
            recomputeQueueDepth()
        }
        return added
    }

    // ── Seed data ─────────────────────────────────────────────

    /// Populate with a handful of mock rows covering every status
    /// so each queue tab and the dashboard counters have something
    /// to render in the design preview.
    private func seed() {
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
        let twoDays = Calendar.current.date(byAdding: .day, value: -2, to: today) ?? today

        // ACK'd outbound — completed
        appendSeed(MessageRecord(
            reference: "SM-260527-A1B2C3",
            format: .pacs008,
            direction: .outbound,
            settlementCurrency: "AXC",
            settlementAmount: "125,000.00",
            orderingCustomerName: "ACME CORPORATION LTD",
            beneficiaryName: "BENEFICIARY CO LTD",
            beneficiaryBIC: "RECVBKHKXXX",
            valueDate: yesterday,
            envelopeBody: mockPacs008Body(ref: "SM-260527-A1B2C3"),
            axiomTxid: MessageStore.deterministicTxid(seed: "SM-260527-A1B2C3"),
            witnessCount: 5,
            requiredK: 5,
            factChainDepth: 24,
            nablaConfirmed: true,
            sanctionsResult: .clear,
            status: .ack,
            createdBy: "ops_alice",
            initialLifecycle: [
                LifecycleEvent(actor: "ops_alice", kind: .created,
                               at: yesterday.addingTimeInterval(-3600)),
                LifecycleEvent(actor: "ops_alice", kind: .submittedForAuthorization,
                               at: yesterday.addingTimeInterval(-3500)),
                LifecycleEvent(actor: "ops_bob",   kind: .authorized,
                               at: yesterday.addingTimeInterval(-3200)),
                LifecycleEvent(actor: "UNCLE-gateway", kind: .sentToGateway,
                               at: yesterday.addingTimeInterval(-3180)),
                LifecycleEvent(actor: "UNCLE-gateway", kind: .ackReceived,
                               note: "Receiver bank accepted.",
                               at: yesterday.addingTimeInterval(-3000)),
            ]))

        // Pending authorization — awaiting checker. Includes a
        // demonstrated reconciliation so the Detail view shows
        // the inline "Instructed − charges → Settled" line.
        appendSeed(MessageRecord(
            reference: "SM-260528-D4E5F6",
            format: .pacs008,
            direction: .outbound,
            settlementCurrency: "AXC",
            settlementAmount: "8,375.50",
            orderingCustomerName: "ACME CORPORATION LTD",
            beneficiaryName: "VENDOR SERVICES SARL",
            beneficiaryBIC: "VENDFRPPXXX",
            valueDate: today,
            envelopeBody: mockPacs008Body(ref: "SM-260528-D4E5F6"),
            reconciliationLine: "Instructed 8,400.50 AXC − sender chgs 25.00 AXC → Settled 8,375.50 AXC",
            reconciliationBalanced: true,
            axiomTxid: MessageStore.deterministicTxid(seed: "SM-260528-D4E5F6"),
            witnessCount: 0,
            requiredK: 5,
            factChainDepth: 8,
            nablaConfirmed: false,
            sanctionsResult: .clear,
            status: .pendingAuthorization,
            createdBy: "ops_alice",
            initialLifecycle: [
                LifecycleEvent(actor: "ops_alice", kind: .created,
                               at: today.addingTimeInterval(-540)),
                LifecycleEvent(actor: "ops_alice", kind: .submittedForAuthorization,
                               at: today.addingTimeInterval(-500)),
            ]))

        // NACK — gateway rejected
        appendSeed(MessageRecord(
            reference: "SM-260526-9A8B7C",
            format: .mt103,
            direction: .outbound,
            settlementCurrency: "AXC",
            settlementAmount: "47,200.00",
            orderingCustomerName: "ACME CORPORATION LTD",
            beneficiaryName: "MISCONFIGURED CO",
            beneficiaryBIC: "BADBKXXX000",
            valueDate: twoDays,
            envelopeBody: mockMT103Body(ref: "SM-260526-9A8B7C"),
            axiomTxid: nil,
            witnessCount: 0,
            requiredK: 5,
            factChainDepth: 0,
            nablaConfirmed: false,
            sanctionsResult: .review,
            status: .nack,
            createdBy: "ops_alice",
            initialLifecycle: [
                LifecycleEvent(actor: "ops_alice", kind: .created,
                               at: twoDays.addingTimeInterval(-7200)),
                LifecycleEvent(actor: "ops_alice", kind: .submittedForAuthorization,
                               at: twoDays.addingTimeInterval(-7100)),
                LifecycleEvent(actor: "ops_bob",   kind: .authorized,
                               at: twoDays.addingTimeInterval(-6900)),
                LifecycleEvent(actor: "UNCLE-gateway", kind: .sentToGateway,
                               at: twoDays.addingTimeInterval(-6890)),
                LifecycleEvent(actor: "UNCLE-gateway", kind: .nackReceived,
                               note: "Receiver BIC not in UNCLE counterparty table.",
                               at: twoDays.addingTimeInterval(-6800)),
            ]))

        // Inbound — received from a counterparty
        appendSeed(MessageRecord(
            reference: "PRTNR-260528-XY12",
            format: .pacs008,
            direction: .inbound,
            settlementCurrency: "AXC",
            settlementAmount: "65,000.00",
            orderingCustomerName: "PARTNER FUND LP",
            beneficiaryName: "ACME CORPORATION LTD",
            beneficiaryBIC: "DEMOBKHKXXX",
            valueDate: today,
            envelopeBody: mockPacs008Body(ref: "PRTNR-260528-XY12"),
            axiomTxid: MessageStore.deterministicTxid(seed: "PRTNR-260528-XY12"),
            witnessCount: 5,
            requiredK: 5,
            factChainDepth: 17,
            nablaConfirmed: true,
            sanctionsResult: .clear,
            status: .received,
            createdBy: "UNCLE-gateway",
            initialLifecycle: [
                LifecycleEvent(actor: "UNCLE-gateway", kind: .received,
                               note: "Inbound credit transfer from PRTNRBKXXX.",
                               at: today.addingTimeInterval(-180)),
            ]))
    }

    private func appendSeed(_ rec: MessageRecord) {
        messages.append(rec)
    }
}

// =================================================================
// Mock envelope bodies — used only by the seed data. Real records
// embed the actual rendered SwiftMT103 / SwiftPacs008 output from
// the composer; these placeholders just give the audit trail
// something to display on the seed rows.
// =================================================================

private func mockPacs008Body(ref: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <Document xmlns="urn:iso:std:iso:20022:tech:xsd:pacs.008.001.08">
      <FIToFICstmrCdtTrf>
        <GrpHdr>
          <MsgId>MSG-\(ref)</MsgId>
          <CreDtTm>2026-05-28T09:14:22Z</CreDtTm>
          <NbOfTxs>1</NbOfTxs>
          <SttlmInf><SttlmMtd>CLRS</SttlmMtd></SttlmInf>
        </GrpHdr>
        <CdtTrfTxInf>
          <PmtId><EndToEndId>\(ref)</EndToEndId></PmtId>
          <IntrBkSttlmAmt Ccy="AXC">125000.00</IntrBkSttlmAmt>
          <ChrgBr>DEBT</ChrgBr>
          <Dbtr><Nm>ACME CORPORATION LTD</Nm></Dbtr>
          <Cdtr><Nm>BENEFICIARY CO LTD</Nm></Cdtr>
        </CdtTrfTxInf>
      </FIToFICstmrCdtTrf>
    </Document>
    """
}

private func mockMT103Body(ref: String) -> String {
    """
    {1:F01DEMOBKHKXXX0000000000}{2:I103BADBKXXX000N}{4:
    :20:\(ref)
    :23B:CRED
    :32A:260526AXC47200,00
    :50K:ACME CORPORATION LTD
    :59:MISCONFIGURED CO
    :71A:OUR
    -}
    """
}
