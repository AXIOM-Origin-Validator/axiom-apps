import Foundation
import SwiftUI
import AxiomSdk

// =================================================================
// Institution accounts — multi-treasury model.
//
// Real banks don't push SWIFT messages from a single funded
// position. Treasury runs the inter-bank settlements; FX desk runs
// the currency book; each branch has its own AXC balance for the
// customer payments it originates; the settlement account vs
// operating account split lives at every BIS-regulated institution.
// UNCLE SAM mirrors that — one InstitutionAccount per funded
// position, the operator picks which one to send FROM per wire.
//
// Architecturally each account is a distinct AxiomWallet (own
// keypair, own AXC balance, own tier address). There's no new SDK
// surface — the bank just opens N wallets at launch instead of one.
// =================================================================

// =================================================================
// AccountColor — admin-picked accent that tints the chrome strip
// when the account is active. Lets a banker glance at the top bar
// and instantly know which funded position they're operating from
// (Treasury vs FX Desk vs Branch HK-01 etc.) without reading any
// labels.
//
// Palette is a deliberately conservative institutional set —
// banks-and-treasury greens / navies / wines / slates rather than
// fintech jewel tones. Each colour is chosen to read well as a
// chrome-strip tint behind white text.
// =================================================================

enum AccountColor: String, CaseIterable, Codable, Identifiable {
    case navy        = "navy"
    case burgundy    = "burgundy"
    case forest      = "forest"
    case slate       = "slate"
    case royal       = "royal"
    case charcoal    = "charcoal"
    case olive       = "olive"
    case plum        = "plum"
    case teal        = "teal"
    case ochre       = "ochre"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .navy:     return "Navy"
        case .burgundy: return "Burgundy"
        case .forest:   return "Forest"
        case .slate:    return "Slate"
        case .royal:    return "Royal"
        case .charcoal: return "Charcoal"
        case .olive:    return "Olive"
        case .plum:     return "Plum"
        case .teal:     return "Teal"
        case .ochre:    return "Ochre"
        }
    }

    /// The chrome-strip tint colour. Reads well behind white text.
    var color: Color {
        switch self {
        case .navy:     return Color(red: 0.10, green: 0.18, blue: 0.36)
        case .burgundy: return Color(red: 0.36, green: 0.10, blue: 0.10)
        case .forest:   return Color(red: 0.10, green: 0.32, blue: 0.18)
        case .slate:    return Color(red: 0.28, green: 0.34, blue: 0.40)
        case .royal:    return Color(red: 0.10, green: 0.24, blue: 0.55)
        case .charcoal: return Color(red: 0.18, green: 0.20, blue: 0.24)
        case .olive:    return Color(red: 0.32, green: 0.32, blue: 0.14)
        case .plum:     return Color(red: 0.30, green: 0.16, blue: 0.34)
        case .teal:     return Color(red: 0.08, green: 0.34, blue: 0.38)
        case .ochre:    return Color(red: 0.48, green: 0.30, blue: 0.08)
        }
    }
}

enum AccountPurpose: String, CaseIterable, Codable, Identifiable {
    case treasury     = "Treasury"
    case fx           = "FX Desk"
    case branch       = "Branch"
    case customerPool = "Customer Pool"
    case settlement   = "Settlement"
    case operating    = "Operating"
    case nostro       = "Nostro / Vostro"
    var id: String { rawValue }

    var label: String { rawValue }
    /// Banker tooltip — what kind of wires this account funds.
    var explanation: String {
        switch self {
        case .treasury:
            return "Inter-bank settlement, central money flows, large-value payments to correspondents."
        case .fx:
            return "FX trading book — currency conversion + counterparty settlement on FX deals."
        case .branch:
            return "Branch-originated customer payments. Each branch has its own funded position + sub-BIC."
        case .customerPool:
            return "Pooled customer-segregated funds. Used when customer accounts are commingled at the bank level."
        case .settlement:
            return "Dedicated settlement leg — used by clearing-house counter-party payments."
        case .operating:
            return "Bank's own operating expenses (fees, vendor payments, internal cost centres)."
        case .nostro:
            return "Account this bank holds at a correspondent (nostro) or that a counterparty holds with this bank (vostro)."
        }
    }

    var icon: String {
        switch self {
        case .treasury:     return "building.columns.fill"
        case .fx:           return "arrow.left.arrow.right"
        case .branch:       return "building.2"
        case .customerPool: return "person.3"
        case .settlement:   return "checkmark.seal"
        case .operating:    return "gear"
        case .nostro:       return "arrow.triangle.swap"
        }
    }
}

/// Persisted metadata for one institutional account. Encoded as JSON
/// inside `@AppStorage("unclesam.accounts")` so the array survives
/// re-launches. The live AxiomWallet handle is held separately on
/// `InstitutionSession` — opened from `<appDir>/wallets/<pairName>-normal`
/// at launch via `tryOpenExistingAccounts`.
struct AccountConfig: Identifiable, Codable, Hashable {
    var id: UUID
    var displayName: String
    var purpose: AccountPurpose
    /// Optional sub-BIC (e.g. branch BIC differing from HQ BIC).
    /// Empty = use the institution-level BIC from
    /// `InstitutionSession.bankBIC`.
    var subBIC: String
    /// Email half of the AXIOM wallet_id. Must be unique across
    /// accounts on this install — drives the wallet directory name
    /// + the SDK's `createWalletPair(email:)` call.
    var walletEmail: String
    /// Directory name used on disk:
    /// `<appDir>/wallets/<pairName>-normal/wallet.axiom`. Derived
    /// from a slug of the displayName; never mutated after create
    /// because we don't move wallet files around.
    var pairName: String
    var createdAt: Date
    /// Operator-picked accent that tints the chrome strip when
    /// this account is active. Default navy keeps existing
    /// installs looking like the previous fixed-navy chrome.
    var color: AccountColor = .navy

    init(displayName: String, purpose: AccountPurpose,
         subBIC: String, walletEmail: String, pairName: String,
         color: AccountColor = .navy) {
        self.id = UUID()
        self.displayName = displayName
        self.purpose = purpose
        self.subBIC = subBIC
        self.walletEmail = walletEmail
        self.pairName = pairName
        self.createdAt = Date()
        self.color = color
    }

    /// Sub-BIC if set, otherwise the institution-level BIC (passed
    /// in from `InstitutionSession.bankBIC`).
    func effectiveBIC(fallback institutionBIC: String) -> String {
        subBIC.isEmpty ? institutionBIC : subBIC
    }
}

/// Live runtime state for one open account. Combines the persisted
/// AccountConfig with the in-memory AxiomWallet handle + cached
/// balance/address. Not Codable — only AccountConfig persists.
@MainActor
final class InstitutionAccount: ObservableObject, Identifiable {
    let config: AccountConfig
    var id: UUID { config.id }

    /// The open AxiomWallet for this account, nil until opened.
    @Published var wallet: AxiomWallet? = nil
    /// Tier address extracted from `wallet.allAddresses()` matching
    /// the institution-level bankTier. Refreshed when wallet opens.
    @Published var tierAddress: String = ""
    /// Cached balance in atoms. Refreshed after every send via
    /// `refreshBalance()`.
    @Published var balanceAtoms: UInt64 = 0
    /// Last open / send / refresh error for this account.
    @Published var lastError: String? = nil

    init(config: AccountConfig) {
        self.config = config
    }

    /// AXC display string for the cached balance.
    var balanceDisplay: String {
        formatAxc(atoms: balanceAtoms)
    }

    /// Adopt an opened AxiomWallet — pick out the bank-tier
    /// address that matches the institution's locked tier.
    func adoptOpenedWallet(_ w: AxiomWallet, bankTier: BankTier) {
        wallet = w
        balanceAtoms = w.balance()
        let chosen = bankTier.sdkDisplayName
        if let addrs = try? w.allAddresses(),
           let match = addrs.first(where: { $0.displayName == chosen }) {
            tierAddress = match.address
        } else {
            tierAddress = (try? w.address()) ?? ""
        }
        lastError = nil
    }

    func refreshBalance() {
        if let w = wallet { balanceAtoms = w.balance() }
    }
}

// =================================================================
// CensoredBalance — renders an AXC balance when the current
// operator role permits it (Treasurer / Auditor / makerChecker
// demo god mode), or a "— — —" placeholder otherwise. Same width
// either way so the layout doesn't reflow when a role swap
// toggles visibility — a column that suddenly appears would look
// like a calculation just happened, which is exactly the kind of
// banker mistake the censorship is meant to prevent.
// =================================================================

struct CensoredBalance: View {
    let atoms: UInt64
    let canView: Bool
    var font: Font = DesignTokens.monoFont

    var body: some View {
        if canView {
            Text(formatAxc(atoms: atoms))
                .font(font)
        } else {
            Text("— — — AXC")
                .font(font)
                .foregroundStyle(DesignTokens.textTertiary)
                .help("Balance is hidden for your role. Treasurer / Auditor can see account positions.")
        }
    }
}
