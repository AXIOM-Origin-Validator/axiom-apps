import SwiftUI
import AppKit
import AxiomSdk

// =================================================================
// SystemStatusSheet — read-only diagnostic of the SDK runtime +
// network seed state.
//
// Distinct from `DiagnosticSheet` (which scans the wallets directory
// for orphaned pairs / stale locks): this one answers "is this
// install healthy" — Core ELF match, validators with encryption
// fingerprints, Nabla picker state, seed sync version, SDK build.
//
// Reached from Settings → Advanced → "Show system status". All FFI
// reads; no mutation. Tap-to-copy fields where the hex / path is
// worth lifting into a bug report.
// =================================================================

struct SystemStatusSheet: View {
    let onClose: () -> Void

    @State private var snapshot: SystemSnapshot = .empty
    /// True while a Nabla picker probe round is in flight. Disables
    /// the "Probe now" button so the user can't double-fire and gets
    /// visual feedback that something is happening.
    @State private var isProbing: Bool = false
    /// Outcome of the most recent probe round — surfaced as a brief
    /// status line in the Nabla card (e.g. "Last probe: 9 of 10
    /// reachable"). Cleared on next probe.
    @State private var lastProbeSummary: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    coreElfSection
                    validatorsSection
                    nablaSection
                    seedSyncSection
                    buildSection
                }
                .padding(EdgeInsets(top: DesignTokens.Spacing.md,
                                    leading: DesignTokens.Spacing.lg,
                                    bottom: DesignTokens.Spacing.lg,
                                    trailing: DesignTokens.Spacing.lg))
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .onAppear { reload() }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SYSTEM STATUS")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("SDK runtime + seed state")
                    .font(DesignTokens.Typography.heading)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(DesignTokens.Typography.label)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.md,
                            leading: DesignTokens.Spacing.lg,
                            bottom: DesignTokens.Spacing.sm,
                            trailing: DesignTokens.Spacing.lg))
    }

    private var footer: some View {
        HStack {
            Text(snapshot.initialized ? "SDK initialised" : "SDK NOT initialised — `sdkSetup()` hasn't run")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(snapshot.initialized
                                 ? DesignTokens.statusCleanFg
                                 : DesignTokens.statusRejectedFg)
            Spacer()
            Button("Refresh") { reload() }
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandPrimary)
                .controlSize(.small)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm,
                            leading: DesignTokens.Spacing.lg,
                            bottom: DesignTokens.Spacing.sm,
                            trailing: DesignTokens.Spacing.lg))
    }

    // MARK: - Sections

    private var coreElfSection: some View {
        statusCard(title: "Core ELF") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                coreElfMatchBanner
                kvHexRow("Loaded BLAKE3",
                         value: snapshot.loadedCoreId,
                         emptyPlaceholder: "(not loaded)")
                kvHexRow("Canonical (baked in binary)",
                         value: snapshot.canonicalCoreId,
                         emptyPlaceholder: "(empty — dev build, gate disabled)")
                kvRow("ELF path",
                      value: snapshot.elfPath,
                      mono: true,
                      emptyPlaceholder: "(not loaded)")
            }
        }
    }

    /// Three-state banner — match (green), mismatch (red), gate-off
    /// (informational). The gate-off case is the common dev path
    /// where `AXIOM_CANONICAL_CORE_ID` wasn't set at compile time,
    /// so the runtime accepts whatever ELF it finds.
    private var coreElfMatchBanner: some View {
        let loaded = snapshot.loadedCoreId
        let canonical = snapshot.canonicalCoreId
        let (text, color, bg, icon): (String, Color, Color, String) = {
            if loaded.isEmpty {
                return ("SDK not initialised",
                        DesignTokens.textTertiary,
                        DesignTokens.bgTertiary,
                        "questionmark.circle")
            }
            if canonical.isEmpty {
                return ("Dev build: no canonical baked, any ELF accepted",
                        DesignTokens.statusScarredFg,
                        DesignTokens.statusScarredBgSoft,
                        "exclamationmark.triangle")
            }
            if loaded == canonical {
                return ("Match — gate verified the bundled ELF at setup",
                        DesignTokens.statusCleanFg,
                        DesignTokens.statusCleanBgSoft,
                        "checkmark.seal")
            }
            return ("MISMATCH — wallet should not have started",
                    DesignTokens.statusRejectedFg,
                    DesignTokens.statusRejectedBgSoft,
                    "xmark.octagon")
        }()
        return HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(DesignTokens.Typography.labelStrong)
                .foregroundStyle(color)
            Spacer()
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xxs,
                            leading: DesignTokens.Spacing.xs,
                            bottom: DesignTokens.Spacing.xxs,
                            trailing: DesignTokens.Spacing.xs))
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        .padding(.bottom, 2)
    }

    private var validatorsSection: some View {
        statusCard(title: "Validators (\(snapshot.validators.count))") {
            if snapshot.validators.isEmpty {
                Text("(none loaded — `validators.list` empty)")
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
            } else {
                ForEach(Array(snapshot.validators.enumerated()), id: \.offset) { _, v in
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Text(v.name)
                            .frame(width: 70, alignment: .leading)
                        Text(v.email)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(DesignTokens.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let pk = v.ed25519Pk, !pk.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "lock.fill")
                                    .font(DesignTokens.Typography.caption)
                                Text(fingerprint(pk))
                            }
                            .foregroundStyle(DesignTokens.statusCleanFg)
                        } else {
                            HStack(spacing: 3) {
                                Image(systemName: "lock.open")
                                    .font(DesignTokens.Typography.caption)
                                Text("plain")
                            }
                            .foregroundStyle(DesignTokens.textTertiary)
                        }
                    }
                    .font(DesignTokens.Typography.monoSmall)
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private var nablaSection: some View {
        let entries = snapshot.nablaPicker
        // 4-state liveness. The picker's internal `last_ok` HashMap
        // is populated as a side-effect of `register_with_nabla`
        // (send/redeem/heal) — i.e., the wallet has to actually
        // BROADCAST before any node shows as "connected"/"stale".
        // Until then everything is "untested" — which historically
        // rendered as "never connected", reading as a broken state
        // when it's just "no broadcast yet." The "Probe now" button
        // below fires a TCP-handshake probe against every alive
        // address and updates the picker directly, giving the user
        // real connectivity diagnostics on demand.
        let connected = entries.filter { $0.state == "connected" }.count
        let stale     = entries.filter { $0.state == "stale" }.count
        let untested  = entries.filter { $0.state == "untested" }.count
        let failed    = entries.filter { $0.state == "failed" }.count
        let title = "Nabla picker (\(connected) connected, \(stale) seen, \(untested) untested, \(failed) failed)"
        return statusCard(title: title) {
            nablaProbeBar
            if entries.isEmpty {
                Text("(picker empty — `nabla-nodes.list` not loaded)")
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(nablaStateColour(e.state))
                                .frame(width: 6, height: 6)
                            Image(systemName: nablaStateSymbol(e.state))
                                .font(DesignTokens.Typography.micro)
                                .foregroundStyle(nablaStateColour(e.state))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(nablaStateAccessibilityLabel(e.state))
                        // Name from the seed list when known; the
                        // picker may also know runtime-discovered
                        // addresses with no seed-side name — render
                        // just the address in that case.
                        if !e.name.isEmpty {
                            Text(e.name)
                                .frame(width: 100, alignment: .leading)
                            Text(e.address)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(DesignTokens.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(e.address)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(nablaStateLabel(e))
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                    .font(DesignTokens.Typography.monoSmall)
                    .padding(.vertical, 1)
                }
            }
        }
    }

    /// Probe-control bar inside the Nabla card. "Probe now" fires a
    /// quick TCP handshake against every alive address (via the SDK
    /// FFI `sdkProbeAllNablaNodes`) and updates the picker. Backing
    /// rationale + help text explain what "untested" means so the
    /// reader doesn't interpret it as broken.
    @ViewBuilder
    private var nablaProbeBar: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button(action: probeNablaNow) {
                    if isProbing {
                        HStack(spacing: DesignTokens.Spacing.xxs) {
                            ProgressView().controlSize(.small)
                            Text("Probing…")
                        }
                    } else {
                        Text("Probe now")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isProbing || snapshot.nablaPicker.isEmpty)
                if let summary = lastProbeSummary {
                    Text(summary)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
                Spacer()
            }
            Text("Liveness updates as a side-effect of broadcasts (send / redeem / claim / heal). Until then nodes show as \"not contacted yet\" — that's the optimistic default, not a failure. Use \"Probe now\" to verify reachability without a broadcast.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, DesignTokens.Spacing.xxs)
    }

    private func probeNablaNow() {
        guard !isProbing else { return }
        isProbing = true
        lastProbeSummary = nil
        Task.detached {
            // Off-main: each probe blocks up to 3 s on a TCP
            // connect; running on main would freeze the sheet.
            let total = UInt32(sdkNablaPickerSnapshot().count)
            let ok = sdkProbeAllNablaNodes()
            await MainActor.run {
                isProbing = false
                lastProbeSummary = "Last probe: \(ok) of \(total) reachable"
                reload()
            }
        }
    }

    /// Colour for a Nabla node's connection state. Green = reached in
    /// the most recent round, yellow = reached before, red = last
    /// attempt failed, grey = never reached (untested default).
    private func nablaStateColour(_ state: String) -> Color {
        switch state {
        case "connected": return DesignTokens.statusCleanFg
        case "stale":     return DesignTokens.statusScarredFg
        case "failed":    return DesignTokens.statusRejectedFg
        default:          return DesignTokens.textTertiary   // untested
        }
    }

    /// SF Symbol companion for the state dot — states are never
    /// color-only. Mirrors ChequeStatusStyle's symbol vocabulary.
    private func nablaStateSymbol(_ state: String) -> String {
        switch state {
        case "connected": return "checkmark.seal"
        case "stale":     return "exclamationmark.triangle"
        case "failed":    return "xmark.octagon"
        default:          return "questionmark.circle"   // untested
        }
    }

    /// VoiceOver description for the state dot + symbol pair.
    private func nablaStateAccessibilityLabel(_ state: String) -> String {
        switch state {
        case "connected": return "Connected"
        case "stale":     return "Seen before, currently stale"
        case "failed":    return "Last attempt failed"
        default:          return "Not contacted yet"
        }
    }

    /// Trailing relative-time label for a Nabla picker row.
    ///
    /// "Untested" prints as "not contacted yet" — the picker's
    /// `last_ok` HashMap is populated by `register_with_nabla` on
    /// success, so an address without a stamp means no broadcast
    /// has exercised it (NOT that the node is dead — that would
    /// be the "failed" state). The previous "never connected"
    /// wording read as a failure and triggered confused bug
    /// reports.
    private func nablaStateLabel(_ e: AppNablaPickerEntry) -> String {
        switch e.state {
        case "connected": return "connected \(secondsAgoLabel(e.lastOkSecs)) ago"
        case "stale":     return "last ok \(secondsAgoLabel(e.lastOkSecs)) ago"
        case "failed":    return "failed \(secondsAgoLabel(e.deadSinceSecs)) ago"
        default:          return "not contacted yet"
        }
    }

    private var seedSyncSection: some View {
        let v = snapshot.localSeedsVersion
        let mtime = snapshot.seedsVersionMtime
        return statusCard(title: "Seed sync (axiom-dist)") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                kvRow("Cached SEEDS_VERSION",
                      value: v.map(String.init) ?? "",
                      mono: true,
                      emptyPlaceholder: "(none — wallet hasn't fetched yet)")
                kvRow("Last refresh",
                      value: mtime.map(refreshTimeLabel) ?? "",
                      mono: false,
                      emptyPlaceholder: "—")
                Text("Settings → Network → ‘Refresh seeds from axiom-dist’ forces a re-pull. Auto-refreshes when remote SEEDS_VERSION > cached.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .padding(.top, DesignTokens.Spacing.xxs)
            }
        }
    }

    private var buildSection: some View {
        statusCard(title: "Build") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                kvRow("SDK FFI version",
                      value: snapshot.buildVersion,
                      mono: true,
                      emptyPlaceholder: "(unavailable)")
                kvRow("App directory",
                      value: snapshot.appDir,
                      mono: true,
                      emptyPlaceholder: "(not loaded)")
                Button("Reveal app directory in Finder") {
                    if !snapshot.appDir.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: snapshot.appDir)]
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(snapshot.appDir.isEmpty)
            }
        }
    }

    // MARK: - Row helpers

    private func statusCard<Content: View>(
        title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(DesignTokens.Typography.labelStrong)
                .foregroundStyle(DesignTokens.textPrimary)
            content()
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm,
                            leading: DesignTokens.Spacing.sm,
                            bottom: DesignTokens.Spacing.sm,
                            trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private func kvRow(_ label: String,
                       value: String,
                       mono: Bool,
                       emptyPlaceholder: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(width: 180, alignment: .leading)
            if value.isEmpty {
                Text(emptyPlaceholder)
                    .font(mono ? DesignTokens.Typography.monoSmall : DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textTertiary)
            } else {
                Text(value)
                    .font(mono ? DesignTokens.Typography.monoSmall : DesignTokens.Typography.caption)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    /// Hex-string row with a copy button — for the canonical /
    /// loaded CoreID values where you'd realistically want to paste
    /// into a bug report.
    private func kvHexRow(_ label: String,
                          value: String,
                          emptyPlaceholder: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(width: 180, alignment: .leading)
            if value.isEmpty {
                Text(emptyPlaceholder)
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
                Spacer()
            } else {
                Text(value)
                    .font(DesignTokens.Typography.monoSmall)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(DesignTokens.Typography.micro)
                }
                .buttonStyle(.plain)
                .help("Copy hex")
            }
        }
    }

    // MARK: - Formatting

    /// First 4 + last 4 bytes of pubkey, hex-grouped. Same shape the
    /// Settings → Network table uses so the user sees consistent
    /// fingerprints across the app.
    private func fingerprint(_ bytes: Data) -> String {
        guard bytes.count >= 8 else {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        let head = bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
        let tail = bytes.suffix(4).map { String(format: "%02x", $0) }.joined()
        return "\(head)…\(tail)"
    }

    private func secondsAgoLabel(_ ts: UInt64) -> String {
        let now = UInt64(Date().timeIntervalSince1970)
        let elapsed = now.saturating_sub_or_zero(ts)
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m" }
        return "\(elapsed / 3600)h"
    }

    private func refreshTimeLabel(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt.string(from: d)
    }

    // MARK: - Snapshot loading

    private func reload() {
        snapshot = SystemSnapshot.load()
    }
}

private extension UInt64 {
    /// Saturating subtraction. Avoids underflow when the
    /// last-marked-dead timestamp ends up ahead of wall-clock due to
    /// NTP adjustment or epoch comparison oddity.
    func saturating_sub_or_zero(_ rhs: UInt64) -> UInt64 {
        self.checkedSubtract(rhs) ?? 0
    }
    func checkedSubtract(_ rhs: UInt64) -> UInt64? {
        if rhs > self { return nil }
        return self - rhs
    }
}

// =================================================================
// SystemSnapshot — pulls every diagnostic field via FFI in one go,
// then the view renders off the cached struct. Keeps the view body
// pure and predictable.
// =================================================================

private struct SystemSnapshot {
    var initialized: Bool
    var loadedCoreId: String
    var canonicalCoreId: String
    var elfPath: String
    var appDir: String
    var buildVersion: String
    var validators: [AppValidatorHint]
    var nablaPicker: [AppNablaPickerEntry]
    var localSeedsVersion: Int?
    var seedsVersionMtime: Date?

    static let empty = SystemSnapshot(
        initialized: false,
        loadedCoreId: "",
        canonicalCoreId: "",
        elfPath: "",
        appDir: "",
        buildVersion: "",
        validators: [],
        nablaPicker: [],
        localSeedsVersion: nil,
        seedsVersionMtime: nil,
    )

    static func load() -> SystemSnapshot {
        let initialized = sdkIsInitialized()
        let appDir = sdkAppDir()

        var localSeedsVersion: Int? = nil
        var seedsVersionMtime: Date? = nil
        if !appDir.isEmpty {
            let path = "\(appDir)/.seeds_version"
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                localSeedsVersion = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let mod = attrs[.modificationDate] as? Date {
                seedsVersionMtime = mod
            }
        }

        return SystemSnapshot(
            initialized: initialized,
            loadedCoreId: sdkLoadedCoreId(),
            canonicalCoreId: sdkCanonicalCoreId(),
            elfPath: sdkElfPath(),
            appDir: appDir,
            buildVersion: sdkBuildVersion(),
            validators: sdkAppValidators(),
            nablaPicker: sdkNablaPickerSnapshot(),
            localSeedsVersion: localSeedsVersion,
            seedsVersionMtime: seedsVersionMtime,
        )
    }
}
