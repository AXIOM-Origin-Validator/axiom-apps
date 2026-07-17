import SwiftUI

// =================================================================
// SwiftOnlyTag + AxiomAnchorTag — visible markers that label
// composer fields by which rail they actually drive.
//
// UNCLE SAM's design contract: AXIOM is the rail (value movement,
// ~3 min cryptographic finality), the SWIFT envelope is a parallel
// record for the bank's existing pipeline. Fields that ONLY shape
// the SWIFT message — correspondents, cover messages, cancellation
// references, regulatory metadata — must be visibly tagged so an
// operator (and any reviewer) sees at a glance what each field
// actually does.
//
// Two tags:
//   • SwiftOnlyTag — "informational on AXIOM; emitted into the
//                    SWIFT envelope only".
//   • AxiomAnchorTag — "drives the AXIOM rail (settled amount,
//                       beneficiary wallet, etc.)".
//
// Hover any tag for a one-line explanation.
// =================================================================

struct SwiftOnlyTag: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "doc.text")
                .font(.system(size: 8))
            Text("SWIFT-only")
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.3)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .foregroundStyle(DesignTokens.textSecondary)
        .background(DesignTokens.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(DesignTokens.borderPrimary, lineWidth: 0.5)
        )
        .help("Informational on AXIOM — emitted into the SWIFT envelope only. Does not affect the AXIOM rail.")
    }
}

struct AxiomAnchorTag: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "link")
                .font(.system(size: 8))
            Text("AXIOM-anchored")
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.3)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .foregroundStyle(DesignTokens.brandNavy)
        .background(DesignTokens.brandNavySoft)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(DesignTokens.brandNavy.opacity(0.3), lineWidth: 0.5)
        )
        .help("Drives the AXIOM rail — settled value, witnesses, FACT chain. Also emitted into the SWIFT envelope.")
    }
}

// =================================================================
// NonCancellableBanner — permanent UI reminder that AXIOM TX is
// irreversible from witness finality (~3 min after submit). Sits
// above the cancellation/recall field in the composer so the
// operator can never claim ignorance.
// =================================================================

struct NonCancellableBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.statusRejectedFg)
            VStack(alignment: .leading, spacing: 2) {
                Text("AXIOM SETTLEMENT IS IRREVERSIBLE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                Text("Once k validators sign (~3 min after submit) the AXC has moved and cannot be recalled. Any cancellation reference below populates the SWIFT envelope only — it does NOT reverse the AXIOM transaction.")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(DesignTokens.statusRejectedBg)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(DesignTokens.statusRejectedFg.opacity(0.3),
                              lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// =================================================================
// Sanctions / OFAC pre-flight model + stub screener.
//
// Real screening is bank-side (Accuity, LexisNexis Bridger,
// Refinitiv, FircoSoft) against OFAC SDN + UN + EU + UK HMT lists.
// The bank's screening engine is the gold source; UNCLE SAM only
// shows the hook point and the verdict so the operator + checker
// see the screen happened.
//
// Stub here returns a deterministic verdict based on simple name
// heuristics so the demo can show CLEAR / HIT / REVIEW outcomes.
// =================================================================

enum SanctionsResult: String, Codable {
    case clear   = "CLEAR"
    case review  = "REVIEW"
    case hit     = "HIT"

    var fg: Color {
        switch self {
        case .clear:  return DesignTokens.statusSettledFg
        case .review: return DesignTokens.statusPendingFg
        case .hit:    return DesignTokens.statusRejectedFg
        }
    }
    var bg: Color {
        switch self {
        case .clear:  return DesignTokens.statusSettledBg
        case .review: return DesignTokens.statusPendingBg
        case .hit:    return DesignTokens.statusRejectedBg
        }
    }
    var icon: String {
        switch self {
        case .clear:  return "checkmark.shield.fill"
        case .review: return "questionmark.circle.fill"
        case .hit:    return "xmark.shield.fill"
        }
    }
    var rationale: String {
        switch self {
        case .clear:  return "No matches against OFAC SDN, UN, EU, UK HMT lists."
        case .review: return "Soft match — name/address fuzzy match below auto-clear threshold. Manual review required."
        case .hit:    return "HARD MATCH against sanctions list. Payment must be frozen and reported."
        }
    }
}

enum SanctionsScreener {

    /// Stub screener — deterministic, name-heuristic based. Real
    /// implementations call out to the bank's screening engine.
    /// Returns CLEAR for normal names; REVIEW when the
    /// beneficiary name contains the word "MISCONFIGURED" (one of
    /// the seed records); HIT when a name contains "BLOCKED" or
    /// "SANCTIONED" — so the demo can show all three verdicts
    /// when the operator tries them.
    static func screen(orderingName: String,
                       beneficiaryName: String,
                       beneficiaryBIC: String) -> SanctionsResult {
        let allText = "\(orderingName) \(beneficiaryName) \(beneficiaryBIC)".uppercased()
        if allText.contains("BLOCKED") || allText.contains("SANCTIONED") {
            return .hit
        }
        if allText.contains("MISCONFIGURED") || allText.contains("UNKNOWN") {
            return .review
        }
        return .clear
    }
}

/// Small chip used in queue / detail to display a sanctions verdict.
struct SanctionsChip: View {
    let result: SanctionsResult
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: result.icon)
                .font(.system(size: 9))
            Text("SCRN \(result.rawValue)")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.3)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(result.fg)
        .background(result.bg)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .help("Sanctions / OFAC pre-flight: \(result.rationale)")
    }
}
