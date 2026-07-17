import Foundation
import CommonCrypto
import AxiomSdk

// =================================================================
// DiagnosticReport — generate a plain-text wallet diagnostic dump
// for sharing with the protocol team when chasing a hard-to-localise
// bug (e.g. the KIDDO cheque-drop or any "stuck mid-claim" report).
//
// Privacy posture:
//   - No private keys, wallet secrets, or wallet_secret_hex.
//   - Public addresses truncated to first 8 hex chars.
//   - Email shown as `<first-char>***@<domain>` (e.g. "a***@example.com")
//     so the local part doesn't leak but the domain stays useful for
//     debugging mail routing.
//   - Counterparty addresses in history truncated identically.
//   - FACT chain bytes / receipt bytes / signature bytes NEVER
//     included. Only summary counts.
//
// Output: plain-text, line-oriented. Suitable for copy/paste into
// chat, GitHub issue, or email. Or write to a file via the helper.
// =================================================================

enum DiagnosticReport {

    /// Generate the report text for a given wallet, plus app-wide
    /// context (binary SHA, version). Synchronous — file IO is fast
    /// enough that wrapping in Task adds noise.
    ///
    /// `walletDir` lets the report walk the wallet's on-disk layout
    /// (maildir, cheques/, outbox/, pairs.json) — the FFI exposes
    /// most wallet state in memory, but the filesystem layout is
    /// where the canonical evidence for transport bugs lives (e.g.
    /// the kiddo-cheque-drop investigation needs to see how many
    /// cheques actually landed in maildir/new vs how many the SDK
    /// reports as pending). If `nil`, those sections are omitted.
    static func generate(
        wallet: AxiomWallet?,
        walletDir: String? = nil,
        includeSystemContext: Bool = true
    ) -> String {
        var out = [String]()
        let timestamp = isoTimestamp()
        out.append("AXIOM Wallet Diagnostic Report")
        out.append("=" + String(repeating: "=", count: 32))
        out.append("Generated:    \(timestamp)")
        if includeSystemContext {
            out.append(contentsOf: systemContextLines())
        }
        out.append("")

        guard let w = wallet else {
            out.append("(no active wallet — report ends here)")
            return out.joined(separator: "\n") + "\n"
        }

        out.append(contentsOf: walletIdentityLines(w))
        out.append("")
        out.append(contentsOf: walletStateLines(w))
        out.append("")
        out.append(contentsOf: tardisTickLines())
        out.append("")
        out.append(contentsOf: diagnoseActionsLines(w))
        out.append("")
        out.append(contentsOf: pendingChequesLines(w))
        out.append("")
        out.append(contentsOf: scarredLinksLines(w))
        out.append("")
        out.append(contentsOf: recentHistoryLines(w, limit: 10))
        out.append("")
        out.append(contentsOf: addressLines(w))
        out.append("")
        out.append(contentsOf: lastReceiptWitnessLines(w))
        out.append("")
        if let dir = walletDir {
            out.append(contentsOf: filesystemLayoutLines(walletDir: dir))
            out.append("")
            out.append(contentsOf: maildirLines(walletDir: dir, subPath: "maildir/inbox/new", label: "INBOX/NEW (delivered, not yet processed)"))
            out.append("")
            out.append(contentsOf: maildirLines(walletDir: dir, subPath: "maildir/inbox/cur", label: "INBOX/CUR (processed, retained for audit)"))
            out.append("")
            out.append(contentsOf: chequesDirLines(walletDir: dir))
            out.append("")
            out.append(contentsOf: outboxLines(walletDir: dir))
            out.append("")
        }
        out.append(contentsOf: appRegistryLines())
        out.append("")
        out.append(contentsOf: kiddoPresenceLines())
        out.append("")
        out.append("End of report.")
        return out.joined(separator: "\n") + "\n"
    }

    /// Write the report to `~/Downloads/axiom-diagnostic-<ts>.txt`
    /// and return the resulting file URL. Throws on write failure.
    static func writeToDownloads(wallet: AxiomWallet?, walletDir: String? = nil) throws -> URL {
        let text = generate(wallet: wallet, walletDir: walletDir)
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let stamp = filenameTimestamp()
        let fileURL = downloadsURL.appendingPathComponent("axiom-diagnostic-\(stamp).txt")
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    // MARK: - Section builders

    private static func systemContextLines() -> [String] {
        var lines = [String]()
        lines.append("Wallet version: \(AxiomVersion.app) (crate \(AxiomVersion.crate))")
        // Mac binary SHA — read from /Applications since this is
        // what's actually running. If we can't read it (dev build
        // running out of swift-build), fall back to "(unknown)".
        let appBinPath = "/Applications/AxiomWallet.app/Contents/MacOS/AxiomWallet"
        if let sha = sha256OfFile(atPath: appBinPath) {
            lines.append("Mac binary SHA: \(sha.prefix(16))…")
        } else {
            lines.append("Mac binary SHA: (unable to read \(appBinPath))")
        }
        lines.append("Pool exhausted flag: \(PoolExhaustedFlag.isSet ? "SET — Claim CTA suppressed globally" : "not set")")
        return lines
    }

    private static func walletIdentityLines(_ w: AxiomWallet) -> [String] {
        var lines = [String]()
        lines.append("— WALLET IDENTITY —")
        lines.append("  Name:      \(w.name())")
        lines.append("  Email:     \(sanitizeEmail(w.email()))")
        let addr = (try? w.address()) ?? "(error)"
        lines.append("  Address:   \(truncateHex(addr, leading: 8))")
        return lines
    }

    private static func walletStateLines(_ w: AxiomWallet) -> [String] {
        var lines = [String]()
        lines.append("— WALLET STATE —")
        lines.append("  wallet_seq:                  \(w.walletSeq())")
        lines.append("  balance:                     \(w.balance()) quanta")
        lines.append("  fact_chain depth:            \(w.factLinkCount())")
        // Continuity is the field whose absence let a uj-class corrupted
        // wallet read "healthy". Derive it from diagnose() — a
        // `fact_chain_broken` action means the chain has a structural
        // continuity break (DIAGNOSE ACTIONS below carries the specifics).
        let continuityBroken = ((try? w.diagnose()) ?? [])
            .contains { $0.action == FactChainCorruption.diagnoseAction }
        lines.append("  fact_chain continuity:       \(continuityBroken ? "BROKEN — structurally corrupted (see DIAGNOSE ACTIONS)" : "OK")")
        lines.append("  scar count:                  \(w.factScarCount())")
        lines.append("  garbage states:              \(w.garbageStateIdCount())")
        lines.append("  pending cheques:             \(w.pendingChequeCount())")
        lines.append("  pending genesis register:    \(w.hasPendingGenesisRegistration() ? "yes" : "no")")
        lines.append("  client protocol version:     \(w.clientProtocolVersion())")
        lines.append("  server protocol version:     \(w.serverProtocolVersion())")
        lines.append("  min client protocol version: \(w.minClientProtocolVersion())")
        lines.append("  sdk too old:                 \(w.isSdkTooOld() ? "YES — UPDATE REQUIRED" : "no")")
        return lines
    }

    private static func diagnoseActionsLines(_ w: AxiomWallet) -> [String] {
        var lines = [String]()
        lines.append("— DIAGNOSE ACTIONS —")
        let actions = (try? w.diagnose()) ?? []
        if actions.isEmpty {
            lines.append("  (no recovery actions — wallet appears healthy)")
        } else {
            for action in actions {
                lines.append("  [\(action.action)] \(action.reason)")
                lines.append("    call=\(action.call) detail=\(action.detail)")
            }
        }
        return lines
    }

    private static func pendingChequesLines(_ w: AxiomWallet) -> [String] {
        var lines = [String]()
        lines.append("— PENDING CHEQUE BUNDLES —")
        let bundles = w.listPendingChequeBundles()
        if bundles.isEmpty {
            lines.append("  (none)")
        } else {
            for b in bundles {
                lines.append("  cheque_id=\(b.chequeId.prefix(8))…")
                lines.append("    sender=\(truncateHex(b.sender, leading: 8))")
                lines.append("    amount=\(b.amount) quanta")
                lines.append("    sigs=\(b.signatureCount)/\(b.requiredK)")
                lines.append("    status=\(b.displayStatus) (\(b.displayReason ?? "—"))")
            }
        }
        return lines
    }

    private static func scarredLinksLines(_ w: AxiomWallet) -> [String] {
        var lines = [String]()
        lines.append("— SCARRED FACT LINKS —")
        let scars = w.listScarredLinks()
        if scars.isEmpty {
            lines.append("  (none)")
        } else {
            for s in scars {
                lines.append("  link_index=\(s.linkIndex) txid=\(s.txidHex.prefix(8))… amount=\(s.amount) is_scarred=\(s.isScarred)")
            }
        }
        return lines
    }

    private static func recentHistoryLines(_ w: AxiomWallet, limit: Int) -> [String] {
        var lines = [String]()
        lines.append("— RECENT HISTORY (last \(limit)) —")
        let rows = w.history(limit: UInt32(limit))
        if rows.isEmpty {
            lines.append("  (no history)")
        } else {
            for r in rows {
                let ts = unixToReadable(r.timestamp)
                let cp = truncateHex(r.counterparty, leading: 8)
                let ref = r.reference.map { " ref=\($0)" } ?? ""
                lines.append("  \(ts)  \(r.txType.padding(toLength: 8, withPad: " ", startingAt: 0))  \(r.amount) quanta  \(cp)  txid=\(r.txid.prefix(8))…\(ref)")
            }
        }
        return lines
    }

    /// Validator IDs from the wallet's most-recent receipt. The
    /// canonical "which validators witnessed my last TX" answer.
    /// Cross-check note clarifies the kind of TX the IDs came from
    /// because the visible artifact in maildir depends on the TX
    /// type.
    private static func lastReceiptWitnessLines(_ w: AxiomWallet) -> [String] {
        var lines = [String]()
        lines.append("— LAST RECEIPT WITNESS IDS —")
        let ids = w.lastReceiptWitnessIds()
        if ids.isEmpty {
            lines.append("  (no receipt — wallet may not have transacted yet)")
        } else {
            lines.append("  k=\(ids.count) validator(s) witnessed the last TX:")
            for id in ids {
                lines.append("    \(id.prefix(16))…")
            }
            lines.append("  Note: these are 64-char crypto `validator_id`s (BLAKE3 of the validator's SPHINCS pk). The maildir below shows .eml `From:` handles (e.g. eta/alpha/kappa) which the SDK does NOT map back to validator_ids in this report — correlate by mentally pairing the k=\(ids.count) IDs above with the k senders in maildir.")
            lines.append("  TX-type interpretation:")
            lines.append("    SEND / GENESIS_CLAIM   → expect k cheques from k distinct senders in maildir.")
            lines.append("    REDEEM                  → no new cheques are issued; expect k §4.6 verify confirmations instead.")
            lines.append("    HEAL                    → expect k self-witness cheques (sender == receiver).")
            lines.append("  Canonical transport-drop fingerprint: k senders in receipt vs <k distinct senders in maildir for the matching TX.")
        }
        return lines
    }

    private static func addressLines(_ w: AxiomWallet) -> [String] {
        var lines = [String]()
        lines.append("— TIER ADDRESSES —")
        let addrs = (try? w.allAddresses()) ?? []
        if addrs.isEmpty {
            lines.append("  (none — wallet may not be fully constructed)")
        } else {
            lines.append("  \(addrs.count) tier address(es) derived")
            for a in addrs {
                lines.append("    \(a.displayName) (k=\(a.k))  \(truncateHex(a.address, leading: 12))")
            }
        }
        return lines
    }

    // MARK: - Filesystem inspection

    private static func filesystemLayoutLines(walletDir: String) -> [String] {
        var lines = [String]()
        lines.append("— WALLET DIRECTORY LAYOUT —")
        lines.append("  Path: \(walletDir)")
        let fm = FileManager.default
        guard fm.fileExists(atPath: walletDir) else {
            lines.append("  (directory does not exist on disk)")
            return lines
        }
        // Per-wallet files. pairs.json / validators.list / nablas.list
        // are NOT per-wallet — they live at app level (see
        // appRegistryLines). The per-wallet items are wallet.axiom and
        // wallet.lock; everything else here is a subdirectory.
        for entry in ["wallet.axiom", "wallet.lock"] {
            let p = walletDir + "/" + entry
            lines.append("  \(entry): \(fileSummary(path: p))")
        }
        for subdir in ["maildir", "maildir/inbox", "maildir/inbox/new", "maildir/inbox/cur", "maildir/inbox/tmp", "cheques", "outbox", "outbox-tot"] {
            let p = walletDir + "/" + subdir
            if fm.fileExists(atPath: p) {
                let count = (try? fm.contentsOfDirectory(atPath: p).count) ?? -1
                lines.append("  \(subdir)/: \(count >= 0 ? "\(count) entr\(count == 1 ? "y" : "ies")" : "(unreadable)")")
            } else {
                lines.append("  \(subdir)/: (missing)")
            }
        }
        return lines
    }

    /// List files in a maildir subdirectory with sanitised From / Subject
    /// headers extracted from the .eml. Caps the listing at 20 entries
    /// (most recent by mtime) so a stuck wallet with thousands of
    /// retained messages doesn't blow up the report.
    private static func maildirLines(walletDir: String, subPath: String, label: String) -> [String] {
        var lines = [String]()
        lines.append("— MAILDIR \(label) —")
        let dir = walletDir + "/" + subPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir) else {
            lines.append("  (directory does not exist)")
            return lines
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
            lines.append("  (unreadable)")
            return lines
        }
        if entries.isEmpty {
            lines.append("  (empty)")
            return lines
        }
        let counts = subjectPrefixCounts(dir: dir, entries: entries)
        lines.append("  Total: \(entries.count) message(s)")
        lines.append("  Subject-prefix counts: cheque=\(counts.cheque) witness_response=\(counts.witnessResponse) error=\(counts.error) other=\(counts.other)")
        if counts.error > 0 {
            lines.append("  ⚠ \(counts.error) AXIOM/error/* response(s) present — see per-file entries below for the extracted SDK error code.")
        }
        // Sort by mtime descending so the most-recent show first.
        struct Entry { let name: String; let mtime: Date; let size: Int64 }
        let enriched: [Entry] = entries.compactMap { name in
            let path = dir + "/" + name
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = attrs[.size] as? NSNumber else {
                return nil
            }
            return Entry(name: name, mtime: mtime, size: size.int64Value)
        }.sorted { $0.mtime > $1.mtime }
        let limit = 20
        let listed = enriched.prefix(limit)
        for e in listed {
            let ts = isoTimestamp(e.mtime)
            let headers = readEmlHeaders(path: dir + "/" + e.name)
            let from = headers["from"].map(sanitizeEmailHeader) ?? "(no From)"
            let to = headers["to"].map(sanitizeEmailHeader) ?? "(no To)"
            let date = headers["date"].map { truncate($0, max: 60) } ?? "(no Date)"
            let messageId = headers["message-id"].map { truncate($0, max: 70) } ?? "(no Message-Id)"
            let subj = headers["subject"].map { truncate($0, max: 60) } ?? "(no Subject)"
            let ctype = headers["content-type"].map { truncate($0, max: 50) } ?? "(no Content-Type)"
            lines.append("  filename=\(e.name)")
            lines.append("    mtime=\(ts)  size=\(e.size)")
            lines.append("    From:        \(from)")
            lines.append("    To:          \(to)")
            lines.append("    Date:        \(date)")
            lines.append("    Subject:     \(subj)")
            lines.append("    Message-Id:  \(messageId)")
            lines.append("    Content-Type:\(ctype)")
            // For AXIOM/error/* responses, parse the body and surface
            // the SDK error code — the kiddo-cheque-drop investigation
            // showed that "1/3 sigs" partials can be transport drops
            // OR validator rejections; the error code (if present)
            // distinguishes them.
            if (headers["subject"] ?? "").hasPrefix("AXIOM/error/") {
                if let ec = Self.extractErrorCodeFromEml(path: dir + "/" + e.name) {
                    lines.append("    ⚠ Error code: \(ec)")
                } else {
                    lines.append("    ⚠ Error code: (parse failed — body didn't yield an E_* token)")
                }
            }
        }
        if enriched.count > limit {
            lines.append("  ... and \(enriched.count - limit) older message(s) elided")
        }
        return lines
    }

    private static func chequesDirLines(walletDir: String) -> [String] {
        var lines = [String]()
        lines.append("— CHEQUES DIRECTORY (on-disk pending bundles) —")
        let dir = walletDir + "/cheques"
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir),
              let entries = try? fm.contentsOfDirectory(atPath: dir) else {
            lines.append("  (none or unreadable)")
            return lines
        }
        if entries.isEmpty {
            lines.append("  (empty)")
            return lines
        }
        lines.append("  Total: \(entries.count) file(s)")
        for name in entries.sorted() {
            let path = dir + "/" + name
            let attrs = try? fm.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date).map(isoTimestamp) ?? "(no mtime)"
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            lines.append("  \(name)  size=\(size)  mtime=\(mtime)")
        }
        return lines
    }

    private static func outboxLines(walletDir: String) -> [String] {
        var lines = [String]()
        lines.append("— OUTBOX (UMP envelopes awaiting transport) —")
        // outbox/ is maildir-structured: outbox/{tmp,new,sent,failed}/
        // — each holding actual envelope files. Walking the top level
        // would just show the subdirectory names (the first cut of this
        // report did exactly that, which was useless). Walk one deeper.
        let fm = FileManager.default
        for root in ["outbox", "outbox-tot"] {
            let rootDir = walletDir + "/" + root
            if !fm.fileExists(atPath: rootDir) {
                lines.append("  \(root)/: (missing)")
                continue
            }
            // Discover whatever subdirs exist (the structure may vary
            // across outbox variants — outbox-tot uses a different
            // layout than outbox for the TOT carrier).
            guard let subs = try? fm.contentsOfDirectory(atPath: rootDir) else {
                lines.append("  \(root)/: (unreadable)")
                continue
            }
            if subs.isEmpty {
                lines.append("  \(root)/: (empty top level)")
                continue
            }
            for sub in subs.sorted() {
                let subDir = rootDir + "/" + sub
                var isDir: ObjCBool = false
                fm.fileExists(atPath: subDir, isDirectory: &isDir)
                if !isDir.boolValue {
                    // Flat file at the root (rare) — show as-is.
                    let attrs = try? fm.attributesOfItem(atPath: subDir)
                    let mtime = (attrs?[.modificationDate] as? Date).map(isoTimestamp) ?? "(no mtime)"
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    lines.append("  \(root)/\(sub)  size=\(size)  mtime=\(mtime)  (file)")
                    continue
                }
                let entries = (try? fm.contentsOfDirectory(atPath: subDir)) ?? []
                lines.append("  \(root)/\(sub)/: \(entries.count) envelope(s)")
                for name in entries.sorted().prefix(10) {
                    let attrs = try? fm.attributesOfItem(atPath: subDir + "/" + name)
                    let mtime = (attrs?[.modificationDate] as? Date).map(isoTimestamp) ?? "(no mtime)"
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    lines.append("    \(name)  size=\(size)  mtime=\(mtime)")
                }
                if entries.count > 10 {
                    lines.append("    ... and \(entries.count - 10) more elided")
                }
            }
        }
        return lines
    }

    /// App-level wallet registry — `pairs.json`, `validators.list`,
    /// `nablas.list` live at `~/Library/Application Support/Axiom/wallets/`,
    /// NOT in per-wallet subdirectories. The first cut of this report
    /// looked for them inside the wallet dir and reported them missing,
    /// which was wrong: the files were fine, just elsewhere.
    private static func appRegistryLines() -> [String] {
        var lines = [String]()
        lines.append("— APP-LEVEL WALLET REGISTRY —")
        let root = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Axiom/wallets")
        lines.append("  Path: \(root)")
        let fm = FileManager.default
        if !fm.fileExists(atPath: root) {
            lines.append("  (directory does not exist)")
            return lines
        }
        for entry in ["pairs.json", "validators.list", "nablas.list"] {
            let p = root + "/" + entry
            lines.append("  \(entry): \(fileSummary(path: p))")
        }
        // Enumerate the per-wallet subdirectories so a reader can see
        // every pair-name + mode combination installed on this Mac.
        if let entries = try? fm.contentsOfDirectory(atPath: root) {
            let walletDirs = entries.filter { name in
                var isDir: ObjCBool = false
                fm.fileExists(atPath: root + "/" + name, isDirectory: &isDir)
                return isDir.boolValue
            }.sorted()
            lines.append("  Per-wallet subdirectories: \(walletDirs.count)")
            for name in walletDirs.prefix(20) {
                lines.append("    \(name)/")
            }
            if walletDirs.count > 20 {
                lines.append("    ... and \(walletDirs.count - 20) more elided")
            }
        }
        return lines
    }

    private static func kiddoPresenceLines() -> [String] {
        var lines = [String]()
        lines.append("— KIDDO (mail relay) ACCESSIBILITY —")
        let kiddoPath = "/Applications/AxiomKiddo.app"
        let fm = FileManager.default
        if fm.fileExists(atPath: kiddoPath) {
            let binPath = "\(kiddoPath)/Contents/MacOS/AxiomKiddo"
            if let sha = sha256OfFile(atPath: binPath) {
                lines.append("  Installed: \(kiddoPath)")
                lines.append("  Binary SHA (first 16): \(sha.prefix(16))…")
            } else {
                lines.append("  Installed: \(kiddoPath) (binary unreadable)")
            }
        } else {
            lines.append("  NOT INSTALLED at \(kiddoPath)")
            lines.append("  → cheques will not be delivered unless an alternate transport is configured")
        }
        let kiddoRunning = pgrepKiddo()
        lines.append("  Process: \(kiddoRunning ? "running" : "not running (or pgrep failed)")")
        return lines
    }

    private static func tardisTickLines() -> [String] {
        var lines = [String]()
        lines.append("— LAST OBSERVED NABLA TARDIS TICK —")
        let sdkTick = sdkLastNablaTick()
        let sdkSeenAt = sdkLastNablaSeenAt()
        let persisted = LastNablaTickStore.persisted
        lines.append("  SDK in-process:  tick=\(sdkTick)  seen_at=\(formatTickTimestamp(sdkSeenAt))")
        lines.append("  Persisted:       tick=\(persisted.tick)  seen_at=\(formatTickTimestamp(persisted.seenAt))")
        let (effTick, effSeenAt) = LastNablaTickStore.effective(
            sdkTick: sdkTick, sdkSeenAt: sdkSeenAt,
        )
        if effTick == 0 || effSeenAt == 0 {
            lines.append("  Effective: (no tick observed)")
            lines.append("  Note: if a register completed this Mac but tick=0 still, the validator's FactConfirmResponse likely had no `tick` field (dev env validators that don't populate it). YP §17.10.5.3 / sdk/client/src/nabla.rs:1602-1611.")
        } else {
            let now = Date()
            let age = max(0, Int(now.timeIntervalSince1970) - Int(effSeenAt))
            let ageHuman: String
            if age < 60 { ageHuman = "\(age) sec" }
            else if age < 3600 { ageHuman = "\(age / 60) min" }
            else if age < 86400 { ageHuman = "\(age / 3600) hr" }
            else { ageHuman = "\(age / 86400) day" }
            lines.append("  Effective:       tick=\(effTick)  seen_at=\(formatTickTimestamp(effSeenAt))")
            lines.append("  Elapsed since:   +\(ageHuman) (wall-clock)")
        }
        return lines
    }

    private static func formatTickTimestamp(_ unixSecs: UInt64) -> String {
        if unixSecs == 0 { return "0 (not set)" }
        return isoTimestamp(Date(timeIntervalSince1970: TimeInterval(unixSecs)))
    }

    // MARK: - Helpers

    private static func isoTimestamp() -> String {
        return isoTimestamp(Date())
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    private static func fileSummary(path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path) else {
            return "(missing)"
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date).map(isoTimestamp) ?? "(no mtime)"
        return "size=\(size)  mtime=\(mtime)"
    }

    /// Parse an `AXIOM/error/...` .eml file and return the SDK error
    /// code embedded in its body. Returns nil if the file doesn't
    /// look like an error response or no code is found.
    ///
    /// Format: .eml body is base64-encoded CBOR (UMP envelope wrapping
    /// an error payload). We don't fully decode the CBOR — we
    /// base64-decode the body and then search the decoded bytes for
    /// an `E_<UPPERCASE>+` pattern (the canonical error-code prefix
    /// per axiom-errors/src/error_code.rs §7). Robust to whatever
    /// outer envelope shape the SDK happens to wrap the code in;
    /// only relies on the error code itself being a UTF-8 string in
    /// the CBOR payload.
    static func extractErrorCodeFromEml(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // Error .emls are tiny (~500 bytes); 4 KB is plenty.
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let sepRange = normalised.range(of: "\n\n") else { return nil }
        let bodyText = normalised[sepRange.upperBound...]
        let base64 = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = Data(
            base64Encoded: base64,
            options: .ignoreUnknownCharacters,
        ) else { return nil }
        return scanForErrorCode(decoded)
    }

    /// Byte-level scan for an `E_<UPPERCASE>+` token. Doesn't depend
    /// on the decoded bytes being valid UTF-8 — CBOR text strings
    /// are length-prefixed but their content is ASCII for our error
    /// codes, so a raw byte search hits the same characters.
    private static func scanForErrorCode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        var i = 0
        while i + 4 < bytes.count {
            // Look for "E_" (0x45, 0x5F) followed by ≥3 uppercase /
            // underscore bytes.
            if bytes[i] == 0x45 && bytes[i + 1] == 0x5F {
                var end = i + 2
                while end < bytes.count {
                    let b = bytes[end]
                    if (b >= 0x41 && b <= 0x5A) || b == 0x5F { end += 1 }
                    else { break }
                }
                if end - i >= 5 {  // at least "E_XYZ"
                    return String(bytes: bytes[i..<end], encoding: .ascii)
                }
                i = end
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Tally `.eml` filenames by their AXIOM/... subject prefix. The
    /// per-file maildir listing shows each Subject in full; this
    /// summary makes the ratio at a glance (e.g. "6 errors, 3
    /// witness_responses, 0 cheques" — that's a validator-rejection
    /// pattern, not a transport-drop pattern).
    private static func subjectPrefixCounts(dir: String, entries: [String]) -> (
        cheque: Int, witnessResponse: Int, error: Int, other: Int
    ) {
        var cheque = 0, wr = 0, err = 0, other = 0
        for name in entries {
            let headers = readEmlHeaders(path: dir + "/" + name)
            let subj = headers["subject"] ?? ""
            if subj.hasPrefix("AXIOM/cheque/") { cheque += 1 }
            else if subj.hasPrefix("AXIOM/witness_response/") { wr += 1 }
            else if subj.hasPrefix("AXIOM/error/") { err += 1 }
            else { other += 1 }
        }
        return (cheque, wr, err, other)
    }

    /// Read the headers of a file (capped at 8 KB) and return a map
    /// of lowercased header name → value. Stops at the first blank
    /// line.
    ///
    /// Handles both LF and CRLF line endings explicitly: the .eml
    /// files written by FATMAMA / TOT carriers use CRLF, and an
    /// earlier version of this parser split on `\n` only and trimmed
    /// with `.whitespaces` (which does NOT include `\r`). Result: the
    /// blank-line "end of headers" break never fired (a `\r` line
    /// trimmed to itself, not empty), and every header value got a
    /// stray trailing CR that messed up downstream display. Now we
    /// normalise CRLF → LF up front and trim with
    /// `.whitespacesAndNewlines`.
    /// Public alias for `readEmlHeaders` — exposed for the dev-tools
    /// inspect path. Same behaviour.
    static func readEmlHeadersPublic(path: String) -> [String: String] {
        readEmlHeaders(path: path)
    }

    private static func readEmlHeaders(path: String) -> [String: String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [:] }
        defer { try? handle.close() }
        let cap = 8192
        let data = (try? handle.read(upToCount: cap)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var headers = [String: String]()
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { break }  // end of headers
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = String(trimmed[..<colon])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !value.isEmpty {
                headers[name] = value
            }
        }
        return headers
    }

    /// Sanitize a `From: …` header value. Keeps the domain visible
    /// (useful for transport routing debug) but redacts the local
    /// part. Handles both bare `addr@host` and full `Name <addr@host>`
    /// forms. On parse failure, returns the entire string truncated.
    private static func sanitizeEmailHeader(_ raw: String) -> String {
        // Extract the addr — between < and >, or the whole string if
        // no angle brackets.
        let addr: String
        if let lt = raw.firstIndex(of: "<"), let gt = raw.lastIndex(of: ">"), lt < gt {
            addr = String(raw[raw.index(after: lt)..<gt])
        } else {
            addr = raw
        }
        return sanitizeEmail(addr)
    }

    private static func truncate(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        return "\(s.prefix(max))…"
    }

    private static func pgrepKiddo() -> Bool {
        // pgrep returns 0 if matches found, 1 otherwise. Synchronous
        // — fast enough on Mac for a button-click report path.
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-f", "AxiomKiddo"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func filenameTimestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.string(from: Date())
    }

    private static func unixToReadable(_ ts: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }

    /// Sanitise an email's local part: keep the first 4 chars (or
    /// fewer if shorter) and mark the truncation with `***`. Domain
    /// always shown in full (useful for transport-routing debug).
    /// The first 4 chars are enough to distinguish typical dev
    /// validator handles (alpha / beta / gamma / kappa / eta etc.)
    /// while still scrubbing user-style addresses (alice@example.com
    /// → a***@example.com). Tradeoff documented: this report is
    /// opt-in shared, so a 4-char prefix is an acceptable middle
    /// ground between "shows the validator" and "doesn't leak the
    /// whole local part."
    private static func sanitizeEmail(_ email: String) -> String {
        guard let atIdx = email.firstIndex(of: "@") else { return "(malformed)" }
        let local = email[..<atIdx]
        let domain = email[atIdx...]
        if local.isEmpty { return "(empty local)\(domain)" }
        if local.count <= 4 { return "\(local)\(domain)" }
        return "\(local.prefix(4))***\(domain)"
    }

    /// Truncate a hex-string to its first `leading` chars + "…".
    /// If the string is shorter than `leading`, return as-is.
    private static func truncateHex(_ s: String, leading: Int) -> String {
        if s.count <= leading { return s }
        return "\(s.prefix(leading))…"
    }

    /// Compute SHA-256 of a file at the given path. Returns lowercase
    /// hex, or nil on read failure. Synchronous + uses
    /// CryptoKit via Foundation; small files (the wallet binary is
    /// ~5MB) complete in <100ms on Apple Silicon.
    private static func sha256OfFile(atPath path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // Use a streaming digest to avoid loading the whole binary
        // into memory. Foundation doesn't ship a streaming hasher in
        // older SDKs, so a one-shot read of the binary's bytes is
        // acceptable here — caller is on Settings → button click.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let hash = data.sha256Lowercased()
        return hash
    }
}

// Lightweight SHA-256 helper via CommonCrypto. Defensive choice over
// CryptoKit's `SHA256` to keep us off the CryptoKit version dance
// across deployment targets (we set .macOS(.v14) but the helper is
// trivial enough to not depend on a newer-SDK path).
private extension Data {
    func sha256Lowercased() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(self.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
