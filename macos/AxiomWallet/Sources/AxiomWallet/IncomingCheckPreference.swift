import SwiftUI
import AxiomSdk

// ===========================================================================
// IncomingCheckPreference — KI#34 WI2/WI5: per-wallet "incoming-payment check
// mode" picker.
//
// When you RECEIVE money, the wallet checks the cheque against a few Nabla
// nodes. WHICH nodes it asks is a per-wallet receiver CHOICE. It's safe to
// make it a choice because a double-spend is ALWAYS eventually caught with
// zero damage to the economy — the only thing at stake is that one receiver
// could briefly accept bad money (like a bad cheque). So: important wallet →
// more caution; pocket-money wallet → faster default. No node is "special";
// the trust is the user's own.
//
// Maps 1:1 to the SDK FFI `NablaSelectionMode` (Default / Secure / Random).
// The SDK setting is PROCESS-GLOBAL (mirrors carrier_preference), so the app
// stores the mode per wallet and pushes it right before any incoming-payment
// check (the redeem / verify_cheque path) — exactly like CarrierPreferences.
//
// The "previous Nabla" memory used by Secure lives in the SDK picker, not the
// wallet — so there is nothing for the app to persist about which nodes were
// used. The app persists only the chosen MODE, per wallet, in UserDefaults
// (not wallet.cbor — it's an app preference, not wallet state).
// ===========================================================================

/// How the receiver picks the Nablas it checks an incoming payment with.
/// App-level mirror of the SDK's `NablaSelectionMode` — own case names
/// (the FFI's `.default` is a Swift keyword) + the UX copy.
enum IncomingCheckMode: String, Codable, CaseIterable, Identifiable {
    /// 1 from the sender's hint + 2 random. Fast. (FFI `.default`)
    case standard
    /// 1 of YOUR OWN previously-used Nablas + 2 random; sender hint ignored.
    case secure
    /// 3 fully random.
    case random

    var id: String { rawValue }

    /// Default mode for a wallet that has never been configured.
    static let fallback: IncomingCheckMode = .standard

    var displayName: String {
        switch self {
        case .standard: return "Default"
        case .secure:   return "Secure"
        case .random:   return "Random"
        }
    }

    /// One-line, plain-language explanation per option (per the KI#34 UX).
    var subtitle: String {
        switch self {
        case .standard:
            return "1 from the sender's suggestion + 2 random. Fast — fine for everyday / pocket-money wallets."
        case .secure:
            return "1 of your own previously-used nodes + 2 random; the sender's suggestion is ignored. A bit slower; best for important wallets."
        case .random:
            return "3 fully random nodes — trust nothing the sender supplied."
        }
    }

    /// Map to the SDK FFI enum.
    var ffi: NablaSelectionMode {
        switch self {
        case .standard: return .default
        case .secure:   return .secure
        case .random:   return .random
        }
    }
}

/// Persisted per-wallet incoming-check mode + SDK push helpers. Same shape
/// as `CarrierPreferences` (UserDefaults keyed by wallet address, push to the
/// process-global SDK runtime before the op).
enum IncomingCheckPreference {
    private static let keyFmt = "nabla_selection_mode.%@"

    private static func key(for w: AxiomWallet) -> String {
        String(format: keyFmt, (try? w.address()) ?? w.email())
    }

    /// Load a wallet's mode, or `.fallback` if never set.
    static func load(for w: AxiomWallet) -> IncomingCheckMode {
        let key = key(for: w)
        guard let raw = UserDefaults.standard.string(forKey: key),
              let mode = IncomingCheckMode(rawValue: raw) else {
            return .fallback
        }
        return mode
    }

    /// Persist per-wallet, then push to the SDK so the next check uses it.
    static func save(_ mode: IncomingCheckMode, for w: AxiomWallet) {
        UserDefaults.standard.set(mode.rawValue, forKey: key(for: w))
        push(mode)
    }

    /// Push a mode into the process-global SDK runtime.
    static func push(_ mode: IncomingCheckMode) {
        sdkSetNablaSelectionMode(mode: mode.ffi)
    }

    /// Set the SDK mode for a SPECIFIC wallet right before driving an op on
    /// it (the set-before-op pattern — call from the redeem / verify path).
    static func applyToSdk(for w: AxiomWallet) {
        push(load(for: w))
    }

    /// Push the active wallet's mode (launch + wallet/mode switch baseline).
    /// No wallet active → reset to the SDK default.
    static func pushActiveToSdk(_ session: AppSession) {
        if let w = session.activeWallet {
            push(load(for: w))
        } else {
            push(.fallback)
        }
    }
}

// =================================================================
// Picker view — embedded in Settings → Network.
// =================================================================
struct IncomingCheckPreferenceView: View {
    @EnvironmentObject private var session: AppSession

    @State private var mode: IncomingCheckMode = .fallback

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("When you receive money, the wallet checks the cheque against a few network nodes. Which nodes it asks is your choice — a double-spend is always caught eventually with no harm to the economy, so the only thing at stake is whether this one wallet could briefly accept a bad cheque. Pick more caution for important wallets, the fast default for pocket money.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $mode) {
                ForEach(IncomingCheckMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(session.activeWallet == nil)
            .onChange(of: mode) { newMode in
                guard let w = session.activeWallet else { return }
                IncomingCheckPreference.save(newMode, for: w)
            }

            // Explanation for the currently-selected option.
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                Image(systemName: mode == .standard ? "bolt.fill"
                                : mode == .secure ? "lock.shield.fill"
                                : "dice.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(mode == .standard ? DesignTokens.textTertiary
                                   : mode == .secure ? DesignTokens.statusCleanFg
                                   : DesignTokens.textSecondary)
                Text(mode.subtitle)
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if session.activeWallet == nil {
                Text("Unlock a wallet to configure this.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
        .onAppear(perform: load)
        .onChange(of: session.activePairIndex) { _ in load() }
        .onChange(of: session.activeMode) { _ in load() }
    }

    private func load() {
        guard let w = session.activeWallet else { mode = .fallback; return }
        mode = IncomingCheckPreference.load(for: w)
    }
}
