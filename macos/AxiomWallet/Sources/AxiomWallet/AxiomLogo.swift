import SwiftUI

// =================================================================
// Official AXIØM logo system.
//
// Vector reproduction of the marks shipped in
// `assets/AXIOM_Official_Logo_Package_v2/`. Drawn directly with
// SwiftUI Path so the marks scale infinitely without raster
// artefacts and tint freely with the surrounding app theme.
//
// Per the v2 Logo Guidelines (Approved):
//   - Outer frame: Core / constitutional boundary / protected system
//   - Λ Lambda:    validation / law / order
//   - — line:      equilibrium / separation / invariant boundary
//   - ∇ Nabla:     operation / flow / execution
//
// Usage rules from the guidelines:
//   - Do NOT alter the proportions of the seal
//   - Do NOT redraw the symbol with stroke-only geometry
//   - Use monochrome black (#111111) or paper white (#F7F5F2)
//     as the primary identity; Constitution Gold (#B89B5E) is the
//     ceremonial accent only
//   - Horizontal lockup → website headers / official documents
//   - Seal-only mark → favicons, GitHub avatars, stamps, hardware
//
// The app theme (HSBC-leaning red palette in DesignTokens) does NOT
// override these — UI buttons / sidebar accents stay branded for
// cohesion, but the logo marks themselves render in the official
// monochrome.
// =================================================================

// MARK: - Brand colors (from AXIOM Logo Guidelines v2)

extension DesignTokens {
    static let axiomBlack       = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255)
    static let axiomPaperWhite  = Color(red: 0xF7 / 255, green: 0xF5 / 255, blue: 0xF2 / 255)
    static let constitutionGold = Color(red: 0xB8 / 255, green: 0x9B / 255, blue: 0x5E / 255)
}

// =================================================================
// AxiomSealShape — vector path of the approved seal.
//
// Source: assets/AXIOM_Official_Logo_Package_v2/01_Vector_SVG/
//         AXIOM-Seal-Approved.svg (viewBox 0 0 235 365).
//
// Coordinates are preserved identically; the shape uses
// fill-rule even-odd so the outer-frame inner cutout and the
// Nabla inner cutout render correctly when filled.
// =================================================================
struct AxiomSealShape: Shape {
    /// Native aspect ratio of the SVG viewBox.
    static let aspectRatio: CGFloat = 235.0 / 365.0

    func path(in rect: CGRect) -> Path {
        let svgAspect = AxiomSealShape.aspectRatio
        let rectAspect = rect.width / rect.height

        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        if rectAspect > svgAspect {
            // Rect is wider than SVG — fit by height, center horizontally.
            scale = rect.height / 365
            offsetX = (rect.width - 235 * scale) / 2
            offsetY = 0
        } else {
            // Rect is taller than (or equal to) SVG — fit by width.
            scale = rect.width / 235
            offsetX = 0
            offsetY = (rect.height - 365 * scale) / 2
        }

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + offsetX + x * scale,
                y: rect.minY + offsetY + y * scale
            )
        }

        var path = Path()

        // ── Outer Core frame — outer perimeter ─────────────────────
        path.move(to: pt(54, 25))
        path.addLine(to: pt(178, 25))
        path.addCurve(to: pt(211, 61),  control1: pt(196, 25),  control2: pt(211, 41))
        path.addLine(to: pt(211, 320))
        path.addCurve(to: pt(180, 356), control1: pt(211, 339), control2: pt(196, 356))
        path.addLine(to: pt(52, 356))
        path.addCurve(to: pt(22, 321),  control1: pt(35, 356),  control2: pt(22, 340))
        path.addLine(to: pt(22, 60))
        path.addCurve(to: pt(54, 25),   control1: pt(22, 41),   control2: pt(36, 25))
        path.closeSubpath()

        // ── Outer Core frame — inner cutout (eoFill flips fill) ────
        path.move(to: pt(56, 40))
        path.addLine(to: pt(176, 40))
        path.addCurve(to: pt(196, 64),  control1: pt(188, 40),  control2: pt(196, 50))
        path.addLine(to: pt(196, 317))
        path.addCurve(to: pt(177, 342), control1: pt(196, 332), control2: pt(187, 342))
        path.addLine(to: pt(55, 342))
        path.addCurve(to: pt(36, 317),  control1: pt(43, 342),  control2: pt(36, 332))
        path.addLine(to: pt(36, 64))
        path.addCurve(to: pt(56, 40),   control1: pt(36, 50),   control2: pt(44, 40))
        path.closeSubpath()

        // ── Λ Lambda (validation) ──────────────────────────────────
        path.move(to: pt(116, 63))
        path.addLine(to: pt(166, 158))
        path.addLine(to: pt(150, 158))
        path.addLine(to: pt(116, 92))
        path.addLine(to: pt(82, 158))
        path.addLine(to: pt(68, 158))
        path.closeSubpath()

        // ── Invariant line (equilibrium) ───────────────────────────
        path.addRect(CGRect(
            x: rect.minX + offsetX + 65 * scale,
            y: rect.minY + offsetY + 181 * scale,
            width: 104 * scale,
            height: 14 * scale
        ))

        // ── ∇ Nabla — outer triangle (execution) ───────────────────
        path.move(to: pt(65, 221))
        path.addLine(to: pt(169, 221))
        path.addLine(to: pt(117, 317))
        path.closeSubpath()

        // ── ∇ Nabla — inner cutout ─────────────────────────────────
        path.move(to: pt(88, 236))
        path.addLine(to: pt(117, 288))
        path.addLine(to: pt(146, 236))
        path.closeSubpath()

        return path
    }
}

// =================================================================
// AxiomSeal — the seal shape rendered with the proper fill rule.
// Pre-bundled with eoFill so callers don't have to remember.
// =================================================================
struct AxiomSeal: View {
    var color: Color = DesignTokens.axiomBlack
    /// Optional vertical pixel height (width auto-derives from aspect).
    var height: CGFloat? = nil

    var body: some View {
        AxiomSealShape()
            .fill(color, style: FillStyle(eoFill: true))
            .modifier(OptionalHeight(height: height))
    }
}

private struct OptionalHeight: ViewModifier {
    let height: CGFloat?
    func body(content: Content) -> some View {
        if let h = height {
            content.frame(width: h * AxiomSealShape.aspectRatio, height: h)
        } else {
            content
        }
    }
}

// =================================================================
// AxiomWordmark — "AXIØM" set in the wordmark style.
//
// SVG sets it in Inter / Helvetica Neue at weight 500 with heavy
// letter-spacing. SwiftUI's system font is San Francisco; Inter is
// the design intent but isn't bundled. Falling back to system at
// the same weight + tracking preserves the geometry well at the
// sizes we display (sidebar, login, header).
// =================================================================
struct AxiomWordmark: View {
    var size: CGFloat = 24
    var color: Color = DesignTokens.axiomBlack

    var body: some View {
        Text("AXIØM")
            .font(.system(size: size, weight: .medium))
            .tracking(size * 0.18)
            .foregroundStyle(color)
    }
}

// =================================================================
// AxiomTagline — "MONETARY ARCHITECTURE".
// Used as the second line in horizontal/vertical lockups.
// =================================================================
struct AxiomTagline: View {
    var size: CGFloat = 9
    var color: Color = DesignTokens.axiomBlack.opacity(0.75)

    var body: some View {
        Text("MONETARY ARCHITECTURE")
            .font(.system(size: size, weight: .regular))
            .tracking(size * 0.3)
            .foregroundStyle(color)
    }
}

// =================================================================
// AxiomHorizontalLockup — seal + wordmark/tagline side-by-side.
// Per the guidelines, this is the preferred form for headers and
// document chrome.
// =================================================================
struct AxiomHorizontalLockup: View {
    var sealHeight: CGFloat = 56
    var color: Color = DesignTokens.axiomBlack
    var showTagline: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: sealHeight * 0.22) {
            AxiomSeal(color: color, height: sealHeight)
            VStack(alignment: .leading, spacing: 2) {
                AxiomWordmark(size: sealHeight * 0.42, color: color)
                if showTagline {
                    AxiomTagline(
                        size: sealHeight * 0.13,
                        color: color.opacity(0.75)
                    )
                }
            }
        }
    }
}

// =================================================================
// AxiomVerticalLockup — seal centered above wordmark/tagline.
// Used on the login screen and onboarding hero.
// =================================================================
struct AxiomVerticalLockup: View {
    var sealHeight: CGFloat = 72
    var color: Color = DesignTokens.axiomBlack
    var showTagline: Bool = true

    var body: some View {
        VStack(spacing: sealHeight * 0.16) {
            AxiomSeal(color: color, height: sealHeight)
            VStack(spacing: 4) {
                AxiomWordmark(size: sealHeight * 0.30, color: color)
                if showTagline {
                    AxiomTagline(
                        size: sealHeight * 0.11,
                        color: color.opacity(0.75)
                    )
                }
            }
        }
    }
}
