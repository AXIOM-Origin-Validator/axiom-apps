import SwiftUI

/// Design-token layer for AxiomKiddo — mirrors the structure of
/// AxiomWallet's DesignTokens (same scale names, same discipline) with
/// a warmer, friendlier palette. Trustworthy first, friendly second:
/// soft warm neutrals and ONE accent, never garish.
///
/// Rules:
///  - No `Color(red:...)`, raw `.green`/`.orange`, or
///    `.system(size:)` literals at call sites — use these tokens.
///  - One meaning per color: status colors come from `WorkerStatusStyle`
///    only (green = running, amber = needs attention, gray = idle,
///    blue = activity in flight). Never reuse a status color for
///    decoration.
///  - Minimum text size for information is 11pt (`caption`); `micro`
///    is for the version string only.
enum KiddoTokens {
    // ── Brand ──────────────────────────────────────────────────────
    /// Warm honey-amber accent — friendly, still serious.
    static let accent       = Color(red: 0xC2 / 255, green: 0x6A / 255, blue: 0x1D / 255)
    static let accentSoft   = Color(red: 0xFB / 255, green: 0xEF / 255, blue: 0xE2 / 255)

    // ── Backgrounds (warm neutrals) ────────────────────────────────
    static let bgPrimary    = Color(red: 0xFF / 255, green: 0xFD / 255, blue: 0xFA / 255)
    static let bgSecondary  = Color(red: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEF / 255)
    static let bgTertiary   = Color(red: 0xEF / 255, green: 0xEB / 255, blue: 0xE4 / 255)

    // ── Text ───────────────────────────────────────────────────────
    static let textPrimary   = Color(red: 0x20 / 255, green: 0x1A / 255, blue: 0x12 / 255)
    static let textSecondary = Color(red: 0x5C / 255, green: 0x54 / 255, blue: 0x48 / 255)
    static let textTertiary  = Color(red: 0x8E / 255, green: 0x86 / 255, blue: 0x7A / 255)

    // ── Borders ────────────────────────────────────────────────────
    static let borderTertiary  = Color.black.opacity(0.08)
    static let borderSecondary = Color.black.opacity(0.14)
    static let hairline: CGFloat = 0.5

    // ── Status (one meaning per color — see WorkerStatusStyle) ─────
    static let statusRunningFg   = Color(red: 0x1E / 255, green: 0x70 / 255, blue: 0x44 / 255)
    static let statusRunningBg   = Color(red: 0xE4 / 255, green: 0xF2 / 255, blue: 0xE9 / 255)
    static let statusAttentionFg = Color(red: 0x9A / 255, green: 0x59 / 255, blue: 0x0B / 255)
    static let statusAttentionBg = Color(red: 0xFA / 255, green: 0xEF / 255, blue: 0xDC / 255)
    static let statusBusyFg      = Color(red: 0x2A / 255, green: 0x4D / 255, blue: 0x8F / 255)
    static let statusBusyBg      = Color(red: 0xE4 / 255, green: 0xEC / 255, blue: 0xFA / 255)
    static let statusIdleFg      = textTertiary
    static let statusIdleBg      = bgTertiary

    // ── Spacing scale (4pt grid, same names as AxiomWallet) ────────
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
    }

    // ── Corner radii (softer than the Wallet's) ────────────────────
    enum Radius {
        /// 6 — chips, status pills
        static let chip: CGFloat = 6
        /// 8 — buttons, fields
        static let control: CGFloat = 8
        /// 12 — cards, panels
        static let card: CGFloat = 12
    }

    // ── Control sizing ─────────────────────────────────────────────
    enum Size {
        /// Status indicator dot — large enough to read at a glance.
        static let statusDot: CGFloat = 10
        /// Minimum hit target for small inline buttons.
        static let minHit: CGFloat = 24
    }

    // ── Typography scale ───────────────────────────────────────────
    enum Typography {
        /// 18 semibold — splash / window titles
        static let title = Font.system(size: 18, weight: .semibold)
        /// 13 semibold — section/card headings
        static let heading = Font.system(size: 13, weight: .semibold)
        /// 13 regular — primary rows, body copy
        static let body = Font.system(size: 13)
        /// 12 medium — control labels
        static let labelStrong = Font.system(size: 12, weight: .medium)
        /// 12 regular — secondary copy
        static let label = Font.system(size: 12)
        /// 11 regular — captions/help (minimum for information)
        static let caption = Font.system(size: 11)
        /// 9 monospaced — version string ONLY
        static let micro = Font.system(size: 9, design: .monospaced)
        /// 12 monospaced — emails, hosts, paths, counters
        static let mono = Font.system(size: 12, design: .monospaced)
        /// 11 monospaced — dense status counters
        static let monoSmall = Font.system(size: 11, design: .monospaced)
    }

    // ── Motion ─────────────────────────────────────────────────────
    enum Motion {
        static let standardDuration: Double = 0.18
        static var reduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        static func standard() -> Animation? {
            reduceMotion ? nil : .easeInOut(duration: standardDuration)
        }
    }
}

/// Worker / account status → consistent color + label + SF Symbol.
/// The ONE mapping for every status dot in the menu bar and Settings;
/// status is never conveyed by color alone (symbol + accessibility
/// label travel with it).
enum WorkerStatusStyle {
    /// Worker running, no errors.
    case running
    /// Last operation failed — needs a look.
    case attention
    /// Work queued / in flight.
    case busy
    /// Not running (disabled or not yet started).
    case idle

    var fg: Color {
        switch self {
        case .running: return KiddoTokens.statusRunningFg
        case .attention: return KiddoTokens.statusAttentionFg
        case .busy: return KiddoTokens.statusBusyFg
        case .idle: return KiddoTokens.statusIdleFg
        }
    }

    var bg: Color {
        switch self {
        case .running: return KiddoTokens.statusRunningBg
        case .attention: return KiddoTokens.statusAttentionBg
        case .busy: return KiddoTokens.statusBusyBg
        case .idle: return KiddoTokens.statusIdleBg
        }
    }

    var symbol: String {
        switch self {
        case .running: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .busy: return "arrow.triangle.2.circlepath"
        case .idle: return "pause.circle"
        }
    }

    /// VoiceOver / tooltip text.
    var label: String {
        switch self {
        case .running: return String(localized: "Running")
        case .attention: return String(localized: "Needs attention")
        case .busy: return String(localized: "Working")
        case .idle: return String(localized: "Not running")
        }
    }
}
