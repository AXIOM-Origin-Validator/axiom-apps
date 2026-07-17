import SwiftUI
import AppKit
import Foundation
import AxiomSdk

// =================================================================
// WalletDevTools — destructive ops + factory reset, passcode-gated,
// reachable from the wallet's Settings → Advanced.
//
// Three operations, each behind an independent ack checkbox:
//
//   1. Clear retained cheque audit log (active wallet)
//      — narrow housekeeping. Removes `maildir/inbox/cur/*` for the
//        active wallet only. wallet.axiom untouched; balance + history
//        + pending bundles all survive. Safe for users who just want
//        to declutter the .eml audit retention.
//
//   2. Clear ALL wallet maildirs + outbox + cheques (every wallet)
//      — broad sweep. Walks every wallet directory under
//        `~/Library/Application Support/Axiom/wallets/` and empties
//        maildir/inbox/{new,cur,tmp}, outbox/{tmp,new,sent,failed},
//        outbox-tot/, and cheques/. wallet.axiom still untouched, but
//        any un-redeemed bundle in cheques/ is gone — destructive if
//        a partial bundle hasn't been processed.
//
//   3. Reset AxiomKiddo
//      — terminates the Kiddo process if running, removes Kiddo's
//        accounts.json from `~/Library/Application Support/AxiomKiddo/`.
//        Keychain entries are NOT cleared (cross-app keychain delete
//        needs an entitlement we don't have under ad-hoc signing) —
//        they become orphaned but harmless (each is keyed by a UUID
//        that no longer exists in accounts.json). The UI notes this.
//
// Passcode-gated entry: same passcode as Kiddo's dev-account add
// flow ("fatmama approve axiom"). Wrong passcode dismisses silently.
// =================================================================

private let kWalletDevPasscode = "fatmama approve axiom"

extension SettingsView {
    // Marker so AdvancedSection can find this file in grep — no actual
    // logic here; AdvancedSection embeds the cards inline.
}

// Wallet-side passcode prompt. Mirrors Kiddo's PasscodeGateSheet:
// bland title, no hint about what's being unlocked, wrong passcode
// dismisses silently. Cheap "discoverability brake" for a feature
// that's destructive if accidentally triggered.
struct WalletDevPasscodeSheet: View {
    let onSubmit: (String) -> Void
    @State private var entered: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter passcode")
                .font(.headline)
            SecureField("Passcode", text: $entered)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Cancel") {
                    entered = ""
                    onSubmit("")
                }
                .keyboardShortcut(.cancelAction)
                Button("OK") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func submit() {
        let v = entered
        entered = ""
        onSubmit(v)
    }
}

/// Test the passcode the user typed against the canonical value.
/// Single-call check, then dismissed by the caller.
func walletDevPasscodeMatches(_ entered: String) -> Bool {
    entered == kWalletDevPasscode
}

struct WalletDevToolsSheet: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.openWindow) private var openWindow
    let onDone: () -> Void

    @State private var ackNarrow: Bool = false
    @State private var ackBroad: Bool = false
    @State private var ackKiddo: Bool = false
    @State private var resultLines: [String] = []
    /// Inspect-only action: no ack needed, no destructive effect.
    @State private var inspectInProgress: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DEV TOOLS")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text("Destructive operations — read carefully")
                .font(.system(size: 16, weight: .semibold))
            Text("Three operations, in increasing destructiveness. Each has its own ack checkbox so you can use one without arming the others.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            #if DEBUG
            faultInjectionLaunchCard
            #endif
            sendStateReferenceCard
            inspectErrorsCard
            narrowCard
            broadCard
            kiddoResetCard

            if !resultLines.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(resultLines.indices, id: \.self) { idx in
                            Text(resultLines[idx])
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(maxHeight: 180)
                .background(DesignTokens.bgPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Close", action: onDone)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 580)
    }

    // MARK: - Cards

    #if DEBUG
    /// Launches the standalone Fault Injection window (a SEPARATE window
    /// that co-exists with the main wallet, so a tester can arm faults and
    /// drive the wallet at the same time — a modal card here would block
    /// the very operations under test). DEBUG-only.
    @ViewBuilder
    private var faultInjectionLaunchCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fault injection — open the tester panel")
                .font(.system(size: 13, weight: .medium))
            Text("Opens a separate, always-on-top-capable window with tickable fault switches (scarred sends, Core-rejected sends, partial commits). It stays open alongside the wallet so you can arm a fault, run the operation here, then clear it. The main window shows a red banner whenever a fault is armed.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openWindow(id: faultInjectionWindowID)
                onDone()   // close this modal so the panel + wallet are both usable
            } label: {
                Label("Open Fault Injection panel", systemImage: "ladybug.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 2)
        }
        .padding(10)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    #endif // DEBUG

    /// Permanent, non-destructive REFERENCE render of the transient
    /// "resumable send" affordance, with representative sample data — so a
    /// contributor can see exactly what it looks like without having to
    /// reproduce a timed-out witness round on a busy env. Renders the SAME
    /// `ResumableSendCard` component the live Send pane uses (buttons inert
    /// here). The card only appears organically on Send when a round is
    /// actually resumable; this is the always-available reference for it.
    @ViewBuilder
    private var sendStateReferenceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Send-state reference — resumable send (read-only)")
                .font(.system(size: 13, weight: .medium))
            Text("Reference render of the “interrupted send — resumable” card shown on the Send pane. It appears there only when a witness hop TIMED OUT (not a rejection/completion), the quorum wasn’t reached, and the wallet hasn’t moved since — see sdk/client/src/send.rs (pending_round) + resume_send/discard_resumable_send in the FFI. Buttons are inert here; this is a contributor reference so the affordance is always visible.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            ResumableSendCard(row: ResumableSendCard.sampleRow, isReference: true)
                .padding(.top, 4)
        }
        .padding(10)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var inspectErrorsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inspect error responses in maildir (read-only)")
                .font(.system(size: 13, weight: .medium))
            Text("Scans every wallet's maildir/inbox/{new,cur} for AXIOM/error/* .eml files. For each: shows the validator handle (From), timestamp, error code extracted from the base64 body (E_* token via byte-scan, no full CBOR decode), and the AXIOM/error/<uuid> subject. No file is modified or deleted. The kiddo-cheque-drop investigation needs this to distinguish transport-drops (no .eml at all) from validator rejections (.eml with AXIOM/error subject + extractable error code).")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Button(inspectInProgress ? "Scanning…" : "Scan and list errors") {
                runErrorInspect()
            }
                .disabled(inspectInProgress)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var narrowCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Clear retained cheque audit log (active wallet only)")
                .font(.system(size: 13, weight: .medium))
            Text("Removes every .eml in this wallet's maildir/inbox/cur — the audit retention of already-processed cheques. wallet.axiom is untouched, balance + history + pending bundles in cheques/ all survive. Safe housekeeping for users who just want to declutter.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("I understand this only clears the audit retention; wallet state is preserved.", isOn: $ackNarrow)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Button("Clear audit log") { runNarrow() }
                .disabled(!ackNarrow)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var broadCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Clear ALL wallet maildirs + outbox + cheques (every wallet)")
                .font(.system(size: 13, weight: .medium))
            Text("Walks every wallet directory on this Mac and empties maildir/inbox/{new,cur,tmp}, outbox/{tmp,new,sent,failed}, outbox-tot/, and cheques/. wallet.axiom is untouched, but any un-redeemed bundle in cheques/ is destroyed — use only on a clean baseline you don't mind losing.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("I understand this destroys un-redeemed cheque bundles in every wallet on this Mac.", isOn: $ackBroad)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Button("Clear everything (every wallet)") { runBroad() }
                .disabled(!ackBroad)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var kiddoResetCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reset AxiomKiddo")
                .font(.system(size: 13, weight: .medium))
            Text("Terminates the Kiddo process (if running) and removes Kiddo's accounts.json. Keychain entries are left in place (cross-app keychain delete needs an entitlement this build doesn't have under ad-hoc signing) — they become orphaned UUIDs that don't tie back to any account, and don't interfere with a fresh Kiddo setup. Use `Keychain Access.app` to remove them manually if desired.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("I understand this wipes every Kiddo account configuration.", isOn: $ackKiddo)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Button("Reset Kiddo now") { runKiddoReset() }
                .disabled(!ackKiddo)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Paths

    private var appSupportRoot: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support")
    }

    private var walletsRootPath: String {
        appSupportRoot + "/Axiom/wallets"
    }

    private var kiddoAccountsJsonPath: String {
        appSupportRoot + "/AxiomKiddo/accounts.json"
    }

    private var activeWalletDir: String? {
        guard let pair = session.activePair else { return nil }
        let modeSuffix: String
        switch session.activeMode {
        case .normal: modeSuffix = "normal"
        case .ark:    modeSuffix = "ark"
        }
        return walletsRootPath + "/" + pair.name + "-" + modeSuffix
    }

    // MARK: - Actions

    /// Read-only inspection: walk every wallet's maildir/inbox/{new,cur},
    /// find AXIOM/error/* .emls, parse each body for an E_* error code,
    /// dump the findings to resultLines. No file is modified.
    private func runErrorInspect() {
        inspectInProgress = true
        var log = [String]()
        log.append("[\(stamp())] Walking \(walletsRootPath)…")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: walletsRootPath) else {
            log.append("[\(stamp())] (root unreadable — nothing to inspect)")
            resultLines = log
            inspectInProgress = false
            return
        }
        var totalErrorCount = 0
        var codeTally: [String: Int] = [:]
        for wallet in entries.sorted() {
            let walletDir = walletsRootPath + "/" + wallet
            var isDir: ObjCBool = false
            fm.fileExists(atPath: walletDir, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            var walletErrors: [(when: Date, name: String, dir: String)] = []
            for sub in ["maildir/inbox/new", "maildir/inbox/cur"] {
                let subPath = walletDir + "/" + sub
                guard fm.fileExists(atPath: subPath),
                      let files = try? fm.contentsOfDirectory(atPath: subPath) else { continue }
                for f in files {
                    let fullPath = subPath + "/" + f
                    // Cheap subject extraction; defer full body parse
                    // to the matched-error path.
                    let headers = DiagnosticReport.readEmlHeadersPublic(path: fullPath)
                    let subj = headers["subject"] ?? ""
                    guard subj.hasPrefix("AXIOM/error/") else { continue }
                    let mtime = (try? fm.attributesOfItem(atPath: fullPath))
                        .flatMap { $0[.modificationDate] as? Date } ?? .distantPast
                    walletErrors.append((mtime, f, sub))
                }
            }
            if walletErrors.isEmpty { continue }
            log.append("[\(stamp())] \(wallet)/")
            walletErrors.sort { $0.when > $1.when }
            for entry in walletErrors {
                let fullPath = walletDir + "/" + entry.dir + "/" + entry.name
                let headers = DiagnosticReport.readEmlHeadersPublic(path: fullPath)
                let from = headers["from"] ?? "(no From)"
                let subj = headers["subject"] ?? ""
                let code = DiagnosticReport.extractErrorCodeFromEml(path: fullPath) ?? "(unparsed)"
                let when = isoTimestamp(entry.when)
                log.append("[\(stamp())]   \(when)  \(entry.dir)/\(entry.name)")
                log.append("[\(stamp())]     From: \(from)")
                log.append("[\(stamp())]     Subject: \(subj)")
                log.append("[\(stamp())]     Error code: \(code)")
                totalErrorCount += 1
                codeTally[code, default: 0] += 1
            }
        }
        log.append("[\(stamp())] Total: \(totalErrorCount) error response(s) across all wallets.")
        if !codeTally.isEmpty {
            log.append("[\(stamp())] Tally by error code:")
            for (code, n) in codeTally.sorted(by: { $0.value > $1.value }) {
                log.append("[\(stamp())]   \(code): \(n)")
            }
        }
        resultLines = log
        inspectInProgress = false
    }

    private func isoTimestamp(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    private func runNarrow() {
        var log = [String]()
        guard let walletDir = activeWalletDir else {
            log.append("[\(stamp())] No active wallet — nothing to clear.")
            resultLines = log
            return
        }
        log.append("[\(stamp())] Active wallet: \(walletDir)")
        let cur = walletDir + "/maildir/inbox/cur"
        log.append(contentsOf: clearDir(cur, label: "maildir/inbox/cur"))
        log.append("[\(stamp())] Done.")
        resultLines = log
        ackNarrow = false
    }

    private func runBroad() {
        var log = [String]()
        log.append("[\(stamp())] Walking \(walletsRootPath)…")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: walletsRootPath) else {
            log.append("[\(stamp())] (root unreadable — nothing to clear)")
            resultLines = log
            return
        }
        let subdirsToClear = [
            "maildir/inbox/new",
            "maildir/inbox/cur",
            "maildir/inbox/tmp",
            "outbox/tmp",
            "outbox/new",
            "outbox/sent",
            "outbox/failed",
            "outbox-tot",
            "cheques",
        ]
        var totalFiles = 0
        var walletsTouched = 0
        for wallet in entries.sorted() {
            let walletDir = walletsRootPath + "/" + wallet
            var isDir: ObjCBool = false
            fm.fileExists(atPath: walletDir, isDirectory: &isDir)
            guard isDir.boolValue else { continue }
            log.append("[\(stamp())] \(wallet)/")
            walletsTouched += 1
            for sub in subdirsToClear {
                let subPath = walletDir + "/" + sub
                if let countRemoved = countAndRemoveAll(subPath) {
                    if countRemoved > 0 {
                        log.append("[\(stamp())]   \(sub)/: removed \(countRemoved) file(s)")
                        totalFiles += countRemoved
                    }
                }
            }
        }
        log.append("[\(stamp())] Done. Removed \(totalFiles) file(s) across \(walletsTouched) wallet director\(walletsTouched == 1 ? "y" : "ies").")
        resultLines = log
        ackBroad = false
    }

    private func runKiddoReset() {
        var log = [String]()
        log.append("[\(stamp())] Looking for AxiomKiddo process…")
        let runningKiddos = NSRunningApplication.runningApplications(
            withBundleIdentifier: "org.axiom.AxiomKiddo",
        )
        if runningKiddos.isEmpty {
            log.append("[\(stamp())] Kiddo not running.")
        } else {
            for k in runningKiddos {
                let pid = k.processIdentifier
                let ok = k.terminate()
                log.append("[\(stamp())] terminate(pid=\(pid)) → \(ok ? "OK" : "REFUSED")")
            }
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: kiddoAccountsJsonPath) {
            do {
                try fm.removeItem(atPath: kiddoAccountsJsonPath)
                log.append("[\(stamp())] Deleted \(kiddoAccountsJsonPath).")
            } catch {
                log.append("[\(stamp())] WARN failed to delete accounts.json: \(error.localizedDescription)")
            }
        } else {
            log.append("[\(stamp())] accounts.json already absent at \(kiddoAccountsJsonPath).")
        }
        log.append("[\(stamp())] Keychain entries left in place (orphaned, harmless).")
        log.append("[\(stamp())] Done.")
        resultLines = log
        ackKiddo = false
    }

    // MARK: - Helpers

    /// Empty a directory's contents (files only). Returns log lines
    /// for inclusion in the result pane.
    private func clearDir(_ path: String, label: String) -> [String] {
        var log = [String]()
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            log.append("[\(stamp())] \(label): (missing — nothing to clear)")
            return log
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else {
            log.append("[\(stamp())] \(label): (unreadable)")
            return log
        }
        if entries.isEmpty {
            log.append("[\(stamp())] \(label): (empty — nothing to clear)")
            return log
        }
        var removed = 0
        for f in entries {
            if (try? fm.removeItem(atPath: path + "/" + f)) != nil {
                removed += 1
            }
        }
        log.append("[\(stamp())] \(label): removed \(removed) of \(entries.count) file(s)")
        return log
    }

    /// Variant for the broad-clear path — returns the count without
    /// generating log lines (caller decides whether to log).
    private func countAndRemoveAll(_ path: String) -> Int? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let entries = try? fm.contentsOfDirectory(atPath: path) else {
            return nil
        }
        var removed = 0
        for f in entries {
            if (try? fm.removeItem(atPath: path + "/" + f)) != nil {
                removed += 1
            }
        }
        return removed
    }

    private func stamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: Date())
    }
}
