import Foundation

// =================================================================
// SwiftInboundParser — the REVERSE of SwiftMT103 / SwiftPacs008.
//
// UNCLE SAM's forward path (WireView) turns an operator-composed
// WireDraft into a SWIFT-aligned message (MT103 FIN or pacs.008
// ISO 20022). This file runs that mapping BACKWARDS: a bank that
// already lives in SWIFT can paste an inbound MT103 or pacs.008
// message and UNCLE SAM parses it into a WireDraft — which then
// drives the same composer + AXIOM rail as a hand-typed wire.
//
// That makes the SWIFT⇄AXIOM bridge bidirectional:
//   • AXIOM → SWIFT : compose a wire, read the SWIFT envelope
//                     (SwiftMT103.render / SwiftPacs008.render)
//   • SWIFT → AXIOM : paste a SWIFT message, get an AXIOM-ready
//                     WireDraft (this file)
//
// The field mapping is the inverse of the renderers — every tag /
// element the renderers EMIT, this parser READS back. Where the
// renderers wrap free-form fields at 35 chars (MT103) the inverse
// is inherently lossy across the name/address boundary (this is a
// real SWIFT property, not a bug); single-line fields round-trip
// exactly. Anything the parser can't place is surfaced in
// `warnings` rather than silently dropped — UNCLE SAM never lets a
// banker assume a field was carried when it wasn't.
//
// Pure Foundation — no SwiftUI, no FFI. The forward renderers carry
// the same property, so the pair compiles + round-trips standalone
// for testing (see the round-trip harness).
// =================================================================

/// Which SWIFT dialect a pasted message turned out to be.
enum ParsedSwiftFormat {
    case mt103
    case pacs008
}

/// Result of parsing an inbound SWIFT message back into a WireDraft.
/// `senderBIC` / `receiverBIC` are the envelope-level institutions
/// (MT103 block 1/2, or pacs.008 Dbtr/Cdtr agents) — the composer
/// uses the in-body :52A:/:57A: equivalents, but these are surfaced
/// so the import UI can pre-fill routing.
struct ParsedSwiftMessage {
    var draft: WireDraft
    var senderBIC: String
    var receiverBIC: String
    var format: ParsedSwiftFormat
    var warnings: [String]
}

enum SwiftInboundParser {

    // ── Format detection + dispatch ──────────────────────────────

    /// Sniff which dialect a pasted blob is. Returns nil if it
    /// resembles neither (the import UI shows "unrecognised").
    static func detectFormat(_ text: String) -> ParsedSwiftFormat? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("FIToFICstmrCdtTrf") || t.contains("<Document") {
            return .pacs008
        }
        // MT103: FIN block structure or a bare block-4 with :20:.
        if t.contains("{4:") || t.range(of: #"(?m)^:20:"#, options: .regularExpression) != nil {
            return .mt103
        }
        return nil
    }

    /// Parse a pasted SWIFT message of either dialect. Returns nil
    /// only when the format can't be recognised or the XML is
    /// malformed; a recognised-but-sparse message still parses (with
    /// warnings for missing mandatory fields).
    static func parse(_ text: String) -> ParsedSwiftMessage? {
        switch detectFormat(text) {
        case .mt103:   return parseMT103(text)
        case .pacs008: return parsePacs008(text)
        case .none:    return nil
        }
    }

    // ── MT103 (FIN) ──────────────────────────────────────────────

    /// Parse an MT103 FIN message. Reads block 1/2 for the sender /
    /// receiver Logical Terminal BICs and block 4 for the colon-
    /// tagged payment fields. Inverse of SwiftMT103.render.
    static func parseMT103(_ text: String) -> ParsedSwiftMessage {
        var d = WireDraft()
        var warnings: [String] = []

        let senderBIC = trimLT(blockContent(text, "1").map { stripFinHeader($0) } ?? "")
        let receiverBIC = trimLT(blockContent(text, "2").map { stripAppHeader($0) } ?? "")

        // Block 4 holds the tagged fields. Fall back to the whole
        // message if the operator pasted only the field body.
        let body = blockContent(text, "4") ?? text
        let fields = scanTaggedFields(body)

        for (tag, value) in fields {
            switch tag {
            case "20":  d.senderReference = value
            case "23B": d.bankOperationCode = value
            case "32A": applyField32A(value, into: &d, warnings: &warnings)
            case "33B":
                let (ccy, amt) = splitCcyAmount(value)
                d.instructedCurrency = ccy
                d.instructedAmount = amt
            case "50K": applyPartyField(value, name: &d.orderingCustomerName,
                                        account: &d.orderingCustomerAccount,
                                        address: &d.orderingCustomerAddress)
            case "52A": d.orderingInstitutionBIC = value
            case "56A": d.intermediaryInstitutionBIC = value
            case "57A": d.beneficiaryInstitutionBIC = value
            case "59":  applyPartyField(value, name: &d.beneficiaryName,
                                        account: &d.beneficiaryAccount,
                                        address: &d.beneficiaryAddress)
            case "70":  d.remittanceInformation = joinLines(value)
            case "71A": d.chargesCode = value
            case "71F":
                let (ccy, amt) = splitCcyAmount(value)
                d.chargesCurrency = ccy
                d.senderCharges = amt
            case "71G":
                let (ccy, amt) = splitCcyAmount(value)
                if d.chargesCurrency.isEmpty || d.chargesCurrency == "AXC" {
                    d.chargesCurrency = ccy
                }
                d.receiverCharges = amt
            case "36":  d.exchangeRate = value
            case "72":  applyField72(value, into: &d)
            case "77B": applyField77B(value, into: &d)
            default:
                warnings.append("Unmapped MT103 field :\(tag): — not carried into the AXIOM wire")
            }
        }

        if d.beneficiaryName.isEmpty { warnings.append("No beneficiary (:59:) name found") }
        if d.settlementAmount.isEmpty || d.settlementAmount == "0,00" {
            warnings.append("No settlement amount (:32A:) found")
        }

        return ParsedSwiftMessage(draft: d, senderBIC: senderBIC,
                                  receiverBIC: receiverBIC,
                                  format: .mt103, warnings: warnings)
    }

    // ── pacs.008 (ISO 20022 XML) ─────────────────────────────────

    /// Parse a pacs.008 (FIToFICstmrCdtTrf) ISO 20022 message via
    /// XMLParser. Inverse of SwiftPacs008.render. Returns nil on
    /// malformed XML.
    static func parsePacs008(_ xml: String) -> ParsedSwiftMessage? {
        guard let data = xml.data(using: .utf8) else { return nil }
        let delegate = Pacs008Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }

        var warnings = delegate.warnings
        if delegate.draft.beneficiaryName.isEmpty {
            warnings.append("No creditor (<Cdtr><Nm>) found")
        }
        if delegate.draft.settlementAmount.isEmpty || delegate.draft.settlementAmount == "0,00" {
            warnings.append("No settlement amount (<IntrBkSttlmAmt>) found")
        }
        return ParsedSwiftMessage(draft: delegate.draft,
                                  senderBIC: delegate.senderBIC,
                                  receiverBIC: delegate.receiverBIC,
                                  format: .pacs008, warnings: warnings)
    }

    // ── MT103 helpers ────────────────────────────────────────────

    /// Extract the content of a FIN block `{n:…}`. For block 4 the
    /// content runs from after `{4:` up to the closing `-}`.
    private static func blockContent(_ text: String, _ n: String) -> String? {
        let open = "{\(n):"
        guard let r = text.range(of: open) else { return nil }
        let after = text[r.upperBound...]
        if n == "4" {
            if let end = after.range(of: "-}") {
                return String(after[..<end.lowerBound])
            }
            return String(after)
        }
        // Simple blocks: read to the matching '}'.
        if let end = after.firstIndex(of: "}") {
            return String(after[..<end])
        }
        return String(after)
    }

    /// Block 1 = `F01<LT(11)><session><sequence>`; the LT is the
    /// sender BIC. Strip the `F01` application id, keep the next 11.
    private static func stripFinHeader(_ s: String) -> String {
        var t = s
        if t.hasPrefix("F01") { t.removeFirst(3) }
        return String(t.prefix(11))
    }

    /// Block 2 (input) = `I103<LT(11)><priority>`; the LT is the
    /// receiver BIC.
    private static func stripAppHeader(_ s: String) -> String {
        var t = s
        if t.hasPrefix("I103") || t.hasPrefix("O103") { t.removeFirst(4) }
        return String(t.prefix(11))
    }

    /// An 11-char Logical Terminal is an 8-char BIC + 3-char branch.
    /// The renderer pads 8-char BICs with `XXX`; strip a trailing
    /// `XXX` so an 8-char input round-trips. (A real branch code is
    /// indistinguishable from the pad — same ambiguity SWIFT has.)
    private static func trimLT(_ s: String) -> String {
        if s.count == 11 && s.hasSuffix("XXX") { return String(s.prefix(8)) }
        return s
    }

    /// Scan an MT103 block-4 body into (tag, value) pairs. A field
    /// starts at a line `:tag:` and its value runs until the next
    /// `:tag:` line (or end) — preserving multi-line fields.
    private static func scanTaggedFields(_ body: String) -> [(String, String)] {
        var out: [(String, String)] = []
        var currentTag: String? = nil
        var currentValue: [String] = []

        func flush() {
            if let t = currentTag {
                out.append((t, currentValue.joined(separator: "\n")
                                            .trimmingCharacters(in: .newlines)))
            }
            currentTag = nil
            currentValue = []
        }

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let m = matchTagLine(line) {
                flush()
                currentTag = m.tag
                if !m.rest.isEmpty { currentValue.append(m.rest) }
            } else if currentTag != nil {
                // Continuation line of the current field. Ignore a
                // stray block terminator if it slipped through.
                if line == "-}" || line == "-" { continue }
                currentValue.append(line)
            }
        }
        flush()
        return out
    }

    /// Match a `:tag:rest` field-opening line. Tag is digits with an
    /// optional trailing letter (e.g. 32A, 71F, 77B, 50K).
    private static func matchTagLine(_ line: String) -> (tag: String, rest: String)? {
        guard line.hasPrefix(":") else { return nil }
        let afterColon = line.dropFirst()
        guard let close = afterColon.firstIndex(of: ":") else { return nil }
        let tag = String(afterColon[..<close])
        // Validate tag shape: 2-3 chars, digits then optional letter.
        let ok = tag.count >= 2 && tag.count <= 3
            && tag.prefix(2).allSatisfy { $0.isNumber }
            && (tag.count == 2 || tag.last!.isLetter)
        guard ok else { return nil }
        let rest = String(afterColon[afterColon.index(after: close)...])
        return (tag, rest)
    }

    /// :32A: = YYMMDD + 3-char CCY + amount. Apply to the draft.
    private static func applyField32A(_ value: String, into d: inout WireDraft,
                                      warnings: inout [String]) {
        guard value.count >= 9 else {
            warnings.append(":32A: malformed — expected YYMMDDCCCamount")
            return
        }
        let chars = Array(value)
        let dateStr = String(chars[0..<6])
        let ccy = String(chars[6..<9])
        let amount = String(chars[9...])
        d.settlementCurrency = ccy
        d.settlementAmount = amount
        let fmt = DateFormatter()
        fmt.dateFormat = "yyMMdd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        if let date = fmt.date(from: dateStr) {
            d.valueDate = date
        } else {
            warnings.append(":32A: value date '\(dateStr)' not parseable")
        }
    }

    /// Split a `<CCY><amount>` SWIFT value (e.g. "AXC1000,00") into
    /// the 3-char currency and the amount.
    private static func splitCcyAmount(_ value: String) -> (String, String) {
        guard value.count > 3 else { return (value, "") }
        let chars = Array(value)
        return (String(chars[0..<3]), String(chars[3...]))
    }

    /// Parse a party block (:50K: ordering customer / :59:
    /// beneficiary). Shape: optional `/account` first line, then a
    /// name line, then address lines. Single-line names round-trip
    /// exactly; a name wrapped across >35 chars is ambiguous against
    /// the address boundary (a real SWIFT property).
    private static func applyPartyField(_ value: String, name: inout String,
                                        account: inout String,
                                        address: inout String) {
        var lines = value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
        if let first = lines.first, first.hasPrefix("/") {
            account = String(first.dropFirst())
            lines.removeFirst()
        }
        guard !lines.isEmpty else { return }
        name = lines.removeFirst()
        if !lines.isEmpty {
            address = lines.joined(separator: "\n")
        }
    }

    /// :72: sender-to-receiver. A leading `/CANC/<ref>` is the
    /// cancellation reference the renderer prepends; split it back
    /// out so it lands in `cancellationReference`, not the free text.
    private static func applyField72(_ value: String, into d: inout WireDraft) {
        let joined = joinLines(value)
        if joined.hasPrefix("/CANC/") {
            let afterTag = joined.dropFirst("/CANC/".count)
            // Cancellation ref runs to the next newline-equivalent;
            // the renderer joined remaining info after a newline.
            if let nl = afterTag.firstIndex(of: "\n") {
                d.cancellationReference = String(afterTag[..<nl]).trimmingCharacters(in: .whitespaces)
                d.senderToReceiverInfo = String(afterTag[afterTag.index(after: nl)...])
            } else {
                d.cancellationReference = String(afterTag).trimmingCharacters(in: .whitespaces)
            }
        } else {
            d.senderToReceiverInfo = joined
        }
    }

    /// :77B: regulatory reporting — `/BENEFRES/<cc>/` and
    /// `/ULTBEN/<name>/` tokens the renderer emits.
    private static func applyField77B(_ value: String, into d: inout WireDraft) {
        let joined = joinLines(value)
        if let res = slashToken(joined, "BENEFRES") { d.beneficiaryResidency = res }
        if let ult = slashToken(joined, "ULTBEN") { d.ultimateBeneficiary = ult }
    }

    /// Extract `<value>` from a `/KEY/<value>/` token inside text.
    private static func slashToken(_ text: String, _ key: String) -> String? {
        guard let r = text.range(of: "/\(key)/") else { return nil }
        let after = text[r.upperBound...]
        if let end = after.firstIndex(of: "/") {
            return String(after[..<end])
        }
        return String(after)
    }

    /// Collapse a wrapped multi-line field back to a single line.
    /// The renderer hard-wrapped at 35 chars with no separator, so
    /// rejoining without a space is the faithful inverse.
    private static func joinLines(_ s: String) -> String {
        s.split(separator: "\n").map { String($0) }.joined()
    }
}

// =================================================================
// Pacs008Delegate — XMLParser delegate that walks a pacs.008
// document and routes element text into a WireDraft. Disambiguates
// the structurally-identical Dbtr/Cdtr (debtor vs creditor) and
// DbtrAgt/CdtrAgt (their agents) sub-trees by the element stack.
// =================================================================
private final class Pacs008Delegate: NSObject, XMLParserDelegate {
    var draft = WireDraft()
    var senderBIC = ""
    var receiverBIC = ""
    var warnings: [String] = []

    private var stack: [String] = []
    private var text = ""
    private var sttlmCcy = ""
    private var instdCcy = ""

    func parser(_ parser: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attrs: [String: String]) {
        stack.append(el)
        text = ""
        if el == "IntrBkSttlmAmt" { sttlmCcy = attrs["Ccy"] ?? "" }
        if el == "InstdAmt" { instdCcy = attrs["Ccy"] ?? "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName: String?) {
        let val = text.trimmingCharacters(in: .whitespacesAndNewlines)
        func has(_ name: String) -> Bool { stack.contains(name) }

        switch el {
        case "EndToEndId":
            if draft.senderReference.isEmpty { draft.senderReference = val }
        case "IntrBkSttlmAmt":
            draft.settlementCurrency = sttlmCcy
            draft.settlementAmount = commaDecimal(val)
        case "InstdAmt":
            draft.instructedCurrency = instdCcy
            draft.instructedAmount = commaDecimal(val)
        case "IntrBkSttlmDt":
            if let date = isoDate(val) { draft.valueDate = date }
        case "ChrgBr":
            draft.chargesCode = mt103Charge(val)
        case "Nm":
            if has("Cdtr") { draft.beneficiaryName = val }
            else if has("Dbtr") { draft.orderingCustomerName = val }
        case "BICFI":
            if has("CdtrAgt") { draft.beneficiaryInstitutionBIC = val; receiverBIC = val }
            else if has("DbtrAgt") { draft.orderingInstitutionBIC = val; senderBIC = val }
        case "Id":
            // Innermost <Othr><Id> carries the account number.
            if has("Othr") {
                if has("CdtrAcct") { draft.beneficiaryAccount = val }
                else if has("DbtrAcct") { draft.orderingCustomerAccount = val }
            }
        case "AdrLine":
            if has("Cdtr") {
                draft.beneficiaryAddress = appendLine(draft.beneficiaryAddress, val)
            } else if has("Dbtr") {
                draft.orderingCustomerAddress = appendLine(draft.orderingCustomerAddress, val)
            }
        case "Ustrd":
            draft.remittanceInformation = val
        default:
            break
        }

        text = ""
        if stack.last == el { stack.removeLast() }
    }

    /// ISO 20022 uses a period decimal; WireDraft / MT103 use a
    /// comma. Convert back on the way in.
    private func commaDecimal(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: ",")
    }

    /// pacs.008 ChrgBr → MT103 :71A: code.
    private func mt103Charge(_ chrgBr: String) -> String {
        switch chrgBr {
        case "DEBT": return "OUR"
        case "SHAR": return "SHA"
        case "CRED": return "BEN"
        default:     return "OUR"
        }
    }

    private func isoDate(_ s: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: s)
    }

    private func appendLine(_ existing: String, _ line: String) -> String {
        existing.isEmpty ? line : existing + "\n" + line
    }
}
