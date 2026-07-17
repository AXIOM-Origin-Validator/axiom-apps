import Foundation
import SwiftUI
import AxiomSdk

// =================================================================
// WalletClass — UI-side derivation of the FACT-class isolation
// boundary (`docs/AXIOM_DESIGN_FactClassIsolation.md`).
//
// Class is determined by the EXACT match of the email domain to
// `axiom.internal`. Validator infrastructure emails like
// `alpha@axiom` are PUBLIC under this rule — they don't have the
// `.internal` suffix. Protocol addresses (BURN / DEED / FEE / DWP)
// are neither dev nor public; they're exempt from class checking
// because they're not user-class wallets at all.
//
// This file is the SDK-thin layer: the SDK doesn't expose a
// `class_tag` field on `DecodedAddress` — the FFI struct is
// unchanged. The Mac wallet derives class itself in Swift from
// the recipient's address (or the sender wallet's email) and uses
// that to drive UX gates (Send button enable, chip render, DEV
// banner). Consensus enforcement is in Core — see
// `core/logic/src/modes.rs` rule R1.
// =================================================================

enum WalletClass: Equatable {
    /// Public production wallets (default — `@anything-but-axiom.internal`).
    case publicClass
    /// Developer / test wallets (`@axiom.internal` exactly).
    case devClass
    /// Protocol addresses (BURN / DEED / FEE / DWP) — exempt from
    /// class enforcement because they aren't user-class wallets.
    case protocolAddress

    /// Short label used on chips and subtitles.
    var displayName: String {
        switch self {
        case .publicClass:     return "@public"
        case .devClass:        return "@axiom.internal"
        case .protocolAddress: return "protocol"
        }
    }
}

/// Derive a wallet's class from its full address (`email/<addr>`).
///
/// Mirrors the Core-side `validate_transaction` rule R1: the email
/// domain (after the FIRST `@`) must be exactly `axiom.internal`
/// to qualify as developer-class. Anything else — including pure
/// `@axiom` (the validator convention), `@axiom.com`,
/// `@axiom.internal.foo`, or `@myaxiom.internal` — is public-class.
///
/// Protocol addresses (BURN/, DEED/, FEE/, DWP/ prefixes) are
/// `.protocolAddress` and bypass class enforcement.
func walletClass(of walletId: String) -> WalletClass {
    if walletId.hasPrefix("BURN/")
        || walletId.hasPrefix("DEED/")
        || walletId.hasPrefix("FEE/")
        || walletId.hasPrefix("DWP/") {
        return .protocolAddress
    }
    let clean = stripWalletSuffixes(walletId)
    let email = clean.split(separator: "/", maxSplits: 1)
        .first.map(String.init) ?? ""
    return walletClass(ofEmail: email)
}

/// Derive a wallet's class from its bare email address — useful
/// when the caller already has `wallet.email()` and doesn't need
/// to round-trip through the address-bag form.
func walletClass(ofEmail email: String) -> WalletClass {
    guard let atIdx = email.firstIndex(of: "@") else {
        return .publicClass
    }
    let domain = email[email.index(after: atIdx)...].lowercased()
    return domain == "axiom.internal" ? .devClass : .publicClass
}

/// Convenience predicate.
func isDevWallet(_ walletId: String) -> Bool {
    walletClass(of: walletId) == .devClass
}

/// Strip optional encryption suffix (`-P` / `-G`) and email-change
/// suffix (`-XX` two hex chars) from a wallet address. Mirrors
/// Core's strip_* helpers so the client-side class derivation sees
/// the same address shape Core does at `validate_transaction`.
private func stripWalletSuffixes(_ walletId: String) -> String {
    var s = walletId
    if s.hasSuffix("-P") || s.hasSuffix("-G") {
        s.removeLast(2)
    }
    // -XX two-hex-char email-change suffix.
    if s.count > 3 {
        let last3 = s.suffix(3)
        if last3.first == "-" {
            let xx = last3.dropFirst()
            if xx.count == 2 && xx.allSatisfy({ $0.isHexDigit }) {
                s.removeLast(3)
            }
        }
    }
    return s
}

// =================================================================
// WalletClassChip — small SwiftUI capsule rendered next to a
// wallet address. Same visual style as the validator-hints carrier
// chips, scoped to wallet class.
// =================================================================
struct WalletClassChip: View {
    let cls: WalletClass

    var body: some View {
        Text(cls.displayName)
            .font(DesignTokens.Typography.chip)
            .tracking(0.3)
            .foregroundStyle(fg)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(bg)
            .clipShape(Capsule())
    }

    private var fg: Color {
        switch cls {
        case .publicClass:     return DesignTokens.statusCleanFg
        case .devClass:        return DesignTokens.statusScarredFg
        case .protocolAddress: return DesignTokens.textTertiary
        }
    }

    private var bg: Color {
        switch cls {
        case .publicClass:     return DesignTokens.statusCleanFg.opacity(0.14)
        case .devClass:        return DesignTokens.statusScarredFg.opacity(0.14)
        case .protocolAddress: return DesignTokens.bgTertiary
        }
    }
}

// =================================================================
// Wallet-aware balance formatting
//
// Mirror of `formatAxcOnly` (in MainAppView.swift) but with a
// class-aware unit string: dev wallets show "dev-AXC", public
// wallets show "AXC". Used on balance displays tied to a specific
// wallet (fromCard, post-send summary, post-claim summary) so the
// unit unambiguously reflects which subgraph the balance is in.
// =================================================================

/// Unit label for the given wallet — `"dev-AXC"` for @axiom.internal
/// wallets, `"AXC"` for everything else (including `nil`).
func axcUnit(for wallet: AxiomWallet?) -> String {
    guard let w = wallet else { return "AXC" }
    return walletClass(ofEmail: w.email()) == .devClass ? "dev-AXC" : "AXC"
}

/// Wallet-aware AXC formatter: same numeric format as
/// `formatAxcOnly` but with the unit string switched to "dev-AXC"
/// for @axiom.internal wallets. Use on balance displays where the
/// caller has the wallet in hand and wants the unit to reflect
/// class (fromCard, claim result, broadcast result).
func formatAxcForWallet(_ atoms: UInt64, wallet: AxiomWallet?) -> String {
    let axcTimes10000 = atoms / 1_000_000
    let whole = axcTimes10000 / 10_000
    let frac = axcTimes10000 % 10_000
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    let wholeStr = formatter.string(from: NSNumber(value: whole)) ?? "\(whole)"
    return "\(wholeStr).\(String(format: "%04d", frac)) \(axcUnit(for: wallet))"
}
