import Foundation

// =================================================================
// SwiftPacs008 — render an ISO 20022 pacs.008 (FIToFICstmrCdtTrf)
// message from the same WireDraft consumed by SwiftMT103.
//
// pacs.008 is the modern SWIFT message for customer credit transfers
// — the ISO 20022 replacement for MT103 that CBPR+, Target2 and
// Fedwire have all standardised on under the FIN→ISO 20022
// migration (cutover late-2025 → 2026). It carries structurally the
// same payment information as MT103 but as RFC-conformant XML
// against the ISO 20022 message scheme, with strongly-typed
// elements rather than colon-tagged FIN fields.
//
// UNCLE SAM defaults to pacs.008 in the preview pane because that's
// the format banks need going forward; MT103 remains a toggle for
// the legacy FIN pipeline.
//
// Like SwiftMT103, this renders the message AS TEXT (well-formed
// XML) — it does NOT validate against the canonical ISO 20022 XSD
// beyond basic structure. A real bank fork would replace this with
// the institution's ISO 20022 library (Volante CSM, Bottomline
// Universal Aggregator, Finastra Fusion Payments, etc.).
//
// Element coverage (pacs.008.001.08 — current SWIFT CBPR+ version):
//
//   <FIToFICstmrCdtTrf>
//     <GrpHdr>            group header (MsgId, CreDtTm, NbOfTxs,
//                         SttlmInf — settlement method)
//     <CdtTrfTxInf>       credit transfer transaction information:
//       <PmtId>           reference IDs (InstrId, EndToEndId, TxId)
//       <IntrBkSttlmAmt>  settlement amount + currency
//       <IntrBkSttlmDt>   value date
//       <InstdAmt>        instructed amount + currency (33B-equiv)
//       <ChrgBr>          charge bearer (OUR/SHA/BEN → DEBT/SHAR/CRED)
//       <Dbtr>            debtor / ordering customer (50K-equiv)
//       <DbtrAcct>        debtor account
//       <DbtrAgt>         debtor agent BIC (52A-equiv)
//       <CdtrAgt>         creditor agent BIC (57A-equiv)
//       <Cdtr>            creditor / beneficiary (59-equiv)
//       <CdtrAcct>        creditor account
//       <RmtInf>          remittance information (70-equiv)
//
// Note: pacs.008 does NOT have a direct equivalent to MT103
// Field 72 (sender-to-receiver, institution-only) — that maps to
// pacs.009 for cover messages or to ISO 20022's <InstrForNxtAgt>
// at the inter-bank layer. Render it as a comment in the XML output
// so the operator can see where they expect it.
// =================================================================

enum SwiftPacs008 {

    /// ISO 20022 namespace constant — pacs.008.001.08 is the current
    /// CBPR+ supported version (as of the SWIFT 2026 release). Pinned
    /// here so the rendered XML is round-trip-validatable against
    /// the official schema.
    static let namespace = "urn:iso:std:iso:20022:tech:xsd:pacs.008.001.08"

    /// Render a complete pacs.008 message as ISO 20022 XML.
    /// Whitespace formatted for human reading (line + 2-space
    /// indent); production banks would emit compact / canonical XML.
    static func render(_ d: WireDraft, senderBIC: String, receiverBIC: String) -> String {
        let endToEnd = d.senderReference.isEmpty
            ? autoEndToEndId()
            : clip(d.senderReference, 35)
        let txId = endToEnd  // typically equal at the originator
        let msgId = autoMsgId()
        let creDtTm = isoTimestamp(Date())
        let valDt = isoDate(d.valueDate)
        let chrgBr = pacsChargeBearer(d.chargesCode)

        var xml = ""
        xml += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<Document xmlns=\"\(namespace)\">\n"
        xml += "  <FIToFICstmrCdtTrf>\n"

        // ── Group Header ─────────────────────────────────────────
        xml += "    <GrpHdr>\n"
        xml += "      <MsgId>\(esc(msgId))</MsgId>\n"
        xml += "      <CreDtTm>\(creDtTm)</CreDtTm>\n"
        xml += "      <NbOfTxs>1</NbOfTxs>\n"
        xml += "      <SttlmInf>\n"
        // CLRS = Clearing System (vs. INDA Instructed Agent /
        // COVE Cover). CLRS matches MT103-equivalent direct
        // settlement via SWIFT.
        xml += "        <SttlmMtd>CLRS</SttlmMtd>\n"
        xml += "      </SttlmInf>\n"
        xml += "    </GrpHdr>\n"

        // ── Credit Transfer Transaction Information ──────────────
        xml += "    <CdtTrfTxInf>\n"

        // Payment identification
        xml += "      <PmtId>\n"
        xml += "        <InstrId>\(esc(endToEnd))</InstrId>\n"
        xml += "        <EndToEndId>\(esc(endToEnd))</EndToEndId>\n"
        xml += "        <TxId>\(esc(txId))</TxId>\n"
        xml += "      </PmtId>\n"

        // Inter-bank settlement amount
        xml += "      <IntrBkSttlmAmt Ccy=\"\(esc(d.settlementCurrency))\">"
        xml += "\(esc(normaliseAmount(d.settlementAmount)))</IntrBkSttlmAmt>\n"

        // Value date
        xml += "      <IntrBkSttlmDt>\(valDt)</IntrBkSttlmDt>\n"

        // Instructed amount (only if different from settlement)
        if d.instructedCurrency != d.settlementCurrency
            || d.instructedAmount != d.settlementAmount {
            xml += "      <InstdAmt Ccy=\"\(esc(d.instructedCurrency))\">"
            xml += "\(esc(normaliseAmount(d.instructedAmount)))</InstdAmt>\n"
        }

        // Charge bearer
        xml += "      <ChrgBr>\(chrgBr)</ChrgBr>\n"

        // Debtor (ordering customer)
        xml += "      <Dbtr>\n"
        if !d.orderingCustomerName.isEmpty {
            xml += "        <Nm>\(esc(d.orderingCustomerName))</Nm>\n"
        } else {
            xml += "        <Nm>(no ordering customer specified)</Nm>\n"
        }
        if !d.orderingCustomerAddress.isEmpty {
            xml += "        <PstlAdr>\n"
            for line in splitAddress(d.orderingCustomerAddress) {
                xml += "          <AdrLine>\(esc(line))</AdrLine>\n"
            }
            xml += "        </PstlAdr>\n"
        }
        xml += "      </Dbtr>\n"

        // Debtor account
        if !d.orderingCustomerAccount.isEmpty {
            xml += "      <DbtrAcct>\n"
            xml += "        <Id>\n"
            xml += "          <Othr>\n"
            xml += "            <Id>\(esc(d.orderingCustomerAccount))</Id>\n"
            xml += "          </Othr>\n"
            xml += "        </Id>\n"
            xml += "      </DbtrAcct>\n"
        }

        // Debtor agent (ordering institution)
        let dbtrAgtBIC = d.orderingInstitutionBIC.isEmpty
            ? senderBIC : d.orderingInstitutionBIC
        xml += "      <DbtrAgt>\n"
        xml += "        <FinInstnId>\n"
        xml += "          <BICFI>\(esc(dbtrAgtBIC))</BICFI>\n"
        xml += "        </FinInstnId>\n"
        xml += "      </DbtrAgt>\n"

        // Creditor agent (beneficiary's bank)
        let cdtrAgtBIC = d.beneficiaryInstitutionBIC.isEmpty
            ? receiverBIC : d.beneficiaryInstitutionBIC
        xml += "      <CdtrAgt>\n"
        xml += "        <FinInstnId>\n"
        xml += "          <BICFI>\(esc(cdtrAgtBIC))</BICFI>\n"
        xml += "        </FinInstnId>\n"
        xml += "      </CdtrAgt>\n"

        // Creditor (beneficiary)
        xml += "      <Cdtr>\n"
        if !d.beneficiaryName.isEmpty {
            xml += "        <Nm>\(esc(d.beneficiaryName))</Nm>\n"
        } else {
            xml += "        <Nm>(no beneficiary specified)</Nm>\n"
        }
        if !d.beneficiaryAddress.isEmpty {
            xml += "        <PstlAdr>\n"
            for line in splitAddress(d.beneficiaryAddress) {
                xml += "          <AdrLine>\(esc(line))</AdrLine>\n"
            }
            xml += "        </PstlAdr>\n"
        }
        xml += "      </Cdtr>\n"

        // Creditor account
        if !d.beneficiaryAccount.isEmpty {
            xml += "      <CdtrAcct>\n"
            xml += "        <Id>\n"
            xml += "          <Othr>\n"
            xml += "            <Id>\(esc(d.beneficiaryAccount))</Id>\n"
            xml += "          </Othr>\n"
            xml += "        </Id>\n"
            xml += "      </CdtrAcct>\n"
        }

        // Remittance information (visible to creditor)
        if !d.remittanceInformation.isEmpty {
            xml += "      <RmtInf>\n"
            xml += "        <Ustrd>\(esc(d.remittanceInformation))</Ustrd>\n"
            xml += "      </RmtInf>\n"
        }

        // Field 72 equivalent — pacs.008 has no direct match;
        // render as XML comment so the operator sees the
        // institution-only info isn't dropped silently.
        if !d.senderToReceiverInfo.isEmpty {
            xml += "      <!-- Sender-to-Receiver (MT103 Field 72): \(esc(d.senderToReceiverInfo)) -->\n"
            xml += "      <!-- pacs.008 maps this to pacs.009 cover or <InstrForNxtAgt> at the inter-bank layer -->\n"
        }

        xml += "    </CdtTrfTxInf>\n"
        xml += "  </FIToFICstmrCdtTrf>\n"
        xml += "</Document>\n"

        return xml
    }

    /// Default end-to-end identifier when the operator hasn't set
    /// a sender reference. pacs.008 EndToEndId allows up to 35
    /// chars (vs. MT103 Field 20's 16); reuse the same SM- prefix
    /// for consistency with the MT103 path, but extend the hex
    /// portion so the EndToEndId stays unique within the bank's
    /// daily volume.
    static func autoEndToEndId() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let date = fmt.string(from: Date())
        let hex = String(format: "%012X", Int.random(in: 0...0xFFFFFFFFFFFF))
        return "SM-\(date)-\(hex)"
    }

    /// Group-header MsgId — distinct from EndToEndId. SWIFT CBPR+
    /// recommends `<BIC>-<YYYYMMDD>-<sequence>` for bank-level
    /// uniqueness; design preview generates a short hex seq.
    private static func autoMsgId() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let date = fmt.string(from: Date())
        let hex = String(format: "%08X", Int.random(in: 0...0xFFFFFFFF))
        return "MSG-\(date)-\(hex)"
    }

    /// ISO 8601 timestamp for <CreDtTm> — UTC with 'Z' suffix.
    private static func isoTimestamp(_ d: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: d)
    }

    /// ISO 8601 date (YYYY-MM-DD) for <IntrBkSttlmDt>.
    private static func isoDate(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: d)
    }

    /// Map MT103 Field 71A charges code to pacs.008 ChrgBr:
    ///   OUR → DEBT (debtor pays)
    ///   SHA → SHAR (shared)
    ///   BEN → CRED (creditor pays)
    private static func pacsChargeBearer(_ mt103Code: String) -> String {
        switch mt103Code {
        case "OUR": return "DEBT"
        case "SHA": return "SHAR"
        case "BEN": return "CRED"
        default:    return "SHAR"
        }
    }

    /// Normalise amount: SWIFT MT103 uses comma decimal ("1000,00"),
    /// pacs.008 uses period decimal ("1000.00") per ISO 20022.
    private static func normaliseAmount(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: ".")
    }

    /// Split a multi-line address into AdrLine elements. pacs.008
    /// allows up to 7 <AdrLine> entries of 70 chars each — far
    /// looser than MT103's 4×35.
    private static func splitAddress(_ s: String) -> [String] {
        let lines = s.split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(lines.prefix(7))
    }

    /// XML attribute / element-content escaping.
    private static func esc(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }

    /// Truncation helper — same shape as SwiftMT103.clip.
    private static func clip(_ s: String, _ n: Int) -> String {
        if s.count <= n { return s }
        return String(s.prefix(n))
    }
}
