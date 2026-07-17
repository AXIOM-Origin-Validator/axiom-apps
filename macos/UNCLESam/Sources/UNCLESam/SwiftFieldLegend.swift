import SwiftUI

// =================================================================
// SwiftFieldLegend — plain-language explanations of the SWIFT
// field codes used throughout the composer + envelope previews.
//
// Two presentations:
//   1. Hover/help tooltips on each field code (always available;
//      uses SwiftUI's `.help()` modifier so they appear after the
//      system hover delay only).
//   2. A toggleable legend panel that overlays the composer with
//      a key-value list of every field code. Off by default so
//      the banker-facing view stays clean and dense; turn on for
//      a non-banker audience watching the demo.
//
// The vocabulary tracks SWIFT MT103 field semantics — UNCLE SAM
// deliberately uses SWIFT field names verbatim (per the
// "vocabulary is the trust" guidance), so a banker glance is
// productive without the legend.
// =================================================================

/// One legend entry — the field code + its plain-language
/// explanation. The longer-form description appears in the
/// toggleable panel; `short` is used inline for tooltips.
struct SwiftFieldEntry: Identifiable {
    let id: String           // the SWIFT tag e.g. ":20:"
    let title: String        // human title e.g. "Sender's Reference"
    let short: String        // one-line tooltip explanation
    let detail: String       // longer paragraph for the panel
    var tag: String { id }
}

enum SwiftFieldLegend {

    /// Canonical entries. Ordered for the panel.
    static let entries: [SwiftFieldEntry] = [
        SwiftFieldEntry(
            id: ":20:", title: "Sender's Reference",
            short: "Sender's Reference — 16-char unique reference assigned by the ordering bank.",
            detail: "The originating bank's unique reference for this transaction. Max 16 chars. Lands in AXIOM's Transaction.reference field; UNCLE uses it as the audit DB key."),
        SwiftFieldEntry(
            id: ":23B:", title: "Bank Operation Code",
            short: "Bank Operation Code — CRED (credit), CRTS (test), SPRI (priority), SSTD (standard), SPAY (payment-style).",
            detail: "Tells the receiving bank what kind of operation this is. CRED is the default for a normal credit transfer."),
        SwiftFieldEntry(
            id: ":32A:", title: "Value Date, Currency, Settled Amount",
            short: "Value Date / Currency / Settled Amount — YYMMDD + 3-letter ISO ccy + decimal amount (comma separator).",
            detail: "The amount actually settled between banks. The combination of date+currency+amount on one line. Differs from :33B: (instructed amount) when charges or FX are involved — see :71F: / :71G: / :36:."),
        SwiftFieldEntry(
            id: ":33B:", title: "Instructed Amount",
            short: "Instructed Amount — what the ordering customer asked to send. May differ from settled (:32A:) when charges/FX apply.",
            detail: "What the ordering customer instructed their bank to send. When this differs from :32A: (settled), the gap is explained by sender/receiver charges (:71F:/:71G:) and exchange rate (:36:)."),
        SwiftFieldEntry(
            id: ":36:", title: "Exchange Rate",
            short: "Exchange Rate — decimal rate (e.g. 0,9132) used to convert instructed → settled when currencies differ.",
            detail: "Required when the instructed currency (:33B:) differs from the settled currency (:32A:). Decimal rate, comma separator on the wire (e.g. 0,9132 for EUR→USD)."),
        SwiftFieldEntry(
            id: ":50K:", title: "Ordering Customer",
            short: "Ordering Customer — account + name + address of the customer who initiated the payment.",
            detail: "The customer whose account is being debited. Format: optional /account on first line, then name + address (max 4 lines × 35 chars). The :50K: variant is the option used when no BIC is available for the customer."),
        SwiftFieldEntry(
            id: ":52A:", title: "Ordering Institution",
            short: "Ordering Institution — BIC of the bank initiating the transfer (often the sender bank itself).",
            detail: "The BIC of the financial institution from which the payment originates. Omitted when it equals the sender bank's BIC."),
        SwiftFieldEntry(
            id: ":57A:", title: "Account With Institution",
            short: "Account With Institution — BIC of the beneficiary's bank.",
            detail: "The BIC of the bank that holds the beneficiary's account. The A variant means the address is given as a BIC."),
        SwiftFieldEntry(
            id: ":59:", title: "Beneficiary Customer",
            short: "Beneficiary Customer — account + name + address of the customer being paid.",
            detail: "The end customer being credited. Account / IBAN on the first line; then name + address (max 4 lines × 35 chars)."),
        SwiftFieldEntry(
            id: ":70:", title: "Remittance Information",
            short: "Remittance Information — free-form narrative visible to the beneficiary (invoice number, narrative).",
            detail: "Free-form text the beneficiary receives — invoice numbers, contract refs, narrative. Max 4 lines × 35 chars."),
        SwiftFieldEntry(
            id: ":71A:", title: "Details of Charges",
            short: "Details of Charges — OUR (sender pays all), SHA (shared), BEN (beneficiary pays).",
            detail: "Who pays the institution charges. OUR = sender; SHA = shared (sender pays sender-side, beneficiary pays receiver-side); BEN = beneficiary pays everything."),
        SwiftFieldEntry(
            id: ":71F:", title: "Sender's Charges",
            short: "Sender's Charges — fee the ordering bank deducted from the principal.",
            detail: "The institution fee the ordering bank deducted. Currency + decimal amount. Combined with :71G: and :36: to reconcile :33B: (instructed) → :32A: (settled)."),
        SwiftFieldEntry(
            id: ":71G:", title: "Receiver's Charges",
            short: "Receiver's Charges — fee the receiving bank will deduct from what's credited.",
            detail: "The institution fee the beneficiary's bank will deduct before crediting the beneficiary. Currency + decimal amount."),
        SwiftFieldEntry(
            id: ":72:", title: "Sender-to-Receiver Information",
            short: "Sender-to-Receiver Information — institution-only metadata (correspondent routing, instructions).",
            detail: "Free-form text between the two banks only. NOT visible to the beneficiary. Used for /ACC/ correspondent routing, /INS/ instructions. Max 6 lines × 35 chars."),
    ]

    /// Lookup by SWIFT tag — used by view modifiers that want a
    /// tooltip for a given field code.
    static func entry(for tag: String) -> SwiftFieldEntry? {
        entries.first { $0.id == tag }
    }

    /// Short tooltip string for a tag, suitable for `.help()`.
    static func tooltip(for tag: String) -> String {
        entry(for: tag)?.short ?? tag
    }
}

// =================================================================
// SwiftFieldLegendPanel — slide-in side panel listing every code
// with its plain-language explanation. Off by default; the
// operator (or the operator's audience guide) toggles it from the
// composer.
// =================================================================

struct SwiftFieldLegendPanel: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SWIFT FIELD-CODE LEGEND")
                        .font(DesignTokens.labelFont)
                        .tracking(0.6)
                        .foregroundStyle(DesignTokens.textTertiary)
                    Text("Plain-language explanations — for non-banker reviewers")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(DesignTokens.bgTertiary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close legend")
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 14))
            .background(DesignTokens.bgSecondary)
            Divider()
            // Entries
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SwiftFieldLegend.entries) { e in
                        legendRow(e)
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .background(DesignTokens.bgPrimary)
        .overlay(
            Rectangle()
                .strokeBorder(DesignTokens.borderPrimary, lineWidth: 0.5)
        )
    }

    private func legendRow(_ e: SwiftFieldEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(e.tag)
                    .font(DesignTokens.monoFont)
                    .foregroundStyle(DesignTokens.brandNavy)
                Text(e.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
            }
            Text(e.detail)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 14))
    }
}

// =================================================================
// SwiftFieldValidation — inline format checks. Returns nil when
// the field is valid (or empty + non-mandatory); returns a short
// error string to display under the field otherwise.
// =================================================================

enum SwiftFieldValidation {

    /// :20: Sender's Reference — 1..16 chars, alphanumeric +
    /// limited punctuation. Cannot start or end with a slash, and
    /// cannot contain double slashes.
    static func validateReference(_ s: String) -> String? {
        if s.isEmpty { return nil }       // auto-generated if blank
        if s.count > 16 {
            return "Max 16 characters (:20: spec)"
        }
        if s.hasPrefix("/") || s.hasSuffix("/") {
            return "Cannot start or end with '/'"
        }
        if s.contains("//") {
            return "'//' not permitted"
        }
        return nil
    }

    /// :32A: amount — decimal with comma separator. (The full
    /// :32A: format YYMMDD+CCC+amount is composed; the composer
    /// keeps date / currency / amount in separate inputs and
    /// validates the amount portion here.)
    static func validateAmount(_ s: String) -> String? {
        if s.isEmpty { return "Required" }
        // Accept either comma or period as the decimal separator
        // (banker convention varies); normalise + parse.
        let normalised = s.replacingOccurrences(of: ",", with: ".")
        guard Double(normalised) != nil else {
            return "Must be a decimal number"
        }
        // No more than 15 digits before decimal per SWIFT spec.
        let beforeDot = normalised.split(separator: ".").first.map(String.init) ?? normalised
        if beforeDot.count > 15 {
            return "Too many digits (:32A: limit 15 before decimal)"
        }
        return nil
    }

    /// 3-letter ISO 4217 currency code.
    static func validateCurrency(_ s: String) -> String? {
        if s.isEmpty { return "Required" }
        if s.count != 3 { return "Must be 3 letters (ISO 4217)" }
        if !s.allSatisfy({ $0.isLetter && $0.isUppercase || $0.isLetter }) {
            return "Letters only"
        }
        return nil
    }

    /// 8 or 11 char BIC. 8-char base or full 11-char (LT identifier).
    static func validateBIC(_ s: String, required: Bool = false) -> String? {
        if s.isEmpty { return required ? "Required" : nil }
        if s.count != 8 && s.count != 11 {
            return "BIC is 8 or 11 characters"
        }
        if !s.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return "Letters + digits only"
        }
        return nil
    }

    /// :36: FX rate — positive decimal.
    static func validateExchangeRate(_ s: String, required: Bool) -> String? {
        if s.isEmpty { return required ? "Required when currencies differ" : nil }
        let n = s.replacingOccurrences(of: ",", with: ".")
        guard let v = Double(n), v > 0 else {
            return "Must be a positive decimal (e.g. 0,9132)"
        }
        return nil
    }
}
