import SwiftUI
import AppKit
import CryptoKit
import AxiomSdk

// =================================================================
// SettingsView — application configuration.
//
// Mirrors views/09_settings.html: left rail of section labels,
// right pane of grouped controls. Sections in this commit:
//
//   About    — app + SDK version, network fingerprint (live FFI),
//              wallet directory path. Read-only.
//   Network  — Nabla node configuration (placeholder — bootstrap
//              list is currently a compile-time constant).
//              digit_version (placeholder — Console-query SDK
//              addition pending).
//   Security — Change app password / Touch ID / session timeout
//              (all placeholders pointing at app-keystore work).
//   Advanced — wallets directory + lock-app shortcut.
//
// Per the integration rule: every dynamic value comes from the FFI
// (network_fingerprint, wallet getters) or pure local state. No
// URLSession.
// =================================================================

struct SettingsView: View {
    @State private var selectedSection: SettingsSection = .about

    enum SettingsSection: String, CaseIterable, Identifiable {
        case about, network, security, advanced
        var id: String { rawValue }
        var title: String {
            switch self {
            case .about:    return "About"
            case .network:  return "Network"
            case .security: return "Security"
            case .advanced: return "Advanced"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            railNav
                .frame(width: 180)
            Divider()
            ScrollView {
                Group {
                    switch selectedSection {
                    case .about:    AboutSection()
                    case .network:  NetworkSection()
                    case .security: SecuritySection()
                    case .advanced: AdvancedSection()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(EdgeInsets(top: DesignTokens.Spacing.lg, leading: DesignTokens.Spacing.xl, bottom: DesignTokens.Spacing.lg, trailing: DesignTokens.Spacing.xl))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bgPrimary)
    }

    private var railNav: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SETTINGS")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
                .padding(EdgeInsets(top: DesignTokens.Spacing.lg, leading: DesignTokens.Spacing.md, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.md))
            ForEach(SettingsSection.allCases) { section in
                Button(action: { selectedSection = section }) {
                    HStack {
                        Text(section.title)
                            .font(
                                selectedSection == section
                                    ? DesignTokens.Typography.bodyStrong
                                    : DesignTokens.Typography.body
                            )
                            .foregroundStyle(
                                selectedSection == section
                                    ? DesignTokens.textPrimary
                                    : DesignTokens.textSecondary
                            )
                        Spacer()
                    }
                    .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.md, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.md))
                    .background(
                        selectedSection == section ? DesignTokens.bgTertiary : Color.clear
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .background(DesignTokens.bgChrome)
    }
}

// =================================================================
// About section
// =================================================================
private struct AboutSection: View {
    @EnvironmentObject private var versionSkew: VersionSkewWatcher
    @EnvironmentObject private var releaseUpdate: ReleaseUpdateWatcher
    // 乖乖 — decorative inert easter egg. 7-tap on "App version" →
    // overlay. See KuaikuaiOverlay.swift; zero functional behaviour.
    @State private var showKuaikuai: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            sectionHeader("About this build")

            welcomeNote

            settingsCard(title: "Versions") {
                row("App version", value: AxiomVersion.app)
                    .kuaikuaiTapTarget(presenting: $showKuaikuai)
                Divider()
                row("SDK version", value: "axiom-sdk-core \(AxiomVersion.crate)")
                Divider()
                row("Schema version", value: "wallet.axiom v2 (auth_hash + wallet_secret)")
                Divider()
                row("Wire protocol", value: "AXIOM/2.11")
                Divider()
                // Numeric wire-protocol counter — bumped server-side
                // every time a wire change (e.g. new error codes the
                // UI must understand) would mismatch older wallets.
                // Driven by VersionSkewWatcher; server column reads
                // "unknown" until the first ACK lands.
                wireProtocolRow
            }

            if versionSkew.updateAvailable {
                updateAvailableChip
            }

            releaseUpdateCard

            settingsCard(title: "Network fingerprint") {
                Text("Verify this against the value published in the Yellow Paper, on axiom.dev, or in a signed press release. They must match — if not, you may be talking to the wrong network.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                    .padding(.bottom, DesignTokens.Spacing.xxs)
                Text(networkFingerprint())
                    .font(DesignTokens.Typography.mono)
                    .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.bgPrimary)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                            .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
                    .textSelection(.enabled)
            }

            settingsCard(title: "Trust anchors") {
                Text("The fingerprint above is BLAKE3 over the two anchors below. The anchors are the actual key material the protocol trusts; the fingerprint is the convenient hash. Auditors and operators can compare these against the Yellow Paper §G1 listing.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                    .padding(.bottom, DesignTokens.Spacing.xxs)

                anchorRow(
                    label: "Wallet identity anchor",
                    sublabel: "WALLET_IDENTITY_KEY — wallet-checksum anchor",
                    value: walletIdentityAnchor()
                )

                let roots = rootAuthorityAnchors()
                ForEach(Array(roots.enumerated()), id: \.offset) { idx, pk in
                    anchorRow(
                        label: "Root authority #\(idx + 1)",
                        sublabel: "ROOT_AUTHORITY_PKS[\(idx)] — validator-trust anchor",
                        value: pk
                    )
                }
            }

            GenesisAnchorCard()

            settingsCard(title: "Integration discipline") {
                Text("This wallet talks to validators and Nabla ONLY through the SDK's exposed FFI. No direct URLSession to validator endpoints. No direct TCP socket to Nabla nodes. KIDDO (the SDK's SMTP client) is the carrier for everything. Every cell of UI data comes from the FFI surface.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
            }
        }
        // 乖乖 — decorative overlay; click-anywhere to dismiss.
        // `.fullScreenCover` is iOS-only; on macOS we present the
        // overlay as a sheet (window-modal panel — closest macOS
        // analogue, the `.onTapGesture` inside KuaikuaiOverlay still
        // dismisses).
        .sheet(isPresented: $showKuaikuai) {
            KuaikuaiOverlay(dismiss: { showKuaikuai = false })
        }
    }

    /// Sign-off note at the bottom of About. Different visual treatment
    /// from the data cards above — softer background, slightly larger
    /// body type, italic signature. A human moment in an otherwise
    /// factual screen; the rest of the section is fingerprints and
    /// anchors, this one's the only thing here addressed to a person.
    private var welcomeNote: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Welcome.")
                .font(DesignTokens.Typography.bodyStrong)
                .foregroundStyle(DesignTokens.textPrimary)

            paragraph("Look at the financial systems around you. Institutions you cannot see. Rules you cannot verify. Intermediaries you cannot escape.")

            paragraph("This is the world you have been given.")

            paragraph("AXIOM was built differently.")

            paragraph("There is no central ledger deciding reality for everyone else. There is no authority to petition. Transactions are witnessed by independent validators. Value is redeemed only when the recipient chooses to redeem it. Consensus emerges from observation, not authority.")

            paragraph("We seeded the first validators. We hold no special privilege. We are witnesses on the same mesh as everyone else. Any validator — including ours — can be replaced, ignored, or removed entirely if the network chooses to continue without it. The system does not depend on us. It was not built to.")

            paragraph("Trust belongs to the mesh, not to its founders.")

            paragraph("The source is open. The cryptography is public. The rules are meant to be examined, verified, and challenged. What you cannot verify, you should not believe — including this.")

            paragraph("Your transactions are your own records. AXIOM is not a blockchain. There is no universal public history exposing every participant to everyone else. What passes between you and a counterparty stays between you and a counterparty.")

            // Stanza — two emphatic statements rendered tight so they
            // read as a couplet, not two paragraphs.
            VStack(alignment: .leading, spacing: 2) {
                stanzaLine("Lose your keys, and nobody can recover them.")
                stanzaLine("Control and responsibility arrive together.")
            }

            // Stanza — three escalating statements that close the
            // body before the salutation.
            VStack(alignment: .leading, spacing: 2) {
                stanzaLine("This system does not ask for permission.")
                stanzaLine("It does not wait for approval.")
                stanzaLine("It only asks whether the witnesses agree.")
            }

            Text("Welcome to the mesh.")
                .font(DesignTokens.Typography.labelStrong)
                .foregroundStyle(DesignTokens.textPrimary)

            HStack {
                Spacer()
                Text("— AXIOM Origin Validator")
                    .font(.system(size: 11, design: .serif))
                    .italic()
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .padding(.top, DesignTokens.Spacing.xxs)
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.brandPrimaryWash)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel)
                .strokeBorder(DesignTokens.brandPrimary.opacity(0.15), lineWidth: DesignTokens.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel))
    }

    /// Standard body paragraph in the welcome note. 12pt with 3pt line
    /// spacing so multi-line paragraphs breathe.
    private func paragraph(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(DesignTokens.Typography.label)
            .foregroundStyle(DesignTokens.textPrimary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One line of a tight stanza. No line spacing within (the parent
    /// VStack provides 2pt between lines); reads as a stacked
    /// statement rather than a paragraph.
    private func stanzaLine(_ text: String) -> some View {
        Text(LocalizedStringKey(text))
            .font(DesignTokens.Typography.label)
            .foregroundStyle(DesignTokens.textPrimary)
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textSecondary)
            Spacer()
            Text(value)
                .font(DesignTokens.Typography.labelStrong)
                .textSelection(.enabled)
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    /// Numeric wire-protocol counter row inside the Versions card.
    /// Shows the baked client value always; appends the
    /// last-observed server value once the first ACK has landed
    /// (server == 0 before any wire round-trip).
    @ViewBuilder
    private var wireProtocolRow: some View {
        let client = versionSkew.clientProtocolVersion
        let server = versionSkew.serverProtocolVersion
        let value: String = {
            if server == 0 {
                return "client v\(client) (server unknown — no ACK yet)"
            }
            return "client v\(client) · server v\(server)"
        }()
        row("Protocol counter", value: value)
    }

    /// Non-blocking "Update available" chip. Shown when the server's
    /// `server_protocol_version` is newer than this client but the
    /// mesh still tolerates us (`is_sdk_too_old() == false`). Purely
    /// informational — no broadcast paths are disabled by this; the
    /// blocking flow lives in `MainAppView.sdkTooOldBanner` and fires
    /// only when the mesh actually bumps its `min_client` floor past us.
    @ViewBuilder
    private var updateAvailableChip: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "arrow.down.circle")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.statusScarredFg)
            VStack(alignment: .leading, spacing: 2) {
                Text("Update available")
                    .font(DesignTokens.Typography.labelStrong)
                Text("The network has advanced to protocol v\(versionSkew.serverProtocolVersion) — this wallet is still v\(versionSkew.clientProtocolVersion) and is being tolerated. Installing a newer build is recommended but not required yet.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusScarredBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    /// Release-feed update card (axiom-dist `releases.json`). Distinct
    /// from `updateAvailableChip` above (which is the protocol-version
    /// skew signal): this is keyed on the published build's CoreID.
    ///   • same CoreID, newer version → optional "Update available"
    ///   • different CoreID           → mandatory "Update required"
    ///     (the network's Core rotated; this build can't transact).
    @ViewBuilder
    private var releaseUpdateCard: some View {
        settingsCard(title: "Software updates") {
            switch releaseUpdate.verdict {
            case .mandatory(let info):
                releaseRow(
                    title: "Update required",
                    detail: "The network has moved to a new Core (CoreID \(String(info.coreId.prefix(8)))…). This build can no longer transact until you install \(info.version).",
                    info: info,
                    mandatory: true
                )
            case .optional(let info):
                releaseRow(
                    title: "Update available",
                    detail: "Version \(info.version) is available on the same Core. Recommended, but you can update whenever it's convenient.",
                    info: info,
                    mandatory: false
                )
            case .upToDate:
                row("Status", value: "Up to date (\(ReleaseUpdate.appVersion()))")
            case .unknown:
                row("Status", value: releaseUpdate.checking ? "Checking…" : "Not checked yet")
            }

            if let err = releaseUpdate.lastError {
                Divider()
                Text(err)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusScarredFg)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let ts = releaseUpdate.lastChecked {
                Divider()
                row("Last checked", value: ts.formatted(date: .omitted, time: .standard))
            }

            // Worldline params (best-effort). Unreachable shows quietly
            // here — never a popup or blocker.
            Divider()
            if releaseUpdate.worldlineReachable {
                if let dv = releaseUpdate.suggestedDigitVersion {
                    let started = releaseUpdate.digitVersionStarted.map { " (since \($0))" } ?? ""
                    row("L$ digit_version", value: "\(dv)\(started)")
                }
            } else {
                row("Network parameters", value: "unavailable — using local defaults")
            }

            Divider()
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    Task { await releaseUpdate.check() }
                } label: {
                    Text("Check for updates")
                }
                .disabled(releaseUpdate.checking)
                if releaseUpdate.checking {
                    ProgressView().controlSize(.small)
                    Text("Checking…")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func releaseRow(title: String, detail: String, info: ReleaseInfo, mandatory: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: mandatory ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                    .foregroundStyle(mandatory ? DesignTokens.statusScarredFg : DesignTokens.textSecondary)
                Text(title).font(DesignTokens.Typography.labelStrong)
            }
            Text(detail)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button {
                    Task { await releaseUpdate.downloadAndReveal() }
                } label: {
                    Text(releaseUpdate.downloading ? "Downloading…" : "Download \(info.version)…")
                }
                .disabled(releaseUpdate.downloading || info.url == nil)
                if info.notesUrl != nil {
                    Button("Release notes") { releaseUpdate.openNotes() }
                        .buttonStyle(.link)
                }
            }
            if info.url == nil {
                Text("Download link not published yet — check back shortly.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// =================================================================
// Genesis anchor (AXC release) — YPX-011 / FACT #0
//
// The unforgeable root of all AXC supply. Anchored to 7 real-world
// news headlines from 7 countries on 2026-03-19, signed by Core
// with the wallet identity private key.
//
// This is the strongest verifiability surface AXIOM has: anyone
// holding a Yellow Paper can also pull up the named news archives
// and confirm the headlines existed. The supply cap (100M AXC) and
// sub-pool breakdown are baked into the binary; recompiling them
// produces a different ELF and therefore a different network.
// =================================================================
private struct GenesisAnchorCard: View {
    private let anchor = genesisAnchor()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("GENESIS ANCHOR (AXC RELEASE)")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                introBlurb

                metaGrid

                supplyBreakdown

                headlineList
            }
            .padding(DesignTokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        }
    }

    private var introBlurb: some View {
        Text("FACT #0 — the unforgeable root of all AXC supply (YPX-011). On the date below, 7 news organisations across 7 countries published the headlines listed at the bottom of this card. The combination of date, headlines, and `WALLET_IDENTITY_KEY` signature is the proof that AXIOM was launched no earlier than this moment, and that the binary you're running was built against the genuine FACT #0.")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.textSecondary)
            .lineSpacing(2)
    }

    private var metaGrid: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            metaRow("Genesis date", anchor.date)
            Divider()
            metaRow("Unix timestamp", "\(anchor.unixTimestamp)")
            Divider()
            metaRow("Total supply (cap)", formatAxcCount(anchor.poolTotalAxc))
        }
    }

    private var supplyBreakdown: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("SUB-POOL ALLOCATION")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            VStack(spacing: 0) {
                ForEach(Array(anchor.subPools.enumerated()), id: \.offset) { idx, pool in
                    HStack(alignment: .top) {
                        Text(pool.poolId)
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.textSecondary)
                        Spacer()
                        Text(formatAxcCount(pool.initialBalance))
                            .font(DesignTokens.Typography.amountCaption)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, DesignTokens.Spacing.xxs)
                    if idx < anchor.subPools.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
            .padding(DesignTokens.Spacing.xs)
            .background(DesignTokens.bgPrimary)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                    .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
            )
        }
    }

    private var headlineList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("HEADLINE ANCHORS — \(anchor.headlines.count) COUNTRIES")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                ForEach(Array(anchor.headlines.enumerated()), id: \.offset) { _, h in
                    headlineRow(h)
                }
            }
        }
    }

    private func headlineRow(_ h: GenesisHeadlineRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Text(h.country.uppercased())
                    .font(DesignTokens.Typography.chip)
                    .tracking(0.3)
                    .foregroundStyle(DesignTokens.brandPrimary)
                    .padding(.horizontal, DesignTokens.Spacing.xxs).padding(.vertical, 1)
                    .background(DesignTokens.brandPrimarySoft)
                    .clipShape(Capsule())
                Text(h.organisation)
                    .font(DesignTokens.Typography.labelStrong)
                Spacer()
                Text(h.timestamp)
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            Text(h.headline)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(DesignTokens.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
        )
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
            Spacer()
            Text(value)
                .font(DesignTokens.Typography.mono)
                .textSelection(.enabled)
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    private func formatAxcCount(_ axc: UInt64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        let n = f.string(from: NSNumber(value: axc)) ?? "\(axc)"
        return "\(n) AXC"
    }
}

// =================================================================
// Network section
//
// Read-only viewer of the SDK's hint files (`validators.list` and
// `nabla-nodes.list` under the app dir). The hint files are the
// authoritative source for validator emails + Nabla addresses since
// the setup() refactor — Settings used to own a JSON-backed copy of
// these lists, but that risked drift. Now the user edits the text
// files directly (via "Reveal in Finder") and restarts the app to
// re-load.
// =================================================================
private struct NetworkSection: View {
    @EnvironmentObject private var session: AppSession
    /// Worldline feed (Console-published digit_version + reachability),
    /// same source AboutSection uses — drives the "proposed" dv row.
    @EnvironmentObject private var releaseUpdate: ReleaseUpdateWatcher
    /// Transient banner from the last "Refresh seeds" press. Nil =
    /// idle; non-nil = either "Refreshing…" / outcome message.
    @State private var refreshStatus: String?
    @State private var isRefreshing: Bool = false

    /// Per-validator pick tally for display, loaded from the shared
    /// `ValidatorPickCounter` (UserDefaults-backed, keyed by validator_id).
    /// The actual counting happens at broadcast finalize in MainAppView's
    /// send/redeem/claim outcome observers — not here. This view just
    /// reads + renders, with a harmless idempotent catch-up on appear.
    @State private var pickCounts: [String: Int] = [:]

    /// Per-Nabla pick tally (address -> count) for the active wallet —
    /// the Nabla analogue of `pickCounts`, recorded at broadcast finalize
    /// in MainAppView. Read-only here for display.
    @State private var nablaPicks: [String: Int] = [:]

    /// Validator IDs (hex-encoded `blake3(sphincs_pk)`) that witnessed
    /// the active wallet's most-recent successful TX. Drives the
    /// "previous witness" blue badge in the validator table. Empty when
    /// no wallet is unlocked, or the active wallet has no last_receipt.
    private var previousWitnessSet: Set<String> {
        guard let w = session.activeWallet else { return [] }
        return Set(w.lastReceiptWitnessIds())
    }

    /// Validator IDs the active wallet's SDK has reactively
    /// blacklisted (hard-rejected on a recent witness round). Drives
    /// the red badge. SDK-owned, persisted on the wallet.
    private var blacklistedSet: Set<String> {
        guard let w = session.activeWallet else { return [] }
        return Set(w.reactiveBlacklist())
    }

    /// Long-list cap: the validator + Nabla tables get a max height
    /// equivalent to ~8 rows. With thousands of seeds (the eventual
    /// mainnet state) the lists scroll independently of the outer
    /// Settings pane. ~36pt per row at the two-line layout (line 1
    /// picks/name/seen + line 2 id/carriers/transport, ~11pt + ~10pt
    /// with ~6pt internal spacing/padding).
    private let listMaxHeight: CGFloat = 8 * 36 + 24


    /// Validator whose detail popover is open. nil = no popover. Set
    /// when the user clicks a row; cleared when the popover dismisses.
    /// Captured-by-value at click time so the popover renders a
    /// snapshot even if the underlying tables refresh.
    @State private var openedValidator: ValidatorDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            sectionHeader("Network")

            settingsCard(title: "Mail transport") {
                Text("Mail transport (SMTP outbound, IMAP / POP3 inbound) is handled by AxiomKiddo.app — a separate mail-shaped gateway app. Install Kiddo, configure your relay there, and point it at this wallet's outbox / inbox directories. See docs/AXIOM_DESIGN_MacOSReferenceApps.md.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
            }

            settingsCard(title: "Carrier preferences") {
                CarrierPreferencesView()
            }

            settingsCard(title: "Incoming payment checks") {
                IncomingCheckPreferenceView()
            }

            settingsCard(title: "Validator hints (validators.list + live)") {
                Text("Bootstrap entries come from `~/Library/Application Support/Axiom/validators.list` (edit + restart to apply, or `Refresh seeds` to pull from axiom-dist). Carriers are live-learned from response payloads (YP §27.5) and cached at `~/Library/Application Support/Axiom/cache/validator_hints.vsp`. `seen` is the last time the wallet completed a witness round with the validator — gossip discovery alone does not count. Rows in italic are validators the wallet has heard about via gossip but doesn't have in its bootstrap list.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                    .padding(.bottom, DesignTokens.Spacing.xxs)

                let validators = sdkAppValidators()
                let liveHints = sdkValidatorHintsLive()
                // Match seed↔live by VALIDATOR_ID (= blake3(sphincs_pk)) —
                // the validator's immutable cryptographic identity. Name,
                // email, carriers, IPs, proof-cap, and encryption key are
                // all operator-mutable; only the id/hash is stable. Joining
                // on the id means an incoming hint updates the SAME row
                // (fresh carriers / IPs / encryption / seen) even when the
                // operator renamed the validator or changed its email — and
                // never splits one validator into a seed row + a stray
                // live-only row. (Earlier code keyed on name, then email;
                // both break the moment that mutable field changes.) The
                // SDK hint cache is already strictly id-keyed —
                // `axiom_sdk_core::hints::ValidatorHintsCache::merge` upserts
                // by validator_id; this mirrors that join key in the UI.
                let liveById: [String: AppValidatorHintLive] = Dictionary(
                    liveHints.compactMap { h in
                        h.validatorId.isEmpty ? nil : (h.validatorId.lowercased(), h)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                let seedIds = Set(validators.map { $0.validatorId.lowercased() })
                let liveOnly = liveHints.filter { h in
                    !seedIds.contains(h.validatorId.lowercased())
                }
                let now = UInt64(Date().timeIntervalSince1970)

                if validators.isEmpty && liveHints.isEmpty {
                    Text("(none loaded — SDK not initialised, or hint file empty)")
                        .font(DesignTokens.Typography.monoSmall)
                        .foregroundStyle(DesignTokens.textTertiary)
                } else {
                    validatorTableHeader
                    let witnesses = previousWitnessSet
                    let blacklist = blacklistedSet
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(validators.enumerated()), id: \.offset) { _, v in
                                Button {
                                    openedValidator = makeDetail(
                                        seed: v,
                                        live: liveById[v.validatorId.lowercased()],
                                        witnesses: witnesses,
                                        blacklist: blacklist,
                                        now: now,
                                    )
                                } label: {
                                    validatorRow(v,
                                                 isPreviousWitness: witnesses.contains(v.validatorId),
                                                 liveHint: liveById[v.validatorId.lowercased()],
                                                 now: now)
                                }
                                .buttonStyle(.plain)
                                .modifier(HoverRowHighlight())
                            }
                            ForEach(Array(liveOnly.enumerated()), id: \.offset) { _, h in
                                Button {
                                    openedValidator = makeDetailLiveOnly(
                                        live: h,
                                        now: now,
                                    )
                                } label: {
                                    liveOnlyRow(h, now: now)
                                }
                                .buttonStyle(.plain)
                                .modifier(HoverRowHighlight())
                            }
                        }
                    }
                    .frame(maxHeight: listMaxHeight)
                    .popover(item: $openedValidator) { detail in
                        ValidatorDetailPopover(detail: detail)
                    }
                    Text("Click a row for full details. Colour key: \u{2022} blue = witnessed active wallet's last TX \u{2022} red = in this wallet's reactive blacklist (SDK-owned) \u{2022} italic = discovered via gossip, not in bootstrap list \u{2022} picks column = app-local FYI counter, resets on reinstall.")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                        .padding(.top, DesignTokens.Spacing.xxs)
                }
            }

            settingsCard(title: "Nabla hints (nabla-nodes.list)") {
                Text("Loaded once at app launch from `~/Library/Application Support/Axiom/nabla-nodes.list`. One `host:port` per line. HTTP addresses are auto-derived (TCP port − 1074). Edit the file and restart the app to apply. `picks` = how many times THIS wallet has reached each node (incoming-payment checks + register); a node with picks > 0 has been used before — useful alongside the per-wallet \"Incoming payment checks\" mode above.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                    .padding(.bottom, DesignTokens.Spacing.xxs)

                let nodes = sdkAppNablaNodes()
                if nodes.isEmpty {
                    Text("(none loaded — SDK not initialised, or hint file empty)")
                        .font(DesignTokens.Typography.monoSmall)
                        .foregroundStyle(DesignTokens.textTertiary)
                } else {
                    HStack {
                        Text("picks").frame(width: 40, alignment: .trailing)
                        Text("name").frame(width: 120, alignment: .leading)
                        Text("address").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .padding(.vertical, 2)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(nodes.enumerated()), id: \.offset) { _, n in
                                let picks = nablaPicks[n.address] ?? 0
                                HStack {
                                    // Per-wallet pick tally — "used previously"
                                    // is simply picks > 0 (highlighted); 0 shows
                                    // a dim em-dash. Mirrors the validator picks
                                    // column.
                                    Text(picks > 0 ? "\(picks)" : "—")
                                        .frame(width: 40, alignment: .trailing)
                                        .foregroundStyle(picks > 0 ? DesignTokens.statusCleanFg : DesignTokens.textTertiary)
                                    Text(n.name)
                                        .lineLimit(1)
                                        .frame(width: 120, alignment: .leading)
                                        .foregroundStyle(picks > 0 ? DesignTokens.textPrimary : DesignTokens.textSecondary)
                                    Text(n.address)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .foregroundStyle(DesignTokens.textSecondary)
                                }
                                .font(DesignTokens.Typography.monoSmall)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: listMaxHeight)
                }
            }

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Reveal hint files in Finder") {
                    let url = URL(fileURLWithPath: defaultAppDir())
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    refreshSeeds()
                } label: {
                    Label("Refresh seeds from axiom-dist",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isRefreshing)

                if let status = refreshStatus {
                    // Presentation only: a failed refresh renders in the
                    // rejected status tone; in-progress / OK stay neutral.
                    Text(status)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(
                            status.hasPrefix("Failed")
                                ? DesignTokens.statusRejectedFg
                                : DesignTokens.textSecondary
                        )
                        .lineLimit(2)
                }
                Spacer()
            }

            settingsCard(title: "Display denomination") {
                Text("AXIOM atoms are the protocol unit (1 AXC = 10^10 atoms). L$ is the display unit; the conversion factor is `digit_version`, set by Console proposal.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)

                // Reads from the shared `DigitVersionState`. Until
                // the SDK exposes a `wallet.digitVersion()` FFI, the
                // value stays at 0 — matches Lambda's default and
                // the live network's current state (no Console
                // proposal has fired).
                row("Current digit_version", value: digitVersionRowValue)
                Divider()
                // The Console publishes its proposed/active digit_version via
                // worldline.json (the same feed the app applies on launch), so
                // this is NOT pending — show the live published value. Falls
                // back to "unavailable" only when the worldline feed is
                // unreachable (best-effort, never a blocker).
                if releaseUpdate.worldlineReachable, let dv = releaseUpdate.suggestedDigitVersion {
                    let started = releaseUpdate.digitVersionStarted.map { " (since \($0))" } ?? ""
                    row("Console-proposed digit_version", value: "\(dv)\(started)")
                } else {
                    row("Console-proposed digit_version", value: "unavailable (worldline feed unreachable)")
                }
            }
        }
        .onAppear {
            // Display the shared tally; record() is a no-op catch-up here
            // (idempotent per wallet_seq) — the real counting happens at
            // broadcast finalize in MainAppView's outcome observers.
            pickCounts = session.activeWallet.map { ValidatorPickCounter.record(wallet: $0) } ?? [:]
            // Read-only display of the per-Nabla tally (counting happens at
            // finalize in MainAppView, not here — avoid folding probe deltas
            // in on a mere Settings open).
            nablaPicks = session.activeWallet.map { NablaPickCounter.counts(for: $0) } ?? [:]
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textSecondary)
            Spacer()
            Text(value)
                .font(DesignTokens.Typography.labelStrong)
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    private var validatorTableHeader: some View {
        // All 6 columns are on line 1 of each row; the line below it
        // just carries the validator_id (unlabelled — hovering the row
        // opens the detail popover for the full context).
        HStack {
            Text("picks").frame(width: 40, alignment: .trailing)
            Text("name").frame(maxWidth: .infinity, alignment: .leading)
            Text("carrier").frame(width: 170, alignment: .leading)
            Text("security").frame(width: 150, alignment: .leading)
            Text("rate").frame(width: 50, alignment: .trailing)
            Text("seen").frame(width: 70, alignment: .leading)
        }
        .font(DesignTokens.Typography.monoSmall)
        .foregroundStyle(DesignTokens.textTertiary)
        .padding(.vertical, 2)
    }

    /// Display value for the "Current digit_version" row. Renders
    /// the live `DigitVersionState.current` (process-wide, defaults
    /// to 0) alongside its `1 AXC = 10^N L$` interpretation. When
    /// the SDK eventually publishes `wallet.digitVersion()` and
    /// AppSession writes through to `DigitVersionState`, this row
    /// will pick up the new value with no additional plumbing.
    private var digitVersionRowValue: String {
        let n = Int(DigitVersionState.current)
        let lPerAxc: String = {
            if n == 0 { return "1 L$" }
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            let v = NSDecimalNumber(decimal: Decimal(sign: .plus, exponent: n, significand: 1))
            return "\(formatter.string(from: v) ?? "10^\(n)") L$"
        }()
        return "\(n) (1 AXC = \(lPerAxc))"
    }

    /// Comma-joined uppercase scheme list extracted from a carrier set
    /// (e.g. `["email:alpha@axiom", "tot:host:7400"]` → `"EMAIL, TOT"`).
    /// Used on line 1 of the validator row — a one-look summary of how
    /// this validator can be reached without dumping full URIs.
    private func carrierSchemesSummary(_ carriers: [String]) -> String {
        var seen = Set<String>()
        var order = [String]()
        for c in carriers {
            guard let colon = c.firstIndex(of: ":") else { continue }
            let scheme = String(c[..<colon]).uppercased()
            if seen.insert(scheme).inserted { order.append(scheme) }
        }
        return order.isEmpty ? "—" : order.joined(separator: ", ")
    }

    /// Format `fee_rate_bps` (u32 basis points, 50 = 0.50%) as a short
    /// percent string for the validator-row "rate" column. Strips
    /// trailing zeros: `100 → "1%"`, `50 → "0.5%"`, `8 → "0.08%"`,
    /// `0 → "0%"`.
    private func formatFeeRate(_ bps: UInt32) -> String {
        if bps == 0 { return "0%" }
        let pct = Double(bps) / 100.0
        let raw = String(format: "%.2f", pct)
        let trimmed = raw.hasSuffix("00")
            ? String(raw.dropLast(3))           // "1.00" → "1"
            : (raw.hasSuffix("0") ? String(raw.dropLast()) : raw) // "0.50" → "0.5"
        return "\(trimmed)%"
    }

    /// Row colour key:
    ///   - **red**    → in active wallet's reactive blacklist (SDK).
    ///   - **blue**   → witnessed active wallet's last TX (previous
    ///                  witness — derived from last_receipt).
    ///   - **plain**  → neither.
    /// Red wins over blue when both apply (blacklisted-but-was-once-a-
    /// witness is the more important signal).
    ///
    /// `liveHint` is the matching entry from the runtime cache (matched
    /// by email — the stable seed↔live join key). When present, its
    /// `carriers` and `observedAt` override the bootstrap fallback values.
    private func validatorRow(_ v: AppValidatorHint,
                              isPreviousWitness: Bool,
                              liveHint: AppValidatorHintLive?,
                              now: UInt64) -> some View {
        let isBlacklisted = blacklistedSet.contains(v.validatorId)
        let rowColour: Color = {
            if isBlacklisted { return DesignTokens.statusRejectedFg }
            if isPreviousWitness { return DesignTokens.brandPrimary }
            return DesignTokens.textPrimary
        }()
        let pickLabel: String = {
            let n = pickCounts[v.validatorId] ?? 0
            return n > 0 ? "\(n)×" : "—"
        }()
        // Carriers: live-learned from WitnessResponse.validator_hints
        // (gossip-propagated, cached in the runtime hint cache) once
        // the validator has been observed; otherwise the carrier set
        // straight off its validators.list seed line — the quoted-CSV
        // format carries a real carrier column (email, TOT, …).
        let carriers: [String] = liveHint?.carriers ?? v.carriers
        let seenLabel: String = liveHint.map { relativeSeen(seenAt: $0.lastWitnessedAt, now: now) } ?? "—"
        // Two-line layout where columns align to the header's six
        // labels (picks · name · carrier · security · rate · seen):
        //   Line 1: picks · name · ←carrier gap→ · ←security gap→ · rate · seen
        //   Line 2: ←picks gutter→ · id · carrier · security · ←rate gap→ · ←seen gap→
        // The id on line 2 sits in the name column (flex), so it
        // appears directly under the validator's name. carrier and
        // security cells land under their respective header labels.
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(pickLabel)
                    .frame(width: 40, alignment: .trailing)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(v.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(rowColour)
                Color.clear.frame(width: 170, height: 0) // carrier sits on line 2
                Color.clear.frame(width: 150, height: 0) // security sits on line 2
                Text(formatFeeRate(v.feeRateBps))
                    .frame(width: 50, alignment: .trailing)
                    .foregroundStyle(DesignTokens.textSecondary)
                Text(seenLabel)
                    .frame(width: 70, alignment: .leading)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            HStack {
                Color.clear.frame(width: 40, height: 0) // picks gutter
                // First 8 hex chars of validator_id = blake3(sphincs_pk).
                // Cryptographic identity used for S-ABR overlap; sits
                // in the name column (flex) so it appears under the name.
                Text(String(v.validatorId.prefix(8)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(DesignTokens.textTertiary)
                CarriersCell(carriers: carriers,
                             encryptionScheme: liveHint?.supportedEncryption ?? "",
                             encryptionFingerprint: encryptionKeyFingerprint(
                                 liveHint?.encryptionPublicKey ?? ""))
                    .frame(width: 170, alignment: .leading)
                transportLabel(for: v.ed25519Pk)
                    .frame(width: 150, alignment: .leading)
                Color.clear.frame(width: 50, height: 0) // rate gap
                Color.clear.frame(width: 70, height: 0) // seen gap
            }
            .font(DesignTokens.Typography.monoSmall)
        }
        .font(DesignTokens.Typography.monoSmall)
        .padding(.vertical, 3)
    }

    /// Row for a validator the wallet learned about via gossip
    /// (`validator_hints` field in a response) but doesn't have in its
    /// bootstrap list. No picks / no fee_rate — those derive from
    /// seed-only data the wallet hasn't received yet.
    private func liveOnlyRow(_ h: AppValidatorHintLive, now: UInt64) -> some View {
        let seenLabel = relativeSeen(seenAt: h.lastWitnessedAt, now: now)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("—")
                    .frame(width: 40, alignment: .trailing)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(h.name)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(DesignTokens.textSecondary)
                Color.clear.frame(width: 100, height: 0)
                Color.clear.frame(width: 180, height: 0)
                Text("—")
                    .frame(width: 50, alignment: .trailing)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text(seenLabel)
                    .frame(width: 70, alignment: .leading)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
            HStack {
                Color.clear.frame(width: 40, height: 0)
                Text(String(h.validatorId.prefix(8)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(DesignTokens.textTertiary)
                CarriersCell(carriers: h.carriers,
                             encryptionScheme: h.supportedEncryption,
                             encryptionFingerprint: encryptionKeyFingerprint(h.encryptionPublicKey))
                    .frame(width: 170, alignment: .leading)
                // Live-only rows have no seed ed25519_pk; render the
                // generic "Plain (no pubkey)" branch.
                transportLabel(for: nil)
                    .frame(width: 150, alignment: .leading)
                Color.clear.frame(width: 50, height: 0)
                Color.clear.frame(width: 70, height: 0)
            }
            .font(DesignTokens.Typography.monoSmall)
        }
        .font(DesignTokens.Typography.monoSmall)
        .padding(.vertical, 3)
    }

    /// Capture a snapshot of a seed-derived validator + its optional
    /// live enrichment into the popover-driving struct.
    private func makeDetail(
        seed v: AppValidatorHint,
        live: AppValidatorHintLive?,
        witnesses: Set<String>,
        blacklist: Set<String>,
        now: UInt64,
    ) -> ValidatorDetail {
        return ValidatorDetail(
            name: v.name,
            // Prefer the seed's validator_id (load-bearing for S-ABR
            // overlap, hand-curated in validators.list) over the live
            // hint's id, which may be unset on validators we haven't
            // contacted yet.
            validatorId: v.validatorId.isEmpty ? live?.validatorId : v.validatorId,
            email: v.email,
            ed25519Pk: v.ed25519Pk,
            carriers: live?.carriers ?? v.carriers,
            proofCap: live?.proofCap,
            lastSeen: live?.lastSeen ?? 0,
            observedAt: live?.observedAt ?? 0,
            picks: pickCounts[v.validatorId] ?? 0,
            isBlacklisted: blacklist.contains(v.validatorId),
            isPreviousWitness: witnesses.contains(v.validatorId),
            now: now,
        )
    }

    /// Same, but for live-only rows (validator known via gossip with
    /// no seed-file entry). No seed-derived fields available.
    private func makeDetailLiveOnly(
        live h: AppValidatorHintLive,
        now: UInt64,
    ) -> ValidatorDetail {
        return ValidatorDetail(
            name: h.name,
            validatorId: h.validatorId,
            email: nil,
            ed25519Pk: nil,
            carriers: h.carriers,
            proofCap: h.proofCap,
            lastSeen: h.lastSeen,
            observedAt: h.observedAt,
            picks: 0,
            isBlacklisted: false,
            isPreviousWitness: false,
            now: now,
        )
    }

    /// "12s" / "3m" / "2h" / "5d" relative-time label. `—` for the
    /// sentinel 0 — the validator has never been witnessed (the wallet
    /// has not completed a transaction with it). Gossip discovery does
    /// NOT count as "seen".
    private func relativeSeen(seenAt: UInt64, now: UInt64) -> String {
        guard seenAt > 0, now >= seenAt else { return "—" }
        let delta = now - seenAt
        switch delta {
        case 0..<60:        return "\(delta)s"
        case 60..<3600:     return "\(delta / 60)m"
        case 3600..<86400:  return "\(delta / 3600)h"
        default:            return "\(delta / 86400)d"
        }
    }

    /// Right-most column: either "Plain (no pubkey)" when the 4th
    /// column of validators.list is absent, or "Encrypted <fp>"
    /// where `<fp>` is a short fingerprint of the ed25519_pk —
    /// short enough to scan, long enough to disambiguate. The
    /// wallet seals UMP bodies to the corresponding X25519 pubkey
    /// (`to_montgomery()` on the Ed25519) when sending.
    @ViewBuilder
    private func transportLabel(for pk: Data?) -> some View {
        if let bytes = pk, !bytes.isEmpty {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: "lock.fill")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.statusCleanFg)
                Text("Encrypted ")
                    .foregroundStyle(DesignTokens.statusCleanFg)
                Text(fingerprint(bytes))
                    .foregroundStyle(DesignTokens.textSecondary)
            }
        } else {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: "lock.open")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Plain (no pubkey)")
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
    }

    /// Short fingerprint of an Ed25519 pubkey for at-a-glance
    /// visual distinctness in the settings row. Renders the first 4
    /// bytes + last 4 bytes as 16 hex chars with a separator. Not a
    /// cryptographic fingerprint (no BLAKE3 dep in the wallet UI);
    /// for an adversarial trust decision the user should look at the
    /// full pubkey via Reveal-in-Finder on validators.list.
    private func fingerprint(_ bytes: Data) -> String {
        guard bytes.count >= 8 else {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        let head = bytes.prefix(4)
        let tail = bytes.suffix(4)
        let headHex = head.map { String(format: "%02x", $0) }.joined()
        let tailHex = tail.map { String(format: "%02x", $0) }.joined()
        return "\(headHex)…\(tailHex)"
    }

    /// Background-task launcher for the "Refresh seeds" button.
    /// Writes new hint files but does NOT mutate the SDK runtime —
    /// validators are loaded into `runtime::validators` once at
    /// `sdk_setup()` time via a OnceLock; restart-to-apply is the
    /// only correct hand-off.
    private func refreshSeeds() {
        isRefreshing = true
        refreshStatus = "Refreshing from axiom-dist…"
        let appDir = defaultAppDir()
        Task { @MainActor in
            let outcome = await SeedFetcher.forceRefresh(appDir: appDir)
            isRefreshing = false
            if let err = outcome.error {
                refreshStatus = "Failed: \(err)"
                return
            }
            let v = outcome.validatorsBytes ?? 0
            let n = outcome.nablaNodesBytes ?? 0
            let versionTag = outcome.remoteVersion.map { " (v\($0))" } ?? ""
            refreshStatus = "OK — wrote \(v) B validators + \(n) B nabla nodes\(versionTag). Restart the wallet to apply."
        }
    }
}

// =================================================================
// Security section
// =================================================================
private struct SecuritySection: View {
    @EnvironmentObject private var session: AppSession
    @State private var changeKeyTarget: LoadedPair? = nil
    @State private var savedFlash: String? = nil
    @State private var showChangePassword: Bool = false
    @State private var biometricOn: Bool = Biometric.isEnabled
    @State private var idleSeconds: Int = UserDefaults.standard.integer(forKey: "axiom.idleLockSeconds")
    /// Migration-notice dismissed flag, mirrored from UserDefaults
    /// so the notice disappears immediately on tap (rather than only
    /// at the next view refresh).
    @State private var migrationNoticeDismissed: Bool =
        UserDefaults.standard.bool(forKey: "axiom.appPasswordMigrationNoticeDismissed.v1")

    /// Last login set this flag if the typed app password ALSO verified
    /// as the first pair's wallet key — i.e., the user is on the
    /// pre-2026-05-27 shared-password setup. We surface a notice
    /// recommending divergence for the shoulder-surf defense.
    private var appPasswordSharedWithWalletKey: Bool {
        UserDefaults.standard.bool(forKey: "axiom.appPasswordSharedWithWalletKey")
    }

    private var shouldShowMigrationNotice: Bool {
        appPasswordSharedWithWalletKey && !migrationNoticeDismissed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            sectionHeader("Security")

            settingsCard(title: "App password") {
                Text("Unlocks the app session at the login screen. Stored in the macOS Keychain (salted hash — no plaintext). Separate from each wallet's signing key: the wallet key is still required, and prompted, for every send, redeem, and heal.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)

                if shouldShowMigrationNotice {
                    sharedPasswordNotice
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App password")
                            .font(DesignTokens.Typography.label)
                        Text("Set during onboarding. Defaults to a different password from your first wallet set's wallet key — change it here if you want to share or rotate it.")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                    Spacer()
                    Button("Change…") { showChangePassword = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.vertical, DesignTokens.Spacing.xxs)
            }

            settingsCard(title: "Wallet keys") {
                Text("Each wallet set has its own wallet key (per-set shared between Normal + Ark). Validators check `auth_hash` derived from the wallet key on every TX (YP §39.3). Change a set's password here for routine rotation, or use Recovery on the login screen for the forgot-password path.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                if session.pairs.isEmpty {
                    placeholderRow("Change wallet key", detail: "No pairs loaded.")
                } else {
                    walletKeyRotationRows
                }
            }

            settingsCard(title: "Biometric / \(Biometric.typeName)") {
                Text("Unlock the app with \(Biometric.typeName) instead of typing the app password. The password is held in the macOS Keychain behind a biometric access control; turning this on asks for your current app password once.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                if Biometric.isAvailable {
                    Toggle(isOn: $biometricOn) {
                        Text("Use \(Biometric.typeName) for unlock")
                            .font(DesignTokens.Typography.label)
                    }
                    .toggleStyle(.switch)
                    .padding(.vertical, DesignTokens.Spacing.xxs)
                    .onChange(of: biometricOn) { _, isOn in
                        if isOn {
                            // Confirm biometrics work right now before
                            // relying on them; revert the toggle if the
                            // user cancels or it fails.
                            Task { @MainActor in
                                let ok = await Biometric.authenticate(
                                    reason: "enable \(Biometric.typeName) unlock")
                                if ok { Biometric.enable() }
                                else { biometricOn = false }
                            }
                        } else {
                            Biometric.disable()
                        }
                    }
                } else {
                    Text("No biometric hardware detected on this Mac.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.textTertiary)
                        .padding(.vertical, DesignTokens.Spacing.xxs)
                }
            }

            settingsCard(title: "Session timeout") {
                Text("Auto-lock the app — return to the login screen — after a stretch with no mouse or keyboard activity. Open wallet handles are released; on-disk wallets are unaffected.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                Picker("Idle lock", selection: $idleSeconds) {
                    Text("Off").tag(0)
                    Text("After 1 minute").tag(60)
                    Text("After 5 minutes").tag(300)
                    Text("After 15 minutes").tag(900)
                    Text("After 1 hour").tag(3600)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .padding(.vertical, DesignTokens.Spacing.xxs)
                .onChange(of: idleSeconds) { _, secs in
                    session.idleLockSeconds = secs
                }
            }

            if let savedFlash {
                Text("✓ \(savedFlash)")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusCleanFg)
            }

            Spacer()
        }
        .sheet(item: Binding(
            get: { changeKeyTarget.map(SettingsChangeKeyTarget.init) },
            set: { _ in changeKeyTarget = nil }
        )) { target in
            ChangeKeySheet(pair: target.pair) { msg in
                changeKeyTarget = nil
                if !msg.isEmpty {
                    savedFlash = msg
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        if savedFlash == msg { savedFlash = nil }
                    }
                }
            }
            .environmentObject(session)
        }
        .sheet(isPresented: $showChangePassword) {
            ChangeAppPasswordSheet(
                onClose: { showChangePassword = false },
                onChanged: { msg in
                    showChangePassword = false
                    // The user just rotated the app password. If it
                    // no longer matches the wallet key, the migration
                    // notice has done its job — clear the dismissed
                    // flag so a future re-collapse (e.g., set both to
                    // the same string again) re-shows it. Also
                    // optimistically clear the "shared" flag; the next
                    // login will re-evaluate against the actual wallet
                    // key and re-set it if they're still shared.
                    UserDefaults.standard.removeObject(
                        forKey: "axiom.appPasswordMigrationNoticeDismissed.v1"
                    )
                    UserDefaults.standard.set(
                        false,
                        forKey: "axiom.appPasswordSharedWithWalletKey"
                    )
                    migrationNoticeDismissed = false
                    flash(msg)
                }
            )
        }
    }

    /// Yellow notice in the App password card when the user's current
    /// app password verifies as the first pair's wallet key (i.e.,
    /// pre-2026-05-27 onboarding default). Dismissible — clicking
    /// "Dismiss" sets the v1 flag so the notice stays gone unless
    /// the user later changes the app password and re-collapses
    /// them onto the wallet key.
    @ViewBuilder
    private var sharedPasswordNotice: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.statusScarredFg)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("Your app password is the same as your first wallet set's wallet key")
                    .font(DesignTokens.Typography.labelStrong)
                Text("This is the default for wallets onboarded before 2026-05-27. Anyone who learns your wallet key (e.g., by watching you type it during a send) can also open the app and browse balance + history. Consider changing your app password to a different string for the shoulder-surf defense.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Button("Change app password…") { showChangePassword = true }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignTokens.statusScarredFg)
                        .controlSize(.small)
                    Button("Dismiss") {
                        UserDefaults.standard.set(
                            true,
                            forKey: "axiom.appPasswordMigrationNoticeDismissed.v1"
                        )
                        migrationNoticeDismissed = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, DesignTokens.Spacing.xxs)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.statusScarredBgSoft)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    @ViewBuilder
    private var walletKeyRotationRows: some View {
        ForEach(Array(session.pairs.enumerated()), id: \.offset) { idx, pair in
            if idx > 0 { Divider() }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pair.name)
                        .font(DesignTokens.Typography.labelStrong)
                    Text(pair.ark == nil ? "Normal mode only" : "Normal + Ark (shared key)")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                Spacer()
                Button("Change key") { changeKeyTarget = pair }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.vertical, DesignTokens.Spacing.xxs)
        }
    }

    /// Show a transient ✓ confirmation under the Wallet keys card.
    private func flash(_ message: String) {
        savedFlash = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if savedFlash == message { savedFlash = nil }
        }
    }
}

private struct SettingsChangeKeyTarget: Identifiable {
    let pair: LoadedPair
    var id: String { pair.name }
}

// =================================================================
// App-password sheets
// =================================================================

/// Change the app password — verifies the current one, sets the new.
/// Does NOT touch any wallet's signing key.
private struct ChangeAppPasswordSheet: View {
    let onClose: () -> Void
    let onChanged: (String) -> Void

    @State private var oldPassword: String = ""
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var errorMessage: String? = nil

    private var canApply: Bool {
        !oldPassword.isEmpty
            && newPassword.count >= 8
            && newPassword == confirmPassword
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Change app password")
                .font(DesignTokens.Typography.heading)
            Text("The app password unlocks the login screen. Changing it does not affect any wallet's signing key.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)

            SecureField("Current app password", text: $oldPassword)
                .textFieldStyle(.roundedBorder)
            SecureField("New password (8+ characters)", text: $newPassword)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm new password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)

            if !confirmPassword.isEmpty && newPassword != confirmPassword {
                Text("New passwords don't match.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                Button("Change password") { apply() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .disabled(!canApply)
            }
            .padding(.top, DesignTokens.Spacing.xxs)
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: 380)
    }

    private func apply() {
        errorMessage = nil
        guard AppPassword.change(old: oldPassword, new: newPassword) else {
            errorMessage = "Current password is wrong."
            return
        }
        onChanged("App password changed.")
    }
}

/// Confirm + authorise deleting the active wallet pair. Three gates,
/// because deletion is irreversible and the wrong pair must never go
/// by a stray click: an explicit warning, a type-`DELETE` phrase, and
/// the app password.
private struct DeleteWalletSheet: View {
    let pairName: String
    let onCancel: () -> Void
    let onConfirmed: () -> Void

    @State private var confirmText: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String? = nil

    private var phraseMatches: Bool {
        confirmText.trimmingCharacters(in: .whitespaces) == "DELETE"
    }
    private var canDelete: Bool { phraseMatches && !password.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Delete wallet set \u{201C}\(pairName)\u{201D}")
                .font(DesignTokens.Typography.heading)
                .foregroundStyle(DesignTokens.statusRejectedFg)
            Text("This permanently removes the \u{201C}\(pairName)\u{201D} wallet set — both the Normal and Ark wallets — and their files from this Mac. It cannot be recovered without its wallet_secret backup. Other wallets, contacts, and settings are untouched. The app relaunches to the login screen.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                (Text("Type ")
                    + Text("DELETE").font(DesignTokens.Typography.monoSmall)
                    + Text(" to confirm"))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                TextField("", text: $confirmText)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            SecureField("Enter your app password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canDelete { confirm() } }

            if let errorMessage {
                Text(errorMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Delete wallet") { confirm() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.statusRejectedFg)
                    .disabled(!canDelete)
            }
            .padding(.top, DesignTokens.Spacing.xxs)
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: 400)
    }

    private func confirm() {
        guard canDelete else { return }
        guard AppPassword.verify(password) else {
            errorMessage = "Wrong app password."
            return
        }
        onConfirmed()
    }
}

// =================================================================
// Advanced section
// =================================================================
private struct AdvancedSection: View {
    @EnvironmentObject private var session: AppSession
    @State private var showDiagnostic: Bool = false
    @State private var showSystemStatus: Bool = false
    @State private var showHealModal: Bool = false
    /// YPX-020 — manual HAL recovery controls (real protocol, not a
    /// simulation): re-anchor a dead-overlap wallet on demand, and
    /// complete recovery to clear the hibernation flag. HAL also surfaces
    /// reactively (dead-overlap banner); these are the always-available
    /// manual entry points.
    @State private var showHalReanchorModal: Bool = false
    @State private var showHalCompleteModal: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var showBurnConfirm: Bool = false
    @State private var burnFeedback: String? = nil
    /// Last successful diagnostic-report file URL; populates the
    /// "Reveal in Finder" affordance + the "Wrote …" line.
    @State fileprivate var lastDiagnosticURL: URL? = nil
    /// Last diagnostic-export error message, if the write failed.
    @State fileprivate var diagnosticExportError: String? = nil
    /// Dev tools state — passcode prompt + the dev sheet itself.
    /// Passcode is the gate; on match the dev sheet opens with three
    /// destructive operations (clear audit log / clear all maildirs /
    /// reset Kiddo). See WalletDevTools.swift.
    @State fileprivate var showDevPasscodeSheet: Bool = false
    @State fileprivate var showWalletDevSheet: Bool = false
    /// Language picker state. Reads/writes UserDefaults
    /// `AppleLanguages`. The override sticks across launches and
    /// resets to system default if cleared (`"System default"`
    /// option). Changing this requires an app relaunch — macOS
    /// doesn't rebuild already-rendered SwiftUI views against a new
    /// bundle locale.
    @State fileprivate var selectedLanguage: String = LanguageOverride.current
    @State fileprivate var languageNeedsRelaunch: Bool = false
    /// Rescan-inbox/cur recovery state — log lines from the most
    /// recent run, plus an in-progress flag for the button.
    @State fileprivate var rescanInProgress: Bool = false
    @State fileprivate var rescanResultLines: [String] = []
    /// Chrome translucency preference (Appearance group). Stored as the
    /// raw Int under `ChromeTranslucency.storageKey` so
    /// `ChromeTranslucency.effective` (ChromeMaterial.swift) reads the
    /// same value. The system's Reduce Transparency setting overrides
    /// to solid unconditionally — see ChromeMaterial.swift.
    @AppStorage(ChromeTranslucency.storageKey)
    private var chromeTranslucencyRaw: Int = ChromeTranslucency.low.rawValue

    /// Typed view of the stored raw value for the segmented Picker.
    private var chromeTranslucency: Binding<ChromeTranslucency> {
        Binding(
            get: { ChromeTranslucency(rawValue: chromeTranslucencyRaw) ?? .low },
            set: { chromeTranslucencyRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            sectionHeader("Advanced")

            settingsCard(title: "Appearance") {
                Picker("Chrome translucency", selection: chromeTranslucency) {
                    ForEach(ChromeTranslucency.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.vertical, DesignTokens.Spacing.xxs)
                Text("Applies to window chrome only (sidebar, bars). Content always sits on solid backgrounds. When the system's Reduce Transparency accessibility setting is on, chrome is always solid.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
            }

            settingsCard(title: "Wallet directory") {
                Text("Where wallet.axiom files and pairs.json live on this Mac. Each wallet set lives in a sub-directory named `<name>-<mode>`.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                Text(defaultWalletDir())
                    .font(DesignTokens.Typography.monoSmall)
                    .padding(EdgeInsets(top: DesignTokens.Spacing.xs, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.xs, trailing: DesignTokens.Spacing.sm))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.bgPrimary)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                            .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
                    .textSelection(.enabled)
                Button("Reveal in Finder") {
                    let url = URL(fileURLWithPath: defaultWalletDir())
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            settingsCard(title: "Lock app") {
                Text("Returns to the login screen. Wallet set handles in this session are released; the on-disk wallets are unaffected.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                Button("Lock now") {
                    session.lock()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            settingsCard(title: "Wallet diagnostic") {
                Text("Scans the wallets directory for stale locks, orphaned wallet-set registrations, unreadable wallet.axiom files, and partial wallet sets. Read-only — auto-fixes are explicit per-row clicks.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                Button("Run diagnostic") { showDiagnostic = true }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }

            settingsCard(title: "System status") {
                Text("Snapshot of the SDK runtime: Core ELF match status, per-validator encryption fingerprint, Nabla picker per-node connection state, seed-sync version + last refresh, SDK build version. Useful for the data you'd want in a bug report.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                Button("Show system status") { showSystemStatus = true }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }

            diagnosticReportCard

            settingsCard(title: "Recover stuck cheque bundles") {
                Text("Re-scans the wallet's `maildir/inbox/cur` for cheque .eml files that were consumed by a previous recv() but didn't make it into their bundle. Each is run through the merge accumulator that recv() now uses post-fix. If your wallet has a pending bundle stuck at, say, 1/3 sigs but you see 3 cheque .emls in the maildir audit log, this recovers them — no file is moved or deleted, only the matching bundle on disk gets updated. Idempotent: running this twice in a row only merges new cheques the first time.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Button(rescanInProgress ? "Scanning…" : "Recover from inbox/cur (active wallet)") {
                        runRescanInboxCur()
                    }
                    .disabled(rescanInProgress || session.activeWallet == nil)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    Spacer()
                }
                if !rescanResultLines.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(rescanResultLines.indices, id: \.self) { idx in
                            Text(rescanResultLines[idx])
                                .font(DesignTokens.Typography.monoSmall)
                                .textSelection(.enabled)
                                .foregroundStyle(DesignTokens.textSecondary)
                        }
                    }
                    .padding(.top, DesignTokens.Spacing.xxs)
                }
            }

            settingsCard(title: "Language") {
                Text("Select the wallet's display language. The choice persists across launches via the `AppleLanguages` UserDefault. A restart is required for the change to take effect (macOS doesn't reload localized resources mid-session). Translations cover the core surfaces today (login, send, receive, settings, etc.); strings not yet localized fall back to English. Set to System default to follow macOS's language preference.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                Picker("Language", selection: $selectedLanguage) {
                    Text("System default").tag(LanguageOverride.systemDefaultSentinel)
                    Text("English").tag("en")
                    Text("繁體中文").tag("zh-Hant")
                    Text("日本語").tag("ja")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .padding(.vertical, DesignTokens.Spacing.xxs)
                .onChange(of: selectedLanguage) { _, newValue in
                    LanguageOverride.set(newValue)
                    languageNeedsRelaunch = true
                }
                if languageNeedsRelaunch {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Button("Relaunch wallet") {
                            LanguageOverride.relaunchApp()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        Text("Restart required for the language change to apply.")
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(DesignTokens.statusScarredFg)
                    }
                }
            }

            settingsCard(title: "Dev tools") {
                Text("Three destructive operations behind a passcode: clear the audit log of processed cheques for the active wallet, clear EVERY wallet's maildir + outbox + cheques on this Mac, and reset AxiomKiddo (terminate process + remove accounts.json). Each ack independently. Wrong passcode dismisses silently.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                Button("Open dev tools…") { showDevPasscodeSheet = true }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }

            // ── Recovery — the sender-side protocol recoveries ──────────────
            Text("RECOVERY")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
                .padding(.top, DesignTokens.Spacing.sm)
            Text("The sender-side protocol recoveries — all REAL ops against live validators (a reference surface for contributors, not a simulation). Pick by what happens to the money:")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
            recoveryComparisonTable

            settingsCard(title: "HEAL — partial-commit recovery (YPX-018)") {
                Text("Run the SDK's heal pass: it re-anchors a drifted wallet (trustless revert-to-last-anchored + retry, zero Nabla) and runs CLARA TX_HEAL for poisoned-committer state from a partial commit. As of 2026-06-24 heal NO LONGER burns scarred links — it only REPORTS them (count below). Heal is idempotent and safe to re-run.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                let scars = session.activeWallet?.factScarCount() ?? 0
                let garbage = session.activeWallet?.garbageStateIdCount() ?? 0
                let needsHeal = scars > 0 || garbage > 0
                HStack(spacing: DesignTokens.Spacing.sm) {
                    healCounter("Scars", value: "\(scars)", warn: scars > 0)
                    healCounter("Garbage states", value: "\(garbage)", warn: garbage > 0)
                    healCounter("Status",
                                value: needsHeal ? "heal recommended" : "healthy",
                                warn: needsHeal)
                }
                Button("Heal wallet…") { showHealModal = true }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    // YPX-020: heal is rejected while hibernating — finish HAL first.
                    .disabled(session.activeWallet == nil || session.isHibernating)

                // ── Deliberate scar burn — separate from heal, value-destroying ──
                // heal() no longer auto-burns (that was the burn-treadmill source);
                // burning is now an explicit, user-confirmed action (burn_scars FFI).
                Divider().padding(.vertical, DesignTokens.Spacing.xxs)
                Text("Burning scarred links DESTROYS the scarred amount to clean the FACT chain so it can compress. Irreversible and rarely needed — Core recovery (heal, above) works without it. Burn only after heal has cleared any garbage state.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                if let fb = burnFeedback {
                    Text(fb)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.statusScarredFg)
                }
                Button("Burn scarred links…") { showBurnConfirm = true }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(DesignTokens.statusRejectedFg)
                    // Nothing to burn, hibernating, or blocking drift (burn would
                    // refuse on garbage state) → keep the destructive action off.
                    .disabled(session.activeWallet == nil || session.isHibernating
                              || scars == 0 || garbage > 0)
                if garbage > 0 {
                    Text("Heal first — a wallet with garbage state can't burn (it refuses).")
                        .font(DesignTokens.Typography.micro)
                        .foregroundStyle(DesignTokens.textTertiary)
                }

                Text("Spec: Yellow Paper YPX-018 — CLARA / TX_HEAL · docs/AXIOM_YPX-018_HEAL_AND_TIERED_MEMORY.md. HEAL repairs a stuck/diverged wallet; a COMPLETED payment whose cheque never reached the receiver is recovered with RECALL below.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineSpacing(2)
            }

            halCard

            recallCard

            settingsCard(title: "Delete current wallet") {
                Text("Removes the active wallet set (Normal + Ark) and its files from this Mac, then returns to the login screen. The wallet set cannot be recovered without its wallet_secret backup — make sure you have that before deleting.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.activePair.map { "Wallet set: \($0.name)" } ?? "No wallet loaded")
                            .font(DesignTokens.Typography.labelStrong)
                        Text("Other wallet sets on this Mac, contacts, and settings are left untouched.")
                            .font(DesignTokens.Typography.micro)
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                    Spacer()
                    Button("Delete current wallet…") { showDeleteConfirm = true }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .tint(DesignTokens.statusRejectedFg)
                        .disabled(session.activePair == nil)
                }
                .padding(.vertical, DesignTokens.Spacing.xxs)
            }

            Spacer()
        }
        .sheet(isPresented: $showDiagnostic) {
            DiagnosticSheet(onClose: { showDiagnostic = false })
        }
        .sheet(isPresented: $showSystemStatus) {
            SystemStatusSheet(onClose: { showSystemStatus = false })
        }
        .sheet(isPresented: $showHealModal) {
            HealConfirmSheet(
                onCancel: { showHealModal = false },
                onCompletion: { showHealModal = false }
            )
            .environmentObject(session)
        }
        .alert("Burn \(session.activeWallet?.factScarCount() ?? 0) scarred link(s)?",
               isPresented: $showBurnConfirm) {
            Button("Cancel", role: .cancel) { showBurnConfirm = false }
            Button("Burn — destroys value", role: .destructive) {
                burnFeedback = nil
                do {
                    let burned = try session.activeWallet?.burnScars() ?? 0
                    let remaining = session.activeWallet?.factScarCount() ?? 0
                    burnFeedback = "Burned \(burned) scarred link(s); \(remaining) remaining."
                } catch {
                    burnFeedback = "Burn failed: \(extractFfiErrorParts(error).message)"
                }
            }
        } message: {
            Text("This permanently destroys the scarred amount on those FACT links to clean the chain so it can compress. It cannot be undone. Core recovery (heal) does not require this.")
        }
        .sheet(isPresented: $showHalReanchorModal) {
            HalRecoverySheet(
                mode: .reAnchor,
                onCancel: { showHalReanchorModal = false },
                onCompletion: { showHalReanchorModal = false }
            )
            .environmentObject(session)
        }
        .sheet(isPresented: $showHalCompleteModal) {
            HalRecoverySheet(
                mode: .complete,
                onCancel: { showHalCompleteModal = false },
                onCompletion: { showHalCompleteModal = false },
                onRestart: {
                    // Dead-new-quorum restart (§7 case 4): re-enter HAL.
                    showHalCompleteModal = false
                    showHalReanchorModal = true
                }
            )
            .environmentObject(session)
        }
        .sheet(isPresented: $showDeleteConfirm) {
            DeleteWalletSheet(
                pairName: session.activePair?.name ?? "",
                onCancel: { showDeleteConfirm = false },
                onConfirmed: {
                    showDeleteConfirm = false
                    deleteCurrentWallet()
                }
            )
        }
        .sheet(isPresented: $showDevPasscodeSheet) {
            WalletDevPasscodeSheet { entered in
                showDevPasscodeSheet = false
                if walletDevPasscodeMatches(entered) {
                    showWalletDevSheet = true
                }
                // Wrong passcode dismisses silently — no toast, no
                // shake. Re-tap "Open dev tools…" to retry.
            }
        }
        .sheet(isPresented: $showWalletDevSheet) {
            WalletDevToolsSheet(onDone: { showWalletDevSheet = false })
                .environmentObject(session)
        }
    }

    /// Delete the active pair: release every wallet handle, drop the
    /// pair from `pairs.json`, remove its wallet directories, and lock
    /// the session back to the login screen. Other pairs are untouched.
    private func deleteCurrentWallet() {
        guard let pair = session.activePair else { return }
        let parentDir = defaultWalletDir()
        let pairName = pair.name
        // Resolve the on-disk directory names from the registry before
        // we tear anything down.
        let registered = (try? listWalletPairs(parentDir: parentDir)) ?? []
        let entry = registered.first { $0.name == pairName }
        let dirNames = [entry?.normalWalletName, entry?.arkWalletName]
            .compactMap { $0 }

        // Drop the pair from the registry, then remove its directories.
        removePairFromRegistry(pairName, parentDir: parentDir)
        for name in dirNames {
            try? FileManager.default.removeItem(atPath: "\(parentDir)/\(name)")
        }

        // Relaunch — a fresh process is the only clean reset. Staying
        // in-process silently switches the session to another pair
        // while still inside Settings, which makes it dangerously easy
        // to delete the wrong wallet next. A relaunch guarantees a
        // clean return to the login screen. (Same reason Recovery's
        // "erase everything" relaunches — the SDK's process-global
        // Runtime is behind a OnceLock and can't be re-pointed.)
        relaunchAxiomWallet()
    }

    /// Remove one pair's entry from `pairs.json`. Mirrors the
    /// `orphanedPairEntry` fix in WalletDiagnostic — the FFI has no
    /// "remove pair" call, so we edit the registry JSON directly.
    private func removePairFromRegistry(_ pairName: String, parentDir: String) {
        let path = "\(parentDir)/pairs.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var pairs = json["pairs"] as? [String: Any]
        else { return }
        pairs.removeValue(forKey: pairName)
        json["pairs"] = pairs
        if let new = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? new.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Recover stuck cheque bundles by re-scanning `maildir/inbox/cur`
    /// and re-ingesting every cheque .eml through the bundle
    /// accumulator. Wraps the FFI's `rescan_inbox_cur` and dumps the
    /// counts to the result-lines pane. Runs on the active wallet.
    fileprivate func runRescanInboxCur() {
        guard let wallet = session.activeWallet else {
            rescanResultLines = ["(no active wallet)"]
            return
        }
        rescanInProgress = true
        rescanResultLines = ["[\(stamp())] Scanning maildir/inbox/cur…"]
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<RescanInboxCurRow, Error> = Result {
                try wallet.rescanInboxCur()
            }
            DispatchQueue.main.async {
                rescanInProgress = false
                switch result {
                case .success(let r):
                    var log = rescanResultLines
                    log.append("[\(stamp())] Scanned \(r.scanned) .eml file(s)")
                    log.append("[\(stamp())] Ingested: \(r.ingested) (cheques newly merged into bundles)")
                    log.append("[\(stamp())] Already present: \(r.already)")
                    log.append("[\(stamp())] Already redeemed (skipped): \(r.alreadyRedeemed)")
                    log.append("[\(stamp())] Not a cheque: \(r.notCheque) (witness_responses, errors, other mail)")
                    log.append("[\(stamp())] Not addressed to this wallet: \(r.notMine)")
                    if r.alreadyRedeemed > 0 {
                        log.append("[\(stamp())] ⚠ \(r.alreadyRedeemed) cheque(s) were skipped because they correspond to a Redeem in wallet history. Pre-fix this rescan would have re-created those bundles, allowing a replay-redeem path. The SDK redeem function also refuses replay locally now (txid matched against history).")
                    }
                    if r.ingested > 0 {
                        log.append("[\(stamp())] → \(r.ingested) bundle(s) updated. Existing list_cheques() / redeem() will pick them up.")
                    } else if r.scanned == 0 {
                        log.append("[\(stamp())] (maildir/inbox/cur is empty — nothing to recover)")
                    } else if r.alreadyRedeemed == 0 {
                        log.append("[\(stamp())] No new cheques to recover — bundles already reflect every cheque in inbox/cur.")
                    }
                    rescanResultLines = log
                case .failure(let err):
                    rescanResultLines.append("[\(stamp())] Failed: \(err.localizedDescription)")
                }
            }
        }
    }

    private func stamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: Date())
    }

    /// Three-tile counter block used in the Wallet recovery card.
    /// `warn` flips the value tint to amber for the "heal needed" case.
    private func healCounter(_ label: String, value: String, warn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text(value)
                .font(DesignTokens.Typography.mono)
                .foregroundStyle(warn ? DesignTokens.statusScarredFg : DesignTokens.textPrimary)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xxs, leading: DesignTokens.Spacing.xs, bottom: DesignTokens.Spacing.xxs, trailing: DesignTokens.Spacing.xs))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }

    // ── HAL card (YPX-020) ──────────────────────────────────────────
    // Manual, always-available HAL recovery controls. NOT a simulation:
    // these run the real protocol (hal_reanchor/hal_complete FFI ->
    // TxKind::HalReanchor/HalComplete, witnessed by live validators) —
    // the same path the reactive dead-overlap/hibernation banners use.
    // HAL (Help Absent Lambda) re-anchors a wallet whose prior validators
    // are gone — the one recovery heal() can't do. This card lets the
    // operator run the full cycle on demand + explains the model with
    // Yellow-Paper references.
    @ViewBuilder
    private var halCard: some View {
        settingsCard(title: "HAL — dead-overlap recovery (YPX-020)") {
            Text("HAL (Help Absent Lambda) recovers a wallet whose prior validators have all gone away, so it can no longer meet the k-1 S-ABR overlap and is stuck. heal() cannot fix this — HAL re-anchors the wallet onto a fresh validator quorum with a key-proved self-send (X → X′).")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
            Text("Two-step, binary model (YPX-020 §7): (1) Re-anchor FREEZES the wallet — Core hard-rejects every transaction except the completion or a restart while the flag is set; (2) Finish recovery (Complete HAL) clears the flag and the wallet is live again. The lock is a binary flag, not a timer — it clears only on completion.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
            Text("Safety: the relaxed synchronous overlap is covered by the global Nabla consume-once + fork-detection + the scar floor — a hibernating wallet can never cleanly double-spend (YPX-020 §2 safety invariant, §3 analysis).")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)

            let hib = session.isHibernating
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let est = session.hibernationConvergenceEstimateSecs()
                HStack(spacing: DesignTokens.Spacing.sm) {
                    healCounter("HAL state",
                                value: hib ? "hibernating" : "normal",
                                warn: hib)
                    healCounter("Est. convergence window",
                                value: hib
                                    ? (est > 0 ? "\(HalRecovery.estimateLabel(est)) remaining" : "likely ready now")
                                    : "—",
                                warn: hib && est > 0)
                }
            }

            Text("This runs the real protocol, not a simulation. Re-anchoring WILL FREEZE this wallet (Send/Redeem disabled) until you Finish recovery — which self-cleans, leaving no dangling cheques. Needs a live network for the witness round.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.statusScarredFg)
                .lineSpacing(2)

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Re-anchor wallet (HAL)…") { showHalReanchorModal = true }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(session.activeWallet == nil)
                Button("Finish recovery (Complete HAL)…") { showHalCompleteModal = true }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(session.activeWallet == nil || !hib)
                    .help(hib
                          ? "Complete the re-anchor and clear hibernation"
                          : "Available after a re-anchor (wallet must be hibernating)")
                Spacer()
            }

            Text("Spec: Yellow Paper YPX-020 — Help Absent Lambda · docs/AXIOM_YPX-020_HAL.md  (§2 protocol · §3 security · §7 binary model, as-built)")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .textSelection(.enabled)
                .padding(.top, 2)
        }
    }

    // ── Recovery comparison table ───────────────────────────────────
    // A one-glance HEAL/HAL/RECALL diff for contributors: what each recovers,
    // what happens to the money, and how many steps.
    @ViewBuilder
    private var recoveryComparisonTable: some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: DesignTokens.Spacing.sm,
             verticalSpacing: DesignTokens.Spacing.xs) {
            GridRow {
                recoveryHeadCell("Op")
                recoveryHeadCell("Recovers")
                recoveryHeadCell("Money")
                recoveryHeadCell("Steps")
            }
            Divider().gridCellColumns(4)
            recoveryRow("HEAL",   "Partial commit — witnesses live, state drifted",       "Lost (accepts the debit)", "1")
            recoveryRow("HAL",    "Dead overlap — prior validators all gone",             "n/a (re-anchor only)",     "2")
            recoveryRow("RECALL", "Completed send whose cheque never reached the receiver", "Recovered (retracted)",   "2")
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.sm, leading: DesignTokens.Spacing.sm, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private func recoveryHeadCell(_ t: String) -> some View {
        Text(t)
            .font(DesignTokens.Typography.sectionLabel)
            .tracking(0.4)
            .foregroundStyle(DesignTokens.textTertiary)
    }

    @ViewBuilder
    private func recoveryRow(_ op: String, _ recovers: String, _ money: String, _ steps: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(op)
                .font(DesignTokens.Typography.monoSmall)
                .foregroundStyle(DesignTokens.brandPrimary)
            Text(recovers)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(money)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(op == "RECALL" ? DesignTokens.statusCleanFg : DesignTokens.textSecondary)
            Text(steps)
                .font(DesignTokens.Typography.monoSmall)
                .foregroundStyle(DesignTokens.textSecondary)
        }
    }

    // ── RECALL card (YPX-022, repurposed 2026-07-07) ────────────────
    // Retract a COMPLETED but UNDELIVERED payment — a send that reached
    // 3-of-3 and debited this wallet, whose cheque never reached the
    // receiver, and which the receiver has NOT redeemed. Deliberate, not
    // failure-reactive: the entry point is the Sent-payments surface.
    // Two-step like HAL: recall (reservation → witnessed commit +
    // hibernate) then finish (redeem the recall cheque).
    @ViewBuilder
    private var recallCard: some View {
        settingsCard(title: "RECALL — retract a payment (YPX-022)") {
            Text("RECALL retracts a payment the receiver hasn't redeemed yet — it doesn't matter whether the cheque reached them or not. The cheque is permanently cancelled and the amount returns to you. Once the receiver redeems, the payment is final and can't be recalled (redeem wins).")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
            Text("Deliberate, not reactive: a payment becomes recallable only after it has gone UNCLAIMED for the protected window — the receiver's fair chance to redeem always comes first. Two-phase: initiating opens a reservation (the cheque stays redeemable; a redeem that lands during it WINS and the recall aborts), then the witnessed recall commits and the wallet hibernates while the retract converges. Finishing redeems the recall cheque — the only step that credits the balance.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
            Text("A payment the receiver redeemed is final and can never be recalled — first-wins. Exactly one of {recall, redeem} ever settles per payment (consume-once).")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)

            Text("Recall a payment from the Activity tab — tap a sent payment and use its Recall button.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)

            Text("Spec: Yellow Paper YPX-022 — RECALL · docs/AXIOM_YPX-022_RECALL.md  (§2 protocol · §2.2.1 reservation/commit · §3 safety · §4 why RECALL ≠ repudiating a received cheque). Also Yellow Paper §17.14.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .lineSpacing(2)
        }
    }

    // ── Diagnostic report card ──────────────────────────────────────
    // Exports a sanitised plain-text wallet diagnostic dump to
    // ~/Downloads for pasting into bug reports / chat / GitHub issue.
    // No private keys, secrets, or full PII. See
    // DiagnosticReport.swift for the privacy posture.

    @ViewBuilder
    fileprivate var diagnosticReportCard: some View {
        settingsCard(title: "Export diagnostic report") {
            Text("Writes a sanitised plain-text snapshot of the active wallet — state counters, diagnose() actions, pending cheques, scarred links, recent history, tier addresses, version info — to ~/Downloads. For pasting into bug reports. No private keys, secrets, or full PII included; addresses truncated, email local-part redacted.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Export to ~/Downloads") {
                    do {
                        // Derive the wallet's on-disk directory from
                        // the pair name + mode (matches the layout
                        // AddPairView creates). The diagnostic report
                        // walks this directory for maildir / cheques /
                        // outbox content — the canonical evidence for
                        // transport-layer bugs lives there.
                        let walletDir: String? = session.activePair.map { pair in
                            let modeSuffix: String
                            switch session.activeMode {
                            case .normal: modeSuffix = "normal"
                            case .ark:    modeSuffix = "ark"
                            }
                            return defaultWalletDir() + "/" + pair.name + "-" + modeSuffix
                        }
                        let url = try DiagnosticReport.writeToDownloads(
                            wallet: session.activeWallet,
                            walletDir: walletDir,
                        )
                        lastDiagnosticURL = url
                        diagnosticExportError = nil
                    } catch {
                        diagnosticExportError = "Write failed: \(error.localizedDescription)"
                        lastDiagnosticURL = nil
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                if let url = lastDiagnosticURL {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                Spacer()
            }
            if let url = lastDiagnosticURL {
                Text("Wrote \(url.lastPathComponent)")
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .textSelection(.enabled)
                    .padding(.top, DesignTokens.Spacing.xxs)
            }
            if let err = diagnosticExportError {
                Text(err)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                    .padding(.top, DesignTokens.Spacing.xxs)
            }
        }
    }
}

// =================================================================
// Shared helpers
// =================================================================
private func sectionHeader(_ title: String) -> some View {
    Text(LocalizedStringKey(title))
        .font(DesignTokens.Typography.heading)
}

@ViewBuilder
private func settingsCard<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Text(title.uppercased())
            .font(DesignTokens.Typography.sectionLabel)
            .tracking(0.4)
            .foregroundStyle(DesignTokens.textTertiary)
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }
}

/// Subtle hover wash for custom plain-button rows that open a detail
/// popover (validator hint rows). Visual feedback only — bgTertiary
/// fill, Motion.quick() fade (nil under Reduce Motion), no behaviour
/// change. Non-interactive rows (Nabla node list) deliberately do not
/// use this.
private struct HoverRowHighlight: ViewModifier {
    @State private var isHovered: Bool = false

    func body(content: Content) -> some View {
        content
            .background(isHovered ? DesignTokens.bgTertiary : Color.clear)
            .onHover { hovering in
                withAnimation(DesignTokens.Motion.quick()) {
                    isHovered = hovering
                }
            }
    }
}

private func anchorRow(label: String, sublabel: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
        Text(label.uppercased())
            .font(DesignTokens.Typography.sectionLabel)
            .tracking(0.4)
            .foregroundStyle(DesignTokens.textTertiary)
        Text(sublabel)
            .font(DesignTokens.Typography.micro)
            .foregroundStyle(DesignTokens.textTertiary)
        Text(value)
            .font(DesignTokens.Typography.monoSmall)
            .padding(DesignTokens.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.bgPrimary)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.control)
                    .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
            .textSelection(.enabled)
    }
    .padding(.vertical, DesignTokens.Spacing.xxs)
}

private func placeholderRow(_ label: String, detail: String) -> some View {
    HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.label)
                .foregroundStyle(DesignTokens.textSecondary)
            Text(detail)
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
        }
        Spacer()
        Text("Pending")
            .font(DesignTokens.Typography.chip)
            .tracking(0.3)
            .foregroundStyle(DesignTokens.textTertiary)
            .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, 3)
            .background(DesignTokens.bgTertiary)
            .clipShape(Capsule())
    }
    .padding(.vertical, DesignTokens.Spacing.xxs)
}

// ── Carriers cell with hover info popover ──────────────────────────

/// Compact carrier display: one capsule per scheme (`email`, `fatmama`,
/// `tcp`, ...), color-coded. Hovering the cell opens a small info
/// popover listing every carrier URI in mono. Click on the parent row
/// opens the full validator detail popover — the two interactions
/// don't conflict because hover dismisses on click.
struct CarriersCell: View {
    let carriers: [String]
    /// Operator encryption scheme tag ("PGP" / "GPG" / …) from the
    /// validator's hint. Empty or "none" ⇒ no 🔒 chip is shown.
    var encryptionScheme: String = ""
    /// Short fingerprint of the operator's encryption key — surfaced
    /// in the hover panel. Empty ⇒ omitted.
    var encryptionFingerprint: String = ""
    @State private var isHovering: Bool = false

    /// True when the validator advertises a usable encryption key.
    private var hasEncryption: Bool {
        !encryptionScheme.isEmpty && encryptionScheme.lowercased() != "none"
    }

    var body: some View {
        Group {
            if carriers.isEmpty {
                Text("—")
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // FlowLayout wraps chips onto a new line within the
                // cell's allotted width. The row's height grows for
                // validators that advertise lots of carriers; rows
                // with one or two carriers stay compact. No
                // truncation, no "+N" overflow — every scheme is
                // visible at a glance.
                FlowLayout(spacing: 3, lineSpacing: 3) {
                    let schemes = uniqueSchemes(carriers)
                    ForEach(Array(schemes.enumerated()), id: \.offset) { _, scheme in
                        schemeChip(scheme)
                    }
                    if hasEncryption {
                        encryptionChip(encryptionScheme)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in isHovering = hovering }
        .popover(isPresented: $isHovering, arrowEdge: .bottom) {
            carriersInfoPanel
        }
    }

    /// Distinct schemes in carrier-list order, preserved (so the first
    /// chip is the operator's preferred carrier per YP §26.9.3).
    private func uniqueSchemes(_ uris: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for uri in uris {
            let s = scheme(of: uri)
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }

    private func scheme(of uri: String) -> String {
        if let idx = uri.firstIndex(of: ":") {
            return String(uri[..<idx])
        }
        return uri
    }


    private var carriersInfoPanel: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("\(carriers.count) carrier\(carriers.count == 1 ? "" : "s")")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.3)
                .foregroundStyle(DesignTokens.textTertiary)
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(carriers.enumerated()), id: \.offset) { _, uri in
                    HStack(spacing: DesignTokens.Spacing.xxs) {
                        Text(scheme(of: uri))
                            .font(DesignTokens.Typography.chip)
                            .tracking(0.3)
                            .foregroundStyle(colourForScheme(scheme(of: uri)))
                            .frame(width: 56, alignment: .leading)
                        Text(uri)
                            .font(DesignTokens.Typography.monoSmall)
                            .foregroundStyle(DesignTokens.textPrimary)
                            .textSelection(.enabled)
                    }
                }
            }
            Text("Tried in order — first carrier is preferred (YP §26.9.3).")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .padding(.top, DesignTokens.Spacing.xxs)
            if hasEncryption {
                Divider()
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Text("🔒 \(encryptionScheme.uppercased())")
                        .font(DesignTokens.Typography.chip)
                        .tracking(0.3)
                        .foregroundStyle(DesignTokens.statusCleanFg)
                    if !encryptionFingerprint.isEmpty {
                        Text("key \(encryptionFingerprint)")
                            .font(DesignTokens.Typography.monoSmall)
                            .foregroundStyle(DesignTokens.textPrimary)
                            .textSelection(.enabled)
                    }
                }
                Text("Operator encryption key — UMP can be sealed to this validator.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(minWidth: 320, alignment: .leading)
    }
}

// ── Shared scheme chip + colour map ────────────────────────────────
// Lifted out of `CarriersCell` so the Settings -> "Carrier preferences"
// card can render the same chip style. Free functions (file-scope) —
// callable from anywhere in this target.

func colourForScheme(_ s: String) -> Color {
    switch s {
    case "email":                          return DesignTokens.statusCleanFg
    case "fatmama":                        return DesignTokens.brandPrimary
    case "tcp", "uncle":                   return DesignTokens.statusScarredFg
    case "ws", "wss", "websocket", "tot":  return Color(red: 0.10, green: 0.55, blue: 0.70)
    case "cousin":                         return Color(red: 0.55, green: 0.25, blue: 0.65)
    case "p2p":                            return Color(red: 0.40, green: 0.30, blue: 0.75)
    case "grpc":                           return Color(red: 0.15, green: 0.50, blue: 0.40)
    case "https":                          return Color(red: 0.20, green: 0.45, blue: 0.80)
    default:                               return DesignTokens.textTertiary
    }
}

func schemeChip(_ scheme: String) -> some View {
    let colour = colourForScheme(scheme)
    return Text(scheme)
        .font(DesignTokens.Typography.chip)
        .tracking(0.3)
        .foregroundStyle(colour)
        .padding(.horizontal, DesignTokens.Spacing.xxs).padding(.vertical, 2)
        .background(colour.opacity(0.14))
        .clipShape(Capsule())
}

/// Chip marking a validator that advertises an operator encryption
/// key — rendered alongside the carrier chips so an encrypted-
/// reachable validator is obvious at a glance (YP §27).
func encryptionChip(_ scheme: String) -> some View {
    let colour = DesignTokens.statusCleanFg
    return Text("🔒 \(scheme.uppercased())")
        .font(DesignTokens.Typography.chip)
        .tracking(0.3)
        .foregroundStyle(colour)
        .padding(.horizontal, DesignTokens.Spacing.xxs).padding(.vertical, 2)
        .background(colour.opacity(0.14))
        .clipShape(Capsule())
}

/// Short fingerprint of an operator encryption key — first 4 bytes of
/// its SHA-256, hex. Not a canonical PGP fingerprint, just a stable
/// visual identifier for the Settings hover panel. Empty in ⇒ empty out.
func encryptionKeyFingerprint(_ key: String) -> String {
    guard !key.isEmpty else { return "" }
    let digest = SHA256.hash(data: Data(key.utf8))
    return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
}

// ── Flow layout (wraps children onto multiple lines) ───────────────

/// Lightweight wrapping layout — places subviews left-to-right with
/// `spacing` between them, breaking to a new line when the next
/// subview would exceed the proposed width. Used by `CarriersCell`
/// so validators with many carrier schemes wrap inside the row
/// instead of overflowing the table or being truncated by a "+N"
/// cap.
///
/// Implements SwiftUI's `Layout` protocol (macOS 13+). Single-pass
/// in `sizeThatFits`; `placeSubviews` re-runs the same wrap algorithm
/// to compute each subview's origin.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout Void) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            // First item on a row, or fits on the current row.
            if rowWidth == 0 || rowWidth + spacing + size.width <= width {
                rowWidth += (rowWidth == 0 ? 0 : spacing) + size.width
                rowHeight = max(rowHeight, size.height)
            } else {
                // Wrap to next row.
                totalHeight += rowHeight + lineSpacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        let width = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.minX + width {
                // Wrap.
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// ── Validator detail popover ───────────────────────────────────────

/// Snapshot of one validator's union of seed + live state, captured at
/// the moment a row was clicked. The popover renders this — even if
/// the underlying tables refresh while the popover is open, the user
/// sees the data they clicked.
struct ValidatorDetail: Identifiable {
    let id = UUID()
    let name: String
    /// Lowercase hex, from live cache. `nil` when validator hasn't
    /// been observed in any response yet (seed-only row).
    let validatorId: String?
    /// `nil` for live-only rows (validator known via gossip, not in
    /// the bootstrap list).
    let email: String?
    /// `nil` if the seed file's 4th column was absent — wallet ships
    /// `UmpEnvelope::Plain` to this validator.
    let ed25519Pk: Data?
    /// Either the live carriers (preferred) or `["email:<email>"]`
    /// derived from the seed row when no live data is available.
    let carriers: [String]
    let proofCap: String?
    /// Validator-reported last_seen tick (live cache field). `0` if
    /// never observed live.
    let lastSeen: UInt64
    /// Unix seconds when this client last saw the validator's hint.
    /// `0` if never observed live (seed-only row).
    let observedAt: UInt64
    let picks: Int
    let isBlacklisted: Bool
    let isPreviousWitness: Bool
    /// Captured `now` so relative-time labels in the popover match
    /// the row that was clicked.
    let now: UInt64
}

private struct ValidatorDetailPopover: View {
    let detail: ValidatorDetail

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Text(detail.name)
                    .font(DesignTokens.Typography.heading)
                    .foregroundStyle(DesignTokens.textPrimary)
                badgesView
                Spacer()
            }
            Divider()
            detailRow(label: "validator_id", value: detail.validatorId ?? "—",
                      mono: true, selectable: detail.validatorId != nil)
            detailRow(label: "email", value: detail.email ?? "—",
                      mono: true, selectable: detail.email != nil)
            carriersBlock
            detailRow(label: "proof_cap", value: detail.proofCap ?? "—", mono: true)
            ed25519Block
            HStack(spacing: DesignTokens.Spacing.xl) {
                detailRow(label: "picks",
                          value: detail.picks > 0 ? "\(detail.picks)×" : "—",
                          mono: true)
                detailRow(label: "last_seen (tick)",
                          value: detail.lastSeen > 0 ? "\(detail.lastSeen)" : "—",
                          mono: true)
                detailRow(label: "observed",
                          value: observedLabel,
                          mono: true)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: 460, alignment: .leading)
    }

    @ViewBuilder
    private var badgesView: some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            if detail.isBlacklisted {
                badge("Blacklisted", DesignTokens.statusRejectedFg)
            }
            if detail.isPreviousWitness {
                badge("Witnessed last TX", DesignTokens.brandPrimary)
            }
            if detail.observedAt == 0 {
                badge("Seed only", DesignTokens.textTertiary)
            }
        }
    }

    private func badge(_ text: String, _ colour: Color) -> some View {
        Text(LocalizedStringKey(text))
            .font(DesignTokens.Typography.chip)
            .tracking(0.3)
            .foregroundStyle(colour)
            .padding(.horizontal, DesignTokens.Spacing.xxs).padding(.vertical, 2)
            .background(colour.opacity(0.12))
            .clipShape(Capsule())
    }

    private var carriersBlock: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("carriers")
                .font(DesignTokens.Typography.monoSmall)
                .foregroundStyle(DesignTokens.textTertiary)
            if detail.carriers.isEmpty {
                Text("—").font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(detail.carriers.enumerated()), id: \.offset) { _, uri in
                        Text(uri)
                            .font(DesignTokens.Typography.monoSmall)
                            .foregroundStyle(DesignTokens.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var ed25519Block: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("ed25519_pk")
                .font(DesignTokens.Typography.monoSmall)
                .foregroundStyle(DesignTokens.textTertiary)
            if let pk = detail.ed25519Pk, !pk.isEmpty {
                Text(pk.map { String(format: "%02x", $0) }.joined())
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("(not published — Plain envelope)")
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textTertiary)
            }
        }
    }

    private var observedLabel: String {
        guard detail.observedAt > 0, detail.now >= detail.observedAt else { return "—" }
        let delta = detail.now - detail.observedAt
        switch delta {
        case 0..<60:        return "\(delta)s ago"
        case 60..<3600:     return "\(delta / 60)m ago"
        case 3600..<86400:  return "\(delta / 3600)h ago"
        default:            return "\(delta / 86400)d ago"
        }
    }

    @ViewBuilder
    private func detailRow(label: String, value: String,
                           mono: Bool, selectable: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.monoSmall)
                .foregroundStyle(DesignTokens.textTertiary)
            let body = Group {
                if mono {
                    Text(value).font(DesignTokens.Typography.monoSmall)
                } else {
                    Text(value).font(DesignTokens.Typography.caption)
                }
            }
            .foregroundStyle(DesignTokens.textPrimary)
            if selectable {
                body.textSelection(.enabled)
            } else {
                body.textSelection(.disabled)
            }
        }
    }
}
