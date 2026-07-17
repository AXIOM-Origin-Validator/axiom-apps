import SwiftUI

/// Single design-token layer for AxiomWallet.
///
/// Mirrors the design discipline from `docs/AXIOM_DESIGN_Naming.md`
/// and the macOS Golden Gate direction: readability and consistency
/// over spectacle. Hairlines, tabular numerals, sentence case, one
/// disciplined accent, color reserved for meaning.
///
/// Rules every view must follow:
///  - No `Color(red:...)`, `.opacity(...)`-blended backgrounds, or
///    `.system(size:)` literals at call sites — use the tokens here.
///  - Money amounts, addresses, and cheque bundle states always sit
///    on solid backgrounds (`bgPrimary`/`bgSecondary`), never on
///    translucent material.
///  - Material/translucency is chrome-only and goes through
///    `ChromeSurface` (see ChromeMaterial.swift), which respects the
///    user's translucency preference and the system's Reduce
///    Transparency setting unconditionally.
enum DesignTokens {
    // ── Brand ──────────────────────────────────────────────────────
    // Signature red on white/black (HSBC-inspired). The app is
    // light-mode only by product decision (2026-06-11); values are
    // sRGB resolved for light appearance.
    static let brandPrimary     = Color(red: 0xDB / 255, green: 0x00 / 255, blue: 0x11 / 255)
    static let brandPrimarySoft = Color(red: 0xFD / 255, green: 0xE6 / 255, blue: 0xE8 / 255) // pale red wash
    /// Pre-blended "softer" wash for large banner/callout fills —
    /// replaces ad-hoc `brandPrimarySoft.opacity(0.35...0.5)`.
    static let brandPrimaryWash = Color(red: 0xFE / 255, green: 0xF3 / 255, blue: 0xF4 / 255)

    // ── Backgrounds ────────────────────────────────────────────────
    static let bgPrimary        = Color.white
    static let bgSecondary      = Color(red: 0xf6 / 255, green: 0xf6 / 255, blue: 0xf7 / 255)
    static let bgTertiary       = Color(red: 0xed / 255, green: 0xed / 255, blue: 0xee / 255)
    /// Sidebar / rail fill when translucency is off.
    static let bgChrome         = Color(red: 0xf2 / 255, green: 0xf2 / 255, blue: 0xf4 / 255)

    // ── Text ───────────────────────────────────────────────────────
    static let textPrimary      = Color(red: 0x10 / 255, green: 0x10 / 255, blue: 0x12 / 255)
    static let textSecondary    = Color(red: 0x52 / 255, green: 0x52 / 255, blue: 0x57 / 255)
    static let textTertiary     = Color(red: 0x8a / 255, green: 0x8a / 255, blue: 0x91 / 255)

    // ── Borders ────────────────────────────────────────────────────
    static let borderTertiary   = Color.black.opacity(0.08)
    static let borderSecondary  = Color.black.opacity(0.14)
    /// Hairline width for card/section strokes.
    static let hairline: CGFloat = 0.5

    // ── Status (semantic colors — defined ONCE, used everywhere) ───
    // Cheque bundle states + FACT chain health. The `Soft` variants
    // are pre-blended fills replacing ad-hoc `.opacity(0.4/0.5/0.6)`
    // at call sites.
    static let statusCleanFg     = Color(red: 0x0f / 255, green: 0x6e / 255, blue: 0x56 / 255)
    static let statusCleanBg     = Color(red: 0xe6 / 255, green: 0xf3 / 255, blue: 0xed / 255)
    static let statusCleanBgSoft = Color(red: 0xf0 / 255, green: 0xf8 / 255, blue: 0xf4 / 255)
    static let statusCleanAccent = Color(red: 0x12 / 255, green: 0x88 / 255, blue: 0x6a / 255)
    static let statusScarredFg     = Color(red: 0x8a / 255, green: 0x57 / 255, blue: 0x09 / 255)
    static let statusScarredBg     = Color(red: 0xfa / 255, green: 0xee / 255, blue: 0xda / 255)
    static let statusScarredBgSoft = Color(red: 0xfc / 255, green: 0xf5 / 255, blue: 0xe9 / 255)
    static let statusScarredAccent = Color(red: 0xd1 / 255, green: 0x84 / 255, blue: 0x14 / 255)
    static let statusRejectedFg     = Color(red: 0xb0 / 255, green: 0x40 / 255, blue: 0x40 / 255)
    static let statusRejectedBg     = Color(red: 0xfb / 255, green: 0xeb / 255, blue: 0xeb / 255)
    static let statusRejectedBgSoft = Color(red: 0xfd / 255, green: 0xf3 / 255, blue: 0xf3 / 255)

    // ── Security tiers (defined ONCE — see TierStyle below) ────────
    static let tierStandardFg   = textSecondary
    static let tierStandardBg   = Color.black.opacity(0.06)
    static let tierSecureFg     = Color(red: 0x2a / 255, green: 0x4d / 255, blue: 0x8f / 255)
    static let tierSecureBg     = Color(red: 0xe2 / 255, green: 0xeb / 255, blue: 0xfa / 255)
    static let tierAaaFg        = Color(red: 0x6e / 255, green: 0x35 / 255, blue: 0xa0 / 255)
    static let tierAaaBg        = Color(red: 0xed / 255, green: 0xe5 / 255, blue: 0xf8 / 255)

    // ── Spacing scale (4pt grid) ───────────────────────────────────
    enum Spacing {
        /// 4 — icon/text gaps inside a chip
        static let xxs: CGFloat = 4
        /// 8 — related rows, chip padding
        static let xs: CGFloat = 8
        /// 12 — control padding, list row insets
        static let sm: CGFloat = 12
        /// 16 — card inner padding
        static let md: CGFloat = 16
        /// 20 — section gaps
        static let lg: CGFloat = 20
        /// 24 — sheet/pane edge padding
        static let xl: CGFloat = 24
        /// 32 — hero separation
        static let xxl: CGFloat = 32
    }

    // ── Corner radii (tighter than the OS 26 defaults) ─────────────
    enum Radius {
        /// 4 — chips, pills, badges
        static let chip: CGFloat = 4
        /// 6 — buttons, text fields
        static let control: CGFloat = 6
        /// 8 — cards, callouts
        static let card: CGFloat = 8
        /// 10 — sheets, large panels
        static let panel: CGFloat = 10
    }

    // ── Typography scale ───────────────────────────────────────────
    // One scale, sentence case everywhere. Monetary amounts ALWAYS
    // use the `amount*` styles (tabular numerals); identifiers
    // (addresses, hashes, hex) use the `mono*` styles.
    enum Typography {
        /// 28 medium, tabular — the balance hero figure
        static let amountHero = Font.system(size: 28, weight: .medium).monospacedDigit()
        /// 16 medium, tabular — amounts in detail sheets / inputs
        static let amountLarge = Font.system(size: 16, weight: .medium).monospacedDigit()
        /// 13 regular, tabular — amounts in rows and tables
        static let amount = Font.system(size: 13).monospacedDigit()
        /// 11 regular, tabular — secondary amounts (≈ AXC subtitles)
        static let amountCaption = Font.system(size: 11).monospacedDigit()

        /// 22 medium — sheet/onboarding step titles
        static let title = Font.system(size: 22, weight: .medium)
        /// 16 medium — pane and card titles
        static let heading = Font.system(size: 16, weight: .medium)
        /// 13 medium — emphasized body / row titles
        static let bodyStrong = Font.system(size: 13, weight: .medium)
        /// 13 regular — default body copy
        static let body = Font.system(size: 13)
        /// 12 regular — secondary copy
        static let label = Font.system(size: 12)
        /// 12 medium — control labels, emphasized captions
        static let labelStrong = Font.system(size: 12, weight: .medium)
        /// 11 regular — captions, helper text (minimum for prose)
        static let caption = Font.system(size: 11)
        /// 11 medium + tracking — section headers (apply
        /// `.tracking(0.4)` and uppercase at the call site only for
        /// section labels)
        static let sectionLabel = Font.system(size: 11, weight: .medium)
        /// 10 regular — footnotes/legal only, never primary info
        static let micro = Font.system(size: 10)
        /// 10 semibold — uppercase status chips ("CLEAN", "SCARRED");
        /// apply `.tracking(0.3)` at the call site
        static let chip = Font.system(size: 10, weight: .semibold)

        /// 12 monospaced — addresses, hashes, hex identifiers
        static let mono = Font.system(size: 12, design: .monospaced)
        /// 11 monospaced — identifiers in dense rows
        static let monoSmall = Font.system(size: 11, design: .monospaced)
    }

    // ── Elevation ──────────────────────────────────────────────────
    // Restrained: hairline strokes carry most separation; shadow is
    // reserved for true overlays (popovers/floating cards).
    enum Elevation {
        static let overlayShadowColor = Color.black.opacity(0.10)
        static let overlayShadowRadius: CGFloat = 12
        static let overlayShadowY: CGFloat = 4
    }

    // ── Motion ─────────────────────────────────────────────────────
    // Micro-interactions are subtle and fast (≤200 ms). Use
    // `Motion.standard()`/`Motion.quick()` which collapse to nil
    // (no animation) when the system Reduce Motion setting is on.
    enum Motion {
        static let quickDuration: Double = 0.12
        static let standardDuration: Double = 0.18

        static var reduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        /// Hover/pressed feedback.
        static func quick() -> Animation? {
            reduceMotion ? nil : .easeOut(duration: quickDuration)
        }
        /// State/layout transitions.
        static func standard() -> Animation? {
            reduceMotion ? nil : .easeInOut(duration: standardDuration)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Semantic mappings — the ONE place cheque-bundle states and security
// tiers get their color + icon. Views render these; they never pick
// status colors or symbols themselves.
// ─────────────────────────────────────────────────────────────────────

/// Cheque bundle / FACT link state → consistent color + iconography.
enum ChequeStatusStyle {
    case clean
    case scarred
    case rejected
    case pending
    case unknown

    /// Maps the SDK's status strings ("clean"/"scarred"/"rejected"/
    /// "partial"...) to a style. Unrecognized strings render neutral.
    init(statusString: String) {
        switch statusString.lowercased() {
        case "clean": self = .clean
        case "scarred": self = .scarred
        case "rejected": self = .rejected
        case "pending", "partial": self = .pending
        default: self = .unknown
        }
    }

    var fg: Color {
        switch self {
        case .clean: return DesignTokens.statusCleanFg
        case .scarred: return DesignTokens.statusScarredFg
        case .rejected: return DesignTokens.statusRejectedFg
        case .pending, .unknown: return DesignTokens.textTertiary
        }
    }

    var bg: Color {
        switch self {
        case .clean: return DesignTokens.statusCleanBg
        case .scarred: return DesignTokens.statusScarredBg
        case .rejected: return DesignTokens.statusRejectedBg
        case .pending, .unknown: return DesignTokens.bgTertiary
        }
    }

    /// Large-area fill (callouts, banners) — softer than `bg`.
    var bgSoft: Color {
        switch self {
        case .clean: return DesignTokens.statusCleanBgSoft
        case .scarred: return DesignTokens.statusScarredBgSoft
        case .rejected: return DesignTokens.statusRejectedBgSoft
        case .pending, .unknown: return DesignTokens.bgSecondary
        }
    }

    /// SF Symbol — states are never color-only.
    var symbol: String {
        switch self {
        case .clean: return "checkmark.seal"
        case .scarred: return "exclamationmark.triangle"
        case .rejected: return "xmark.octagon"
        case .pending: return "clock"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Security tier → consistent pill color. Tier *names* come from the
/// SDK; this maps the family (standard / secure / AAA) to visuals.
enum TierStyle {
    case standard
    case secure
    case aaa

    /// Family from a tier label like "Standard", "A+", "Secure+",
    /// "AAA+", "Ark".
    init(tierLabel: String) {
        let t = tierLabel.lowercased()
        if t.hasPrefix("aaa") { self = .aaa }
        else if t.hasPrefix("secure") { self = .secure }
        else { self = .standard }
    }

    var fg: Color {
        switch self {
        case .standard: return DesignTokens.tierStandardFg
        case .secure: return DesignTokens.tierSecureFg
        case .aaa: return DesignTokens.tierAaaFg
        }
    }

    var bg: Color {
        switch self {
        case .standard: return DesignTokens.tierStandardBg
        case .secure: return DesignTokens.tierSecureBg
        case .aaa: return DesignTokens.tierAaaBg
        }
    }
}
