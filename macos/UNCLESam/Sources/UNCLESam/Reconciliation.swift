import Foundation

// =================================================================
// Reconciliation — settled-vs-instructed amount accounting.
//
// SWIFT's payment messages carry two amounts:
//
//   :32A: Settled amount   — what is actually transferred between
//                            banks at settlement.
//   :33B: Instructed amount — what the ordering customer asked
//                            their bank to send.
//
// When these differ, the gap is explained by:
//   :71F: Sender's charges    — fee the ordering bank deducts.
//   :71G: Receiver's charges  — fee the receiving bank deducts.
//   :36:  Exchange rate       — when 32A.ccy != 33B.ccy, the rate
//                              used to convert.
//
// A real banker reads the message and immediately reconciles
// these. UNCLE SAM surfaces the same reconciliation explicitly
// as an inline display line in the Create form and Message
// Detail view so non-bankers reviewing the demo can see that
// the difference is accounted for, not lost.
//
// The math (sender-charges case, OUR):
//   instructed_in_settled_ccy = instructed * fx_rate
//   settled = instructed_in_settled_ccy − sender_charges
//
// We don't enforce the equation — operators may enter values
// that don't balance for reasons outside this model (intermediate
// correspondent fees, rounding policy, etc.). The reconciliation
// line is informational only.
// =================================================================

/// One reconciliation result — what was computed and what was
/// expected. Used to render the inline display line.
struct ReconciliationDisplay {
    /// The full one-line summary, ready to display.
    let line: String
    /// True when the computed-settled matches the entered-settled
    /// within rounding tolerance — used to colour the line green
    /// (balanced) or amber (mismatch worth a second look).
    let balanced: Bool
    /// Any sanity-check warning that doesn't fail the line but is
    /// worth showing (e.g. "FX rate required when currencies
    /// differ").
    let warning: String?
}

enum Reconciliation {

    /// Build the inline summary for the current draft. Returns
    /// nil when there's nothing to reconcile (no amounts entered).
    static func summary(for d: WireDraft) -> ReconciliationDisplay? {
        guard let settled = parseAmount(d.settlementAmount),
              !d.settlementCurrency.isEmpty else { return nil }

        let instructed = parseAmount(d.instructedAmount)
        let senderCharges = parseAmount(d.senderCharges) ?? 0
        let receiverCharges = parseAmount(d.receiverCharges) ?? 0
        let fxRate = parseAmount(d.exchangeRate)

        let sameCurrency = d.instructedCurrency == d.settlementCurrency

        // Case 1: same currency, no instructed amount entered → no
        // gap to show. Just display the settled amount.
        if instructed == nil || instructed == settled,
           sameCurrency,
           senderCharges == 0, receiverCharges == 0 {
            return ReconciliationDisplay(
                line: "Settled \(fmtAmount(settled)) \(d.settlementCurrency)",
                balanced: true, warning: nil
            )
        }

        // Case 2: there's an instructed amount that differs OR
        // there are charges OR there's an FX rate.
        let inst = instructed ?? settled
        let convertedInstructed: Double
        var fxPart = ""
        if !sameCurrency {
            if let r = fxRate {
                convertedInstructed = inst * r
                fxPart = " × FX \(fmtRate(r))"
            } else {
                convertedInstructed = inst
                fxPart = " × FX ?"
            }
        } else {
            convertedInstructed = inst
        }

        let computed = convertedInstructed - senderCharges - receiverCharges
        let balanced = abs(computed - settled) < 0.005   // half-cent

        // Compose the line.
        var line = "Instructed \(fmtAmount(inst)) \(d.instructedCurrency)"
        if !fxPart.isEmpty {
            line += fxPart
        }
        if senderCharges > 0 {
            line += " − sender chgs \(fmtAmount(senderCharges)) \(d.chargesCurrency)"
        }
        if receiverCharges > 0 {
            line += " − receiver chgs \(fmtAmount(receiverCharges)) \(d.chargesCurrency)"
        }
        line += " → Settled \(fmtAmount(settled)) \(d.settlementCurrency)"
        if !balanced {
            line += " (Δ \(fmtAmount(computed - settled)))"
        }

        var warning: String? = nil
        if !sameCurrency && fxRate == nil {
            warning = "Exchange rate (:36:) required when instructed and settled currencies differ."
        }

        return ReconciliationDisplay(line: line, balanced: balanced, warning: warning)
    }

    /// Parse a SWIFT-style decimal amount. SWIFT uses comma as
    /// decimal separator on the wire ("1000,00") but operators
    /// commonly type period ("1000.00") — accept both.
    private static func parseAmount(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        let normalised = trimmed
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
        return Double(normalised)
    }

    /// Format for display — comma decimal separator per SWIFT
    /// convention, two decimal places (typical for fiat-style
    /// amounts; AXC inherits the same formatting).
    private static func fmtAmount(_ v: Double) -> String {
        let fmt = NumberFormatter()
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        fmt.groupingSeparator = ","
        fmt.decimalSeparator = "."
        return fmt.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// Format an FX rate — 4–6 decimal places typical for
    /// inter-bank rates.
    private static func fmtRate(_ v: Double) -> String {
        let fmt = NumberFormatter()
        fmt.minimumFractionDigits = 4
        fmt.maximumFractionDigits = 6
        fmt.decimalSeparator = "."
        return fmt.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}
