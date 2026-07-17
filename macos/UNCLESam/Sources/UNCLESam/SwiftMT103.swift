import Foundation

// =================================================================
// SwiftMT103 — render an MT103 (Customer Credit Transfer) message
// from a WireDraft.
//
// MT103 is the most common legacy SWIFT FIN message for cross-border
// customer payments. Banks use it to instruct a beneficiary's bank
// to credit a specific account on behalf of an ordering customer.
// UNCLE SAM's primary feature is generating SWIFT-aligned messages
// in real-time as the operator composes a wire — the rendered text
// is shown alongside the composer form, and (per
// docs/AXIOM_DESIGN_UNCLE.md §9) the SWIFT reference (Field 20)
// lands in the AXIOM Transaction's `reference` field while the full
// body lives in UNCLE's audit DB. MT103 is the legacy format; the
// default in UNCLE SAM's preview is the modern ISO 20022 pacs.008
// (see SwiftPacs008.swift) with MT103 retained as a toggle for
// banks still operating their FIN pipeline.
//
// Format spec: SWIFT MT103 (FIN message), Single Customer Credit
// Transfer. Mandatory fields: 20, 23B, 32A, 50a, 59a, 71A.
// Optional fields commonly used: 33B, 52a, 57a, 70, 72.
//
// This file generates the message AS TEXT — it does NOT validate
// against the canonical SWIFT schema beyond field-length / numeric
// constraints. A real bank fork would replace this with the
// institution's SWIFT/CGI-MP library (Volante, Bottomline,
// Finastra, etc.). For UNCLE SAM's design demonstration, plain
// text output is sufficient.
// =================================================================

/// Operator-composed wire draft. Bound to the composer view's state;
/// every field change re-renders the MT103 preview.
struct WireDraft: Equatable {
    /// Sender's reference — Field 20. Max 16 chars per MT103 spec.
    /// Auto-generated as `UW-<YYMMDD>-<6-hex>` if blank.
    var senderReference: String = ""
    /// Bank operation code — Field 23B. Default CRED (normal credit
    /// transfer); options: CRED / CRTS / SPAY / SPRI / SSTD.
    var bankOperationCode: String = "CRED"

    /// Value date (Field 32A) — YYMMDD format on the wire.
    /// This is the SWIFT value date — when the bank books the
    /// payment in its books. UNCLE SAM treats this as SWIFT-only
    /// metadata: AXIOM finality happens ~3 min after submit and
    /// is independent of this date.
    var valueDate: Date = Date()
    /// Settlement currency (3-char ISO 4217). For AXIOM-backed wires
    /// the canonical currency is "AXC"; "USD"/"EUR"/"GBP" allowed
    /// for institutions that quote AXC against fiat in the
    /// reference.
    var settlementCurrency: String = "AXC"
    /// Settlement amount (decimal, comma-separated per SWIFT
    /// convention on the wire).
    var settlementAmount: String = "0,00"
    /// Instructed amount (Field 33B) — usually same as settlement,
    /// rendered separately when the ordering customer specified an
    /// amount in a different currency.
    var instructedCurrency: String = "AXC"
    var instructedAmount: String = "0,00"

    /// Ordering customer (Field 50K) — the wire's payor. Free-form
    /// 4×35 chars on the wire; this collects name + address as one
    /// multi-line block.
    var orderingCustomerAccount: String = ""
    var orderingCustomerName: String = ""
    var orderingCustomerAddress: String = ""

    /// Ordering institution (Field 52A) — BIC of the bank sending
    /// the wire. Defaults from settings (the operator's own bank).
    var orderingInstitutionBIC: String = ""

    /// Intermediary institution (Field 56A) — BIC of the bank
    /// between sender and beneficiary's bank in a correspondent
    /// chain. SWIFT-only field: AXIOM is sender-direct-to-receiver
    /// (no correspondent banking), so this lands in the SWIFT
    /// envelope but does NOT affect the AXIOM rail.
    var intermediaryInstitutionBIC: String = ""

    /// Account with institution (Field 57A) — BIC of the
    /// beneficiary's bank.
    var beneficiaryInstitutionBIC: String = ""

    /// Beneficiary customer (Field 59) — the wire's payee. Same
    /// account + name + address shape as Field 50K.
    var beneficiaryAccount: String = ""
    var beneficiaryName: String = ""
    var beneficiaryAddress: String = ""

    /// Remittance information (Field 70) — free-form 4×35 chars.
    /// Visible to the beneficiary; commonly used for invoice
    /// numbers, internal references, narrative.
    var remittanceInformation: String = ""

    /// Sender-to-receiver information (Field 72) — institution-to-
    /// institution metadata, not for the beneficiary. Common uses:
    /// /ACC/ correspondent routing, /INS/ instructions to receiver.
    var senderToReceiverInfo: String = ""

    /// Charges code (Field 71A) — OUR / SHA / BEN. OUR = sender
    /// pays all charges; SHA = shared; BEN = beneficiary pays.
    var chargesCode: String = "OUR"

    // ── Charge amounts + FX (settled-vs-instructed reconciliation) ──
    //
    // These four fields explain WHY :32A: (settled) differs from
    // :33B: (instructed). The composer surfaces an inline
    // reconciliation line that ties them together so a banker can
    // see the difference is accounted for, not lost.

    /// Sender's charges (Field 71F) — institution-side fees the
    /// ordering bank deducted. Decimal, comma-separated per SWIFT.
    var senderCharges: String = ""
    /// Receiver's charges (Field 71G) — institution-side fees the
    /// beneficiary's bank will deduct. Decimal, comma-separated.
    var receiverCharges: String = ""
    /// Currency the charges are denominated in. Usually the
    /// settlement currency; a separate field because charges can
    /// sometimes ride in the instructed currency.
    var chargesCurrency: String = "AXC"
    /// Exchange rate (Field 36) — instructed-ccy → settlement-ccy.
    /// Required when :32A: and :33B: have different currencies.
    /// Format: decimal with comma separator (e.g. "0,9132").
    var exchangeRate: String = ""

    // ── SWIFT-only metadata (AXIOM has no native equivalent) ───
    //
    // These fields shape the SWIFT envelope for downstream
    // pipeline ingestion but are NOT honoured by the AXIOM rail.
    // UNCLE SAM tags them visibly so the operator never confuses
    // them with the AXIOM-anchored fields above.

    /// Bank operation priority — SPRI (priority) / SSTD
    /// (standard) / SPAY (payment-style). AXIOM has no priority
    /// lanes; this is SWIFT envelope shaping only. Kept separate
    /// from `bankOperationCode` (:23B:) because operators
    /// sometimes set both.
    var swiftPriority: String = "SSTD"

    /// Cancellation reference (:MT192: equivalent) — populated
    /// when this message is a follow-up to a prior wire the bank
    /// wants to cancel on the SWIFT side. Permanent banner above
    /// this field warns that AXIOM TX is not reversible.
    var cancellationReference: String = ""

    /// Regulatory reporting: beneficiary residency code (ISO
    /// 3166-1 alpha-2). Carried in MT103 narrative as
    /// `/BENEFRES/<cc>/`. Required by some jurisdictions for
    /// cross-border payment reporting.
    var beneficiaryResidency: String = ""

    /// Regulatory reporting: ultimate beneficiary (when the
    /// :59: party is acting on behalf of another). Carried as
    /// `/ULTBEN/<name>/`. Travel-rule adjacent.
    var ultimateBeneficiary: String = ""
}

enum SwiftMT103 {

    /// Render a complete MT103 message as text. Includes the SWIFT
    /// block structure ({1:…}{2:…}{4:…}-} per FIN message format).
    /// Multi-line fields are wrapped at 35 chars per line per the
    /// SWIFT spec; oversized text is truncated with a trailing
    /// indicator so the operator sees they need to shorten.
    static func render(_ d: WireDraft, senderBIC: String, receiverBIC: String) -> String {
        var msg = ""

        // ── Block 1 (Basic header) ─────────────────────────────
        // F = FIN, 01 = standard, then sender BIC (11 chars, padded
        // 'X' if 8-char base BIC), session number, sequence number.
        let senderLT = pad11(senderBIC)
        msg += "{1:F01\(senderLT)0000000000}"

        // ── Block 2 (Application header) ───────────────────────
        // I = input (sender-to-network), 103 = MT103, receiver
        // BIC, priority N (normal).
        let receiverLT = pad11(receiverBIC)
        msg += "{2:I103\(receiverLT)N}"

        // ── Block 4 (Text block) ───────────────────────────────
        msg += "{4:\n"

        // :20: Sender's reference (max 16 chars)
        let ref = d.senderReference.isEmpty ? autoReference() : d.senderReference
        msg += ":20:\(clip(ref, 16))\n"

        // :23B: Bank operation code (4 chars)
        msg += ":23B:\(d.bankOperationCode)\n"

        // :32A: Value date / currency / amount
        // Format: YYMMDDCCCNNN,NN  e.g. 260528USD1000,00
        let dateStr = formatValueDate(d.valueDate)
        msg += ":32A:\(dateStr)\(d.settlementCurrency)\(d.settlementAmount)\n"

        // :33B: Instructed amount (if different from settlement)
        if d.instructedCurrency != d.settlementCurrency
            || d.instructedAmount != d.settlementAmount {
            msg += ":33B:\(d.instructedCurrency)\(d.instructedAmount)\n"
        }

        // :50K: Ordering customer (account, name, address)
        // Format: /<account>\n<name>\n<address>
        var f50 = ":50K:"
        if !d.orderingCustomerAccount.isEmpty {
            f50 += "/\(d.orderingCustomerAccount)\n"
        }
        if !d.orderingCustomerName.isEmpty {
            f50 += wrap35(d.orderingCustomerName) + "\n"
        }
        if !d.orderingCustomerAddress.isEmpty {
            f50 += wrap35(d.orderingCustomerAddress) + "\n"
        }
        if f50 == ":50K:" {
            // No customer details — emit a placeholder so the
            // structure of the message stays valid in the preview.
            f50 += "(no ordering customer specified)\n"
        }
        msg += f50

        // :52A: Ordering institution BIC (optional)
        if !d.orderingInstitutionBIC.isEmpty {
            msg += ":52A:\(d.orderingInstitutionBIC)\n"
        }

        // :56A: Intermediary institution BIC (optional, SWIFT
        // correspondent chain — AXIOM ignores this).
        if !d.intermediaryInstitutionBIC.isEmpty {
            msg += ":56A:\(d.intermediaryInstitutionBIC)\n"
        }

        // :57A: Beneficiary's bank BIC (optional but typical)
        if !d.beneficiaryInstitutionBIC.isEmpty {
            msg += ":57A:\(d.beneficiaryInstitutionBIC)\n"
        }

        // :59: Beneficiary customer
        var f59 = ":59:"
        if !d.beneficiaryAccount.isEmpty {
            f59 += "/\(d.beneficiaryAccount)\n"
        }
        if !d.beneficiaryName.isEmpty {
            f59 += wrap35(d.beneficiaryName) + "\n"
        }
        if !d.beneficiaryAddress.isEmpty {
            f59 += wrap35(d.beneficiaryAddress) + "\n"
        }
        if f59 == ":59:" {
            f59 += "(no beneficiary specified)\n"
        }
        msg += f59

        // :70: Remittance information (optional, 4×35)
        if !d.remittanceInformation.isEmpty {
            msg += ":70:\(wrap35(d.remittanceInformation))\n"
        }

        // :71A: Charges code
        msg += ":71A:\(d.chargesCode)\n"

        // :71F: Sender's charges (optional, CCY + amount)
        if !d.senderCharges.isEmpty {
            msg += ":71F:\(d.chargesCurrency)\(d.senderCharges)\n"
        }
        // :71G: Receiver's charges (optional)
        if !d.receiverCharges.isEmpty {
            msg += ":71G:\(d.chargesCurrency)\(d.receiverCharges)\n"
        }
        // :36: Exchange rate (required when 32A ccy != 33B ccy)
        if !d.exchangeRate.isEmpty {
            msg += ":36:\(d.exchangeRate)\n"
        }

        // :72: Sender-to-receiver (optional, 6×35) — also carries
        // cancellation reference when present.
        var f72 = d.senderToReceiverInfo
        if !d.cancellationReference.isEmpty {
            let prefix = "/CANC/\(d.cancellationReference)"
            f72 = f72.isEmpty ? prefix : "\(prefix)\n\(f72)"
        }
        if !f72.isEmpty {
            msg += ":72:\(wrap35(f72))\n"
        }

        // :77B: Regulatory reporting (optional). UNCLE SAM emits
        // beneficiary residency + ultimate beneficiary as
        // /BENEFRES/<cc>/ and /ULTBEN/<name>/ when populated.
        var regParts: [String] = []
        if !d.beneficiaryResidency.isEmpty {
            regParts.append("/BENEFRES/\(d.beneficiaryResidency)/")
        }
        if !d.ultimateBeneficiary.isEmpty {
            regParts.append("/ULTBEN/\(d.ultimateBeneficiary)/")
        }
        if !regParts.isEmpty {
            msg += ":77B:\(regParts.joined(separator: " "))\n"
        }

        // Block 4 terminator + end-of-message
        msg += "-}"

        return msg
    }

    /// Generate a default sender reference when the operator hasn't
    /// supplied one. Format: `SM-<YYMMDD>-<6-hex>`.
    /// 'SM' = UNCLE SAM prefix so back-office systems can recognise
    /// the originating application. Total = 16 chars (the MT103
    /// Field 20 max).
    static func autoReference() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyMMdd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let date = fmt.string(from: Date())
        let hex = String(format: "%06X", Int.random(in: 0...0xFFFFFF))
        return "SM-\(date)-\(hex)"
    }

    /// MT103 Field 32A value-date format: YYMMDD.
    private static func formatValueDate(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyMMdd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: d)
    }

    /// Pad a BIC to 11 chars (SWIFT-canonical Logical Terminal
    /// identifier). 8-char BICs get appended `XXX` (default branch);
    /// shorter / longer left as-is and clipped at 11 to give the
    /// operator a visible signal if the input is malformed.
    private static func pad11(_ bic: String) -> String {
        if bic.count == 8 { return bic + "XXX" }
        if bic.count > 11 { return String(bic.prefix(11)) }
        return bic.padding(toLength: 11, withPad: "X", startingAt: 0)
    }

    /// Clip a string to N chars (no ellipsis — SWIFT is silent
    /// about overflow handling, banks typically just truncate).
    private static func clip(_ s: String, _ n: Int) -> String {
        if s.count <= n { return s }
        return String(s.prefix(n))
    }

    /// Wrap a string at 35 chars per line (SWIFT multi-line field
    /// limit). Hard wrap on character boundary — no word-wrap,
    /// since SWIFT messages have to be exactly-character predictable.
    /// Caller is expected to keep field content under 4×35 for the
    /// 4-line fields and 6×35 for the 6-line fields.
    private static func wrap35(_ s: String) -> String {
        var out = ""
        var idx = s.startIndex
        while idx < s.endIndex {
            let end = s.index(idx, offsetBy: 35, limitedBy: s.endIndex) ?? s.endIndex
            out += s[idx..<end]
            idx = end
            if idx < s.endIndex { out += "\n" }
        }
        return out
    }
}
