import SwiftUI
import AppKit

/// Chrome translucency policy — the ONE gate between the app and any
/// material/glass effect.
///
/// Rules (see DesignTokens.swift header):
///  - Glass/translucency is an accent on chrome (sidebar, toolbars,
///    bars, sheet headers) — never on content surfaces, and never
///    behind money amounts, addresses, or cheque bundle states.
///  - The user preference (Settings → Appearance) mirrors the
///    system's transparency slider and defaults to the LOW end —
///    this is a wallet; readability beats spectacle.
///  - The OS-level Reduce Transparency setting wins unconditionally.
enum ChromeTranslucency: Int, CaseIterable, Identifiable {
    case off = 0
    case low = 1      // default
    case standard = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return String(localized: "Off")
        case .low: return String(localized: "Low")
        case .standard: return String(localized: "Standard")
        }
    }

    static let storageKey = "axm.chrome.translucency"

    /// Current effective level: stored preference, overridden to
    /// `.off` when the system asks for reduced transparency.
    static var effective: ChromeTranslucency {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            return .off
        }
        let raw = UserDefaults.standard.object(forKey: storageKey) as? Int
        return ChromeTranslucency(rawValue: raw ?? ChromeTranslucency.low.rawValue) ?? .low
    }
}

/// Background for chrome surfaces (sidebar, bars, sheet headers).
/// Resolves to a solid token color when translucency is off, a
/// subtle material at LOW, and the regular bar material at STANDARD.
///
/// Usage: `.background(ChromeSurface())` — never on content cards.
struct ChromeSurface: View {
    /// Re-evaluated on each render; views observing the preference
    /// via @AppStorage(ChromeTranslucency.storageKey) re-render on
    /// change.
    var body: some View {
        switch ChromeTranslucency.effective {
        case .off:
            DesignTokens.bgChrome
        case .low:
            // Thicker material = less transparency = more legible.
            Rectangle().fill(.thickMaterial)
        case .standard:
            Rectangle().fill(.bar)
        }
    }
}
