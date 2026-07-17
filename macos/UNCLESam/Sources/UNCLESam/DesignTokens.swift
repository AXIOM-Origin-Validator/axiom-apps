import SwiftUI

// =================================================================
// DesignTokens — high-contrast institutional palette for UNCLE SAM.
//
// Rewritten 2026-05-28 to prioritise legibility for executive
// reviewers (often older eyes). The original draft leaned into
// modern soft-grey fintech minimalism; this iteration goes the
// opposite way: pure white backgrounds, near-black body text,
// strongly visible borders, saturated status pills.
//
// Design rules:
//   • Body text is near-black. Never grey-by-default.
//   • Backgrounds stay almost-white. Differentiation comes from
//     visible borders, not nested grey shades.
//   • Status colours hit ≥ 4.5:1 contrast against their pill bg.
//   • Brand navy for chrome + accents only — not for body text.
//   • Mono sizes scaled up 1pt from the SwiftUI default so
//     monospace BICs/txids don't feel like fine print.
//
// Parallel to AxiomWallet's DesignTokens; deliberately not shared
// because the two apps have different visual priorities. The
// retail wallet biases toward approachable + dense activity;
// UNCLE SAM biases toward formal + high-information-density tables.
// =================================================================

enum DesignTokens {

    // ── Brand ────────────────────────────────────────────────────
    /// UNCLE brand navy. Used for primary chrome, accent strokes,
    /// table-header backgrounds. Saturated enough to read clearly
    /// when white text sits on it.
    static let brandNavy        = Color(red: 0.08, green: 0.16, blue: 0.34)
    /// Selected-row tint — pale blue against the white body so a
    /// selection is obvious without screaming.
    static let brandNavySoft    = Color(red: 0.91, green: 0.94, blue: 0.99)
    /// Institutional gold — used sparingly for "settled" /
    /// "approved" status emphasis. Slightly richer than the
    /// original draft so it doesn't disappear next to the navy.
    static let brandGold        = Color(red: 0.62, green: 0.48, blue: 0.10)
    static let brandGoldSoft    = Color(red: 0.99, green: 0.96, blue: 0.86)

    // ── Backgrounds ──────────────────────────────────────────────
    //
    // Two principles:
    //   1. Pure white for primary canvas (best contrast vs body).
    //   2. Distinct, NOT-grey tones for chrome / table headers so
    //      a glance distinguishes them without dimming the text.
    /// Main content canvas — pure white.
    static let bgPrimary        = Color(red: 1.00, green: 1.00, blue: 1.00)
    /// Card / panel background — a barely-cream off-white. Just
    /// enough to differentiate cards from the canvas without
    /// pushing into low-contrast territory.
    static let bgSecondary      = Color(red: 0.975, green: 0.975, blue: 0.97)
    /// Table-header / row-stripe background — cool blue-grey so
    /// it reads as "structural" rather than "dimmer card".
    static let bgTertiary       = Color(red: 0.91, green: 0.93, blue: 0.97)
    /// Header-strip background — deep institutional navy.
    static let bgChrome         = Color(red: 0.10, green: 0.18, blue: 0.36)

    // ── Text ─────────────────────────────────────────────────────
    //
    // Three tiers, all comfortably above 4.5:1 against bgPrimary.
    // The previous draft put tertiary at L*≈60 which fails WCAG AA
    // at 10pt; this revision pulls it down to L*≈40.
    /// Primary body text — near-black.
    static let textPrimary      = Color(red: 0.05, green: 0.07, blue: 0.10)
    /// Secondary text (captions, descriptions, narrative cells).
    /// Still very readable — dark slate.
    static let textSecondary    = Color(red: 0.20, green: 0.22, blue: 0.26)
    /// Tertiary text (section labels, column headers, mono small
    /// captions). NEVER used for content the operator needs to
    /// act on — only for orientation labels.
    static let textTertiary     = Color(red: 0.36, green: 0.38, blue: 0.42)
    /// Text on the navy chrome (white-on-navy for the top bar).
    static let textOnChrome     = Color.white

    // ── Borders ──────────────────────────────────────────────────
    //
    // Bumped contrast vs the original 0.78 grey. Card outlines
    // should be visible without dominating.
    static let borderPrimary    = Color(red: 0.62, green: 0.66, blue: 0.72)
    static let borderSecondary  = Color(red: 0.80, green: 0.83, blue: 0.86)
    static let borderTertiary   = Color(red: 0.90, green: 0.92, blue: 0.94)

    // ── Status (formal banking labels) ───────────────────────────
    //
    // Pill colours — text foreground sits on pill background; the
    // pair targets ≥ 4.5:1 contrast so the label is readable on
    // small badges. Saturated foregrounds, pale backgrounds.
    static let statusSettledFg  = Color(red: 0.06, green: 0.36, blue: 0.14)
    static let statusSettledBg  = Color(red: 0.86, green: 0.96, blue: 0.88)
    static let statusPendingFg  = Color(red: 0.55, green: 0.38, blue: 0.04)
    static let statusPendingBg  = Color(red: 0.99, green: 0.94, blue: 0.81)
    static let statusRejectedFg = Color(red: 0.60, green: 0.10, blue: 0.12)
    static let statusRejectedBg = Color(red: 0.99, green: 0.90, blue: 0.90)
    static let statusInfoFg     = Color(red: 0.10, green: 0.24, blue: 0.55)
    static let statusInfoBg     = Color(red: 0.89, green: 0.93, blue: 0.99)

    // ── Type styles ──────────────────────────────────────────────
    //
    // Sizes nudged up 1pt across the small-end stack vs the
    // original draft. Mono small at 11pt is still tight enough
    // for dense tables but legible without ⌘+ zoom.
    /// Monospace for BIC / txid / account number rendering.
    static let monoFont         = Font.system(size: 13, design: .monospaced)
    static let monoSmallFont    = Font.system(size: 11, design: .monospaced)
    /// Tabular numbers for amount columns.
    static let amountFont       = Font.system(size: 15, weight: .medium, design: .monospaced)
    /// Section / panel labels — semibold so the small caps style
    /// reads at 11pt without becoming illegible.
    static let labelFont        = Font.system(size: 11, weight: .semibold)
}
