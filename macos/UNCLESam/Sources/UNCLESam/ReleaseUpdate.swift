import Foundation
import AppKit
import CryptoKit
import AxiomSdk

// =================================================================
// ReleaseUpdate — in-app update checker for the PINNED clients
// (AxiomWallet, UNCLE SAM).
//
// These are pinned clients: each build bakes the canonical CoreID it
// talks to (`AXIOM_CANONICAL_CORE_ID`, surfaced as
// `sdkCanonicalCoreId()`), and the published DMG filename carries the
// 8-hex CoreID prefix (`axiomwallet-<coreid8>-<version>.dmg`). The
// network enforces the Same-Core invariant: a client whose Core does
// not match the live canonical CoreID is rejected at the CoreID gate
// and cannot transact. So the update policy is keyed on CoreID, not a
// soft protocol-version drift:
//
//   • manifest CoreID == this build's CoreID  → OPTIONAL update
//     (a feature/bugfix release on the same Core; the mesh still
//      accepts this client — surfaced as an unobtrusive chip).
//
//   • manifest CoreID != this build's CoreID  → MANDATORY update
//     (the canonical Core has rotated; this client is rejected on its
//      next transaction — surfaced as a blocking alert).
//
// The "latest release" manifest is `releases.json`, published to
// axiom-dist (the same raw-GitHub channel the wallet already uses for
// validators.list / nabla-nodes.list). It is written as a byproduct
// of `release-dmg.sh` and merged on publish — no hand maintenance.
//
// "Download directly" = fetch the DMG, verify its sha256 AND that its
// filename CoreID matches the manifest, then mount/reveal it for the
// standard drag-to-Applications step (macOS cannot replace a running
// .app in place; a fully silent swap would need a Sparkle-style
// updater, deliberately out of scope here).
// =================================================================

/// The two pinned clients that ship through this channel.
enum AxiomProduct: String {
    case axiomwallet
    case unclesam
}

/// One product's entry in `releases.json`. `url` / `notesUrl` are
/// optional because `release-dmg.sh` emits the fragment before the
/// box uploads the GitHub asset and fills the final URL on publish.
struct ReleaseInfo: Codable, Equatable {
    let version: String
    let coreId: String
    // OPTIONAL — `products` in releases.json carries non-DMG sibling
    // entries (e.g. `webclient`: html_sha256/zip_sha256, no dmg). The
    // manifest decodes the whole dict into [String: ReleaseInfo], so a
    // missing dmg/sha256 on a sibling must not fail-decode everything
    // ("the data couldn't be read because it is missing"). The pinned
    // DMG products (axiomwallet / unclesam) always populate both; the
    // download path guards on them.
    let dmg: String?
    let url: String?
    let sha256: String?
    let notesUrl: String?

    enum CodingKeys: String, CodingKey {
        case version
        case coreId = "core_id"
        case dmg
        case url
        case sha256
        case notesUrl = "notes_url"
    }
}

/// Top-level `releases.json` shape: `{ "schema": 1, "products": { ... } }`.
struct ReleaseManifest: Codable {
    let schema: Int
    let products: [String: ReleaseInfo]
}

/// `seeds/worldline.json` — network identity (current worldline Core +
/// suggested digit_version). Advisory + best-effort; unreachable ⇒ absent.
struct WorldlineParams: Codable, Equatable {
    let coreId: String
    let digitVersion: Int?
    let digitVersionStarted: String?
    enum CodingKeys: String, CodingKey {
        case coreId = "core_id"
        case digitVersion = "digit_version"
        case digitVersionStarted = "digit_version_started"
    }
}

/// The checker's conclusion for this build against the live manifest.
enum UpdateVerdict: Equatable {
    /// Not checked yet, or the check failed / found no entry.
    case unknown
    /// This build is the published latest (or newer — dev builds ahead).
    case upToDate
    /// A newer release exists on the SAME CoreID — recommended, never blocks.
    case optional(ReleaseInfo)
    /// The published CoreID differs from this build — the network has
    /// rotated its canonical Core and this client will be rejected.
    case mandatory(ReleaseInfo)

    var releaseInfo: ReleaseInfo? {
        switch self {
        case .optional(let i), .mandatory(let i): return i
        case .unknown, .upToDate: return nil
        }
    }

    var isMandatory: Bool { if case .mandatory = self { return true }; return false }
    var hasUpdate: Bool { releaseInfo != nil }
}

enum ReleaseUpdate {
    /// Where `releases.json` lives — the axiom-dist repo root, the same
    /// raw-GitHub host `SeedFetcher` uses for the seed lists.
    /// `AXIOM_RELEASES_URL` overrides it (debug / QA) — a local `file://`
    /// or staging manifest to exercise the update flow on demand.
    static var manifestURL: String {
        let override = ProcessInfo.processInfo.environment["AXIOM_RELEASES_URL"] ?? ""
        if !override.isEmpty { return override }
        return "https://raw.githubusercontent.com/AXIOM-Origin-Validator/axiom-dist/main/releases.json"
    }

    /// Network-parameters feed (current worldline Core + suggested
    /// digit_version). Best-effort; `AXIOM_WORLDLINE_URL` overrides.
    static var worldlineURL: String {
        let override = ProcessInfo.processInfo.environment["AXIOM_WORLDLINE_URL"] ?? ""
        if !override.isEmpty { return override }
        return "https://raw.githubusercontent.com/AXIOM-Origin-Validator/axiom-dist/main/seeds/worldline.json"
    }

    /// This build's app version — `CFBundleShortVersionString` from the
    /// bundle Info.plist. Matches the DMG/release identity
    /// (`unclesam-<coreid8>-<version>.dmg`) and the manifest `version`
    /// field. NOT `sdk_build_version()` (the Rust crate version, a
    /// different namespace — comparing against it never fires the
    /// optional-update path).
    static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// Parse a version like `3.2.0-beta6` → `(3, 2, 0, 6)`; a plain
    /// release `3.2.0` → `(3, 2, 0, Int.max)` so a release sorts ABOVE
    /// any of its betas. Returns nil if the leading `X[.Y[.Z]]` won't
    /// parse, in which case callers fall back to plain string inequality.
    static func parse(_ v: String) -> (Int, Int, Int, Int)? {
        let halves = v.split(separator: "-", maxSplits: 1)
        let core = halves[0].split(separator: ".")
        guard let major = core.first.flatMap({ Int($0) }) else { return nil }
        let minor = core.count > 1 ? (Int(core[1]) ?? 0) : 0
        let patch = core.count > 2 ? (Int(core[2]) ?? 0) : 0
        var pre = Int.max // no pre-release tag ⇒ a final release (highest)
        if halves.count > 1 {
            let digits = halves[1].drop(while: { !$0.isNumber })
            pre = Int(digits) ?? 0
        }
        return (major, minor, patch, pre)
    }

    /// True when `latest` is strictly newer than `current`. Unparseable
    /// versions fall back to "any difference means there's an update"
    /// (the manifest only ever lists the current latest).
    static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let l = parse(latest), let c = parse(current) else {
            return latest != current
        }
        return l > c
    }

    /// Compute the verdict for `product` from a fetched manifest, given
    /// this build's version and baked canonical CoreID.
    ///
    /// `canonicalCoreId` empty ⇒ a dev build (the CoreID gate is skipped
    /// at `setup()`): never raise a mandatory prompt, only an optional
    /// one on version. Released clients always carry a baked CoreID.
    static func verdict(
        for product: AxiomProduct,
        manifest: ReleaseManifest,
        worldlineCoreId: String?,
        currentVersion: String,
        canonicalCoreId: String
    ) -> UpdateVerdict {
        guard let info = manifest.products[product.rawValue] else { return .upToDate }

        let mine = canonicalCoreId.lowercased()
        let theirs = (worldlineCoreId ?? "").lowercased()
        if !mine.isEmpty && !theirs.isEmpty && mine != theirs {
            return .mandatory(info)
        }
        if isNewer(info.version, than: currentVersion) {
            return .optional(info)
        }
        return .upToDate
    }
}
