import Foundation

// =================================================================
// SeedFetcher — HTTP GET of validator + Nabla seed lists from the
// public AXIOM distribution repo.
//
// Rationale: shipping the wallet with hard-coded `validators.list` /
// `nabla-nodes.list` defaults baked into the binary means every
// change to the seed list requires a new release. With this module
// the lists live in axiom-dist (a separate, contributor-maintained
// GitHub repo) and the wallet pulls them on first launch — and on
// every version bump after that.
//
// The fetched list is a **bootstrap seed**, not the network — like
// Bitcoin's DNS seeds or Ethereum's bootnodes. Once the wallet has
// any working entry it discovers more via the protocol's gossip /
// witness paths; the seed list is only the cold-start hint.
//
// Bootstrap pipeline (`SdkBootstrap.run` on launch):
//
//   1. fetchSeedListsIfStale     (this file)
//        — fetch SEEDS_VERSION from axiom-dist. If remote > local
//          cached version, refresh both seed files. If local files
//          are also empty/missing, refresh regardless of version.
//        — On network failure: silent no-op. Fall through to (2).
//   2. seedHintFilesIfMissing    (AxiomWalletApp.swift)
//        — fill anything (1) couldn't fetch from the bundled tiny
//          emergency-floor `.default` files (3 entries each). Lets
//          a wallet booted on a flight survive first launch.
//
// Manual refresh: `forceRefresh(appDir:)` ignores the version cache
// and re-pulls both lists. Triggered by the Settings → Network →
// "Refresh seeds from axiom-dist" button.
//
// Trust posture: HTTPS only, ATS-default trust. The repo is owned
// by the AXIOM-Origin-Validator GitHub org; whoever controls that
// org controls where shipped wallets first reach out. Pre-mainnet
// this is acceptable — for mainnet a signed manifest + pinned
// minimum commit SHA will sit on top of this fetch.
// =================================================================

enum SeedFetcher {
    /// Raw-file base for the seed lists. PRs to axiom-dist edit
    /// `seeds/validators.list` and `seeds/nabla-nodes.list`.
    static let baseURL =
        "https://raw.githubusercontent.com/AXIOM-Origin-Validator/axiom-dist/main/seeds"

    /// 5 seconds is "enough for a GitHub raw GET on a working
    /// connection". Failing fast keeps first-launch UX snappy when
    /// the user is offline; the bundled fallback runs immediately
    /// after.
    static let timeoutSecs: TimeInterval = 5

    /// Launch-fetch retry budget. A wallet opened the instant the
    /// network is still coming up sees the first GET fail; 3 tries with
    /// a short backoff cover that transient before the wallet degrades
    /// to the bundled fallback. (A truly-offline launch fails each
    /// attempt fast — no route — so this stays well under a second.)
    static let maxFetchAttempts = 3

    /// Detailed result returned by `forceRefresh` so the Settings UI
    /// can show useful feedback.
    struct RefreshOutcome {
        var validatorsBytes: Int?
        var nablaNodesBytes: Int?
        var remoteVersion: Int?
        var error: String?
    }

    /// Read the local cached `SEEDS_VERSION` (zero if unset / file
    /// absent / malformed). Stored next to the seed files at
    /// `<appDir>/.seeds_version`.
    private static func localSeedsVersion(appDir: String) -> Int {
        let path = "\(appDir)/.seeds_version"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let v = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return v
    }

    private static func writeSeedsVersion(_ v: Int, appDir: String) {
        let path = "\(appDir)/.seeds_version"
        try? "\(v)\n".write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Fetch + apply seed updates when the remote `SEEDS_VERSION` is
    /// newer than what we have cached, OR when either local file is
    /// missing usable content. Called from `SdkBootstrap.run` on
    /// every launch.
    ///
    /// Behaviour matrix:
    ///   - remote_version > local_version: refresh both files,
    ///     update cache.
    ///   - remote_version == local_version: still refresh files
    ///     whose local copy is empty (offline-first-launch recovery).
    ///   - remote SEEDS_VERSION 404 or unreachable: degrade to
    ///     "missing file" semantics — same as the prior
    ///     `fetchSeedListsIfMissing` behaviour.
    /// Returns `true` when the seed lists are in good shape (freshly
    /// fetched, or an existing real copy left in place); `false` when a
    /// list the wallet had no real copy of couldn't be fetched — i.e.
    /// the wallet is dropping to the bundled `.default` floor. The
    /// caller surfaces a non-fatal "running on fallback" notice.
    static func fetchSeedListsIfStale(appDir: String) async -> Bool {
        let remoteVersion = await fetchInt("\(baseURL)/SEEDS_VERSION")
        let localVersion = localSeedsVersion(appDir: appDir)
        let versionStale = remoteVersion.map { $0 > localVersion } ?? false

        let targets: [(remoteName: String, localName: String)] = [
            ("validators.list",  "validators.list"),
            ("nabla-nodes.list", "nabla-nodes.list"),
        ]

        var refreshedAny = false
        var degraded = false
        for t in targets {
            let dest = "\(appDir)/\(t.localName)"
            let missing = !fileHasUsableContent(at: dest)
            // Skip iff we have content AND the remote isn't newer.
            // Note: when remote version is unknown (404), we treat
            // it as "not newer" so a working file is left alone.
            if !missing && !versionStale { continue }
            guard let body = await fetchText("\(baseURL)/\(t.remoteName)"),
                  !body.isEmpty else {
                // A list we needed couldn't be fetched. If we also have
                // no usable local copy, the wallet falls back to the
                // bundled `.default` floor — flag that for the UI.
                if missing {
                    NSLog("%@", "[SeedFetcher] \(t.remoteName): fetch failed and no "
                        + "usable local copy — wallet will run on the bundled fallback")
                    degraded = true
                }
                continue
            }
            // Format-guard: the SDK's seed parser is strict (6-col
            // validators.list / 3-col nabla-nodes.list). A remote
            // axiom-dist that hasn't yet been updated to a new format
            // will serve a body that the SDK then refuses to parse,
            // bricking the wallet at sdk_setup(). Validate parseability
            // FIRST; reject malformed bodies and keep whatever's local.
            if !bodyParsesAsSeedFormat(body, fileName: t.localName) {
                NSLog("%@", "[SeedFetcher] \(t.remoteName): remote body "
                    + "doesn't parse as the SDK's current format — keeping "
                    + "local copy (wallet will continue to launch).")
                continue
            }
            if (try? body.write(toFile: dest, atomically: true, encoding: .utf8)) != nil {
                refreshedAny = true
            }
        }

        // Only stamp the cached version when we actually applied a
        // refresh — otherwise an "all files up to date, remote
        // version unchanged" launch would loop-write the same value.
        if refreshedAny, let v = remoteVersion {
            writeSeedsVersion(v, appDir: appDir)
        }
        return !degraded
    }

    /// Unconditional refresh — fetches both seed files and rewrites
    /// them on disk, ignoring the version cache. Called by the
    /// Settings "Refresh seeds" button. Returns a `RefreshOutcome`
    /// describing what landed so the UI can confirm.
    ///
    /// Does NOT touch the SDK's in-memory `runtime.validators` /
    /// `runtime.nabla_tcp` — those are loaded once at `sdk_setup()`
    /// and the OnceLock can't be replaced. The UI surfaces a
    /// "Restart the wallet to apply" hint when this completes.
    static func forceRefresh(appDir: String) async -> RefreshOutcome {
        var out = RefreshOutcome()

        let remoteVersion = await fetchInt("\(baseURL)/SEEDS_VERSION")
        out.remoteVersion = remoteVersion

        if let body = await fetchText("\(baseURL)/validators.list"), !body.isEmpty {
            guard bodyParsesAsSeedFormat(body, fileName: "validators.list") else {
                out.error = "remote validators.list is malformed for the current SDK (wrong column count) — local copy left in place"
                return out
            }
            let path = "\(appDir)/validators.list"
            do {
                try body.write(toFile: path, atomically: true, encoding: .utf8)
                out.validatorsBytes = body.utf8.count
            } catch {
                out.error = "validators.list write: \(error.localizedDescription)"
                return out
            }
        } else {
            out.error = "couldn't fetch validators.list"
            return out
        }

        if let body = await fetchText("\(baseURL)/nabla-nodes.list"), !body.isEmpty {
            guard bodyParsesAsSeedFormat(body, fileName: "nabla-nodes.list") else {
                out.error = "remote nabla-nodes.list is malformed for the current SDK (wrong column count) — local copy left in place"
                return out
            }
            let path = "\(appDir)/nabla-nodes.list"
            do {
                try body.write(toFile: path, atomically: true, encoding: .utf8)
                out.nablaNodesBytes = body.utf8.count
            } catch {
                out.error = "nabla-nodes.list write: \(error.localizedDescription)"
                return out
            }
        } else {
            out.error = "couldn't fetch nabla-nodes.list"
            return out
        }

        if let v = remoteVersion {
            writeSeedsVersion(v, appDir: appDir)
        }
        return out
    }

    // MARK: - HTTP plumbing

    /// GET `url` as UTF-8 text. Retries up to `maxFetchAttempts` with a
    /// short escalating backoff — a wallet launched before the network
    /// is up would otherwise fail the one-shot GET and degrade to the
    /// bundled fallback. Returns `nil` once every attempt fails; the
    /// last error is logged (the failure used to be silent).
    private static func fetchText(_ url: String) async -> String? {
        guard let u = URL(string: url) else { return nil }
        var lastError = "unknown error"
        for attempt in 1...maxFetchAttempts {
            do {
                var req = URLRequest(url: u)
                req.timeoutInterval = timeoutSecs
                // Skip URLCache — we want the freshest list, not
                // whatever a proxy cached hours ago.
                req.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                if code == 200 {
                    return String(data: data, encoding: .utf8)
                }
                lastError = "HTTP \(code)"
            } catch {
                lastError = error.localizedDescription
            }
            // Short escalating backoff (0.6s, then 1.2s) before retry.
            if attempt < maxFetchAttempts {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000)
            }
        }
        NSLog("%@", "[SeedFetcher] \(url): failed after \(maxFetchAttempts) attempts — \(lastError)")
        return nil
    }

    private static func fetchInt(_ url: String) async -> Int? {
        guard let s = await fetchText(url) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Returns `true` iff every non-blank, non-comment line in `body`
    /// looks like a valid record for the seed file named `fileName`.
    /// Defensive: the SDK's parser is strict (6-col validators.list,
    /// 3-col nabla-nodes.list), and a remote `axiom-dist` that's been
    /// updated less recently than the SDK serves a body the parser
    /// refuses. Writing that body to disk would brick `sdk_setup()`.
    /// We do a cheap shape check here instead of round-tripping
    /// through the Rust parser (which would require FFI plumbing for
    /// a temp file).
    static func bodyParsesAsSeedFormat(_ body: String, fileName: String) -> Bool {
        let expectedFieldCount: Int
        switch fileName {
        case "validators.list":  expectedFieldCount = 6
        case "nabla-nodes.list": expectedFieldCount = 3
        default: return true // unknown file — pass through, let SDK decide
        }
        var sawData = false
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Cheap "is it N quoted fields?" check — count quotes,
            // expect 2N. Skips parsing escapes; the SDK does the real
            // parse downstream. Catches the old-format case (3 cols
            // served when we want 6) without false positives on
            // legitimate but oddly-quoted content.
            let quoteCount = line.filter { $0 == "\"" }.count
            if quoteCount != expectedFieldCount * 2 { return false }
            sawData = true
        }
        // Empty file (no data rows) — accept; SDK init writes a stub
        // anyway. We only reject affirmatively malformed bodies.
        return sawData || body.contains("#")
    }
}
