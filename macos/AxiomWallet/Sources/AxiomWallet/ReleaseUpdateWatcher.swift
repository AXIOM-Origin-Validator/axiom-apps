import Foundation
import AppKit
import CryptoKit
import AxiomSdk

// =================================================================
// ReleaseUpdateWatcher — app-scoped observable that checks the
// axiom-dist release manifest and drives the in-app update UI.
//
// Cadence: a one-shot check on launch (fired from AxiomWalletApp),
// plus a manual "Check now" from Settings. We don't poll on a timer —
// a new release is a rare event and the manifest is a static file.
//
// See ReleaseUpdate.swift for the CoreID-keyed policy (same CoreID =>
// optional, different CoreID => mandatory).
// =================================================================

@MainActor
final class ReleaseUpdateWatcher: ObservableObject {
    let product: AxiomProduct

    /// Latest computed verdict. `.unknown` until the first check lands.
    @Published private(set) var verdict: UpdateVerdict = .unknown

    /// A manifest fetch is in flight.
    @Published private(set) var checking = false

    /// A DMG download is in flight.
    @Published private(set) var downloading = false

    /// Last user-facing error from a check or download (nil when clean).
    @Published private(set) var lastError: String?

    /// The verified DMG that was downloaded + mounted this session.
    @Published private(set) var downloadedDmg: URL?

    /// When the last check completed (success or failure). Drives the
    /// "Last checked …" line so the user gets visible confirmation the
    /// Check button did something, even when the verdict is unchanged.
    @Published private(set) var lastChecked: Date?

    /// One-shot gate so `MainAppView` fires the mandatory-update alert
    /// exactly once per session when a CoreID rotation is detected.
    @Published var mandatoryAlertPending = false

    /// Hard-lock signal: the published build's CoreID differs from this
    /// build's, so the network's canonical Core has rotated and this
    /// client is rejected at the CoreID gate. The wallet disables every
    /// broadcast (Send / Redeem / Claim) while this is true — transacting
    /// against a Core the validators no longer run would make this
    /// wallet's computed state diverge from the network's and can damage
    /// the wallet. See Yellow Paper §23.10 (Core Upgrade as State
    /// Transition) and §16.8.3 (client + validators run the same Core).
    var mustUpgradeCore: Bool { verdict.isMandatory }

    /// Best-effort network params from `worldline.json`. `reachable`
    /// false ⇒ couldn't fetch this check — surfaced ONLY as a quiet line
    /// in About, never a popup or blocker. Defaults true so a fresh
    /// pre-check state doesn't read as "unavailable".
    @Published private(set) var worldlineReachable = true
    /// Current worldline Core (authoritative for the mandatory check).
    @Published private(set) var worldlineCoreId: String?
    /// Suggested L$ digit_version + the date it took effect.
    @Published private(set) var suggestedDigitVersion: Int?
    @Published private(set) var digitVersionStarted: String?

    init(product: AxiomProduct) { self.product = product }

    /// Fetch `releases.json` and recompute the verdict against this
    /// build's version + canonical CoreID. Safe to call repeatedly.
    func check() async {
        checking = true
        lastError = nil
        let startedAt = Date()

        // (1) Best-effort network params (worldline.json). Failure is NOT
        // an error — it's "absent": no popup, no blocker, just a quiet
        // About line. The suggested digit_version is applied by whoever
        // observes `suggestedDigitVersion`.
        let worldline = await Self.fetchWorldline()
        worldlineReachable = (worldline != nil)
        worldlineCoreId = worldline?.coreId
        // Set the start date BEFORE the dv publisher fires — the
        // `$suggestedDigitVersion` observer reads `digitVersionStarted`
        // synchronously in its didSet, so it must already be current.
        digitVersionStarted = worldline?.digitVersionStarted
        suggestedDigitVersion = worldline?.digitVersion

        // (2) releases.json — the download / version feed.
        do {
            guard let url = URL(string: ReleaseUpdate.manifestURL) else { throw URLError(.badURL) }
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                throw NSError(domain: "ReleaseUpdate", code: code,
                              userInfo: [NSLocalizedDescriptionKey: "feed returned HTTP \(code)"])
            }
            let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
            let v = ReleaseUpdate.verdict(
                for: product,
                manifest: manifest,
                worldlineCoreId: worldline?.coreId,
                currentVersion: ReleaseUpdate.appVersion(),
                canonicalCoreId: sdkCanonicalCoreId()
            )
            verdict = v
            if v.isMandatory { mandatoryAlertPending = true }
        } catch {
            lastError = "Update check failed: \(error.localizedDescription)"
        }

        // A manifest fetch is usually sub-second, so the "Checking…"
        // state would flash invisibly and a manual check would feel
        // dead. Hold the spinner for a minimum beat so the click always
        // produces visible feedback; lastChecked then updates the
        // "Last checked …" line even when the verdict is unchanged.
        let elapsed = Date().timeIntervalSince(startedAt)
        let minVisible = 0.6
        if elapsed < minVisible {
            try? await Task.sleep(nanoseconds: UInt64((minVisible - elapsed) * 1_000_000_000))
        }
        lastChecked = Date()
        checking = false
    }

    /// Fetch `worldline.json`. Returns nil on ANY failure (unreachable,
    /// non-200, decode error) — caller treats nil as "absent", never an
    /// error. Best-effort by design.
    private static func fetchWorldline() async -> WorldlineParams? {
        guard let url = URL(string: ReleaseUpdate.worldlineURL) else { return nil }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? JSONDecoder().decode(WorldlineParams.self, from: data)
        else { return nil }
        return parsed
    }

    /// Download the verified DMG and mount it for the user to drag into
    /// /Applications. Verifies the sha256 against the manifest before
    /// opening anything.
    func downloadAndReveal() async {
        guard let info = verdict.releaseInfo else { return }
        guard let urlStr = info.url, let url = URL(string: urlStr) else {
            lastError = "This release has no download URL yet — check back shortly."
            return
        }
        // Pinned DMG products always carry these; guard so the optional
        // (tolerated for non-DMG sibling entries like `webclient`) can't
        // silently skip the tamper check.
        guard let expectedSha = info.sha256, let dmgName = info.dmg else {
            lastError = "This release is missing its DMG / checksum in the manifest — refusing to download."
            return
        }
        downloading = true
        lastError = nil
        defer { downloading = false }

        do {
            let (tempURL, resp) = try await URLSession.shared.download(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                lastError = "Download failed (HTTP \(code))."
                return
            }
            let data = try Data(contentsOf: tempURL)

            // Whole-DMG integrity: sha256 must match the manifest. This
            // is the authoritative tamper check — the published asset uses
            // a constant stable filename (AxiomWallet.dmg), so the CoreID
            // lives in the release tag and the manifest's `core_id` field,
            // not the asset filename. The manifest sha256 + core_id are
            // the bindings we trust, not the name.
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hex.lowercased() == expectedSha.lowercased() else {
                lastError = "Downloaded DMG sha256 does not match the manifest — refusing to open."
                return
            }

            let downloads = FileManager.default
                .urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dest = downloads.appendingPathComponent(dmgName)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tempURL, to: dest)
            downloadedDmg = dest

            // Mount the DMG (and reveal in Finder) so the user can drag
            // the .app into /Applications — the standard macOS install
            // gesture. macOS can't hot-swap a running bundle.
            NSWorkspace.shared.open(dest)
        } catch {
            lastError = "Download failed: \(error.localizedDescription)"
        }
    }

    /// Open the release notes page (or the GitHub release) in the browser.
    func openNotes() {
        guard let s = verdict.releaseInfo?.notesUrl, let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }
}
