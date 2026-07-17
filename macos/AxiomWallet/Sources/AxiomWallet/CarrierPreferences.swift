import SwiftUI
import AxiomSdk

// ===========================================================================
// CarrierPreferences — which UMP carriers the wallet uses, in what order.
//
// The protocol mandates `email:` as the floor (every validator advertises an
// email carrier — see sdk/core/src/hints.rs::has_email_carrier). The user
// layers preferred carriers above it (`TOT`, dev-only `FATMAMA`). On each
// TX the SDK picks k validators advertising the user's preferred carriers,
// falling back to the email-pool when it can't form k. Email is implicit —
// always at the bottom of the priority order, never stored in the list.
//
// FATMAMA is a developer carrier (`AXIOM_YPX-019_FATMAMA_CARRIER.md` —
// Status: Dev-scoped). Its row is dev-passcode-gated, and hidden entirely
// behind `AXIOM_RELEASE_BUILD` so a general-user binary can't even see it.
//
// YP / design anchors for the developer-curious:
//   - Yellow Paper §27.5.2 — carrier URI format.
//   - docs/AXIOM_DESIGN_TOT.md §5.1 — TOT native-client TCP intake.
//   - docs/AXIOM_YPX-019_FATMAMA_CARRIER.md — FATMAMA dev-scoped scheme.
// ===========================================================================

/// One of the carrier schemes the wallet can talk to. Matches the schemes
/// the SDK recognises (case-insensitive — `hints.rs` lower-cases on parse).
enum CarrierScheme: String, Codable, CaseIterable, Identifiable {
    case email
    case tot
    case fatmama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .email:   return "Email"
        case .tot:     return "TOT"
        case .fatmama: return "FATMAMA"
        }
    }

    /// One-line explainer with a YP / design-doc reference. The macApp is a
    /// developer demonstration — the references are part of the UX.
    var subtitle: String {
        switch self {
        case .email:
            return "Always-on fallback. Every validator advertises an email carrier (protocol mandate)."
        case .tot:
            return "Direct TCP to the validator's TOT intake — AXIOM_DESIGN_TOT.md §5.1."
        case .fatmama:
            return "Dev-only direct-TCP carrier — YPX-019. Hidden in formal release builds."
        }
    }
}

/// Persisted carrier preference for one wallet. The SDK reads this list
/// (once the carrier-aware picker lands) to filter / order the k=of=k
/// witness-round candidate set.
struct CarrierPreferences: Codable, Equatable {
    /// Non-email carriers in priority order, highest first. `email` is the
    /// implicit mandatory fallback at the bottom and is never stored here.
    var priority: [CarrierScheme]

    /// A literal empty preference — no preferred carriers. Used for the
    /// "no active wallet" state, not as the default for a real wallet.
    static let empty = CarrierPreferences(priority: [])

    /// The preference a wallet gets when it has never been configured
    /// in the carrier picker.
    ///
    /// This is a developer demonstration build whose transport IS
    /// FATMAMA (the SDK's outbound path is outbox → Kiddo → FATMAMA
    /// SMTP). So FATMAMA is the sensible default preferred carrier —
    /// and, load-bearing: it's what makes the SDK's witness-round
    /// validator selection filter to FATMAMA-reachable validators out
    /// of the box (`sdk send::carrier_reachable_validators`). Without
    /// a non-empty default here, `pushActiveToSdk` would shove an
    /// empty list into the SDK at launch and the witness round could
    /// pick validators FATMAMA can't route to.
    ///
    /// Formal-release builds (`AXIOM_RELEASE_BUILD`) fall back to
    /// empty — a general-user binary isn't on the FATMAMA dev mesh.
    static let devDefault: CarrierPreferences = {
        #if AXIOM_RELEASE_BUILD
        return CarrierPreferences(priority: [])
        #else
        return CarrierPreferences(priority: [.fatmama])
        #endif
    }()

    private static let keyFmt = "carrier_preferences.%@"

    private static func key(for w: AxiomWallet) -> String {
        String(format: keyFmt, (try? w.address()) ?? w.email())
    }

    /// Load a wallet's preference, or `.devDefault` if it has never
    /// been set in the picker.
    static func load(for w: AxiomWallet) -> CarrierPreferences {
        let key = key(for: w)
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(CarrierPreferences.self, from: data) else {
            return .devDefault
        }
        return prefs
    }

    /// Persist to UserDefaults, per-wallet. Silent on encode failure (the
    /// next change-event retries). Also pushes the new priority list to
    /// the SDK runtime so the next `wallet.send()` picks witness validators
    /// using these preferences without needing a restart.
    func save(for w: AxiomWallet) {
        let key = CarrierPreferences.key(for: w)
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
        pushToSdk()
    }

    /// Push this preference list into the SDK runtime
    /// (`axiom_sdk::runtime::set_carrier_preference`). Empty list = the
    /// SDK's email-only default. NSLog on failure (only happens if a
    /// scheme name is outside the SDK's accepted set — can't happen for
    /// our enum-derived strings, but logged for visibility during the
    /// post-wire shakeout).
    func pushToSdk() {
        let schemes = priority.map { $0.rawValue }
        do {
            try sdkSetCarrierPreference(prefs: schemes)
        } catch {
            NSLog("CarrierPreferences.pushToSdk failed: \(error)")
        }
    }

    /// Load the active wallet's carrier preferences and push them to the
    /// SDK. Call from launch (after `sdkSetup`) and on every wallet /
    /// mode switch so the SDK runtime always reflects the active wallet's
    /// picker state. When no wallet is active (locked, between sessions),
    /// clears the SDK to its email-only default.
    static func pushActiveToSdk(_ session: AppSession) {
        if let w = session.activeWallet {
            load(for: w).pushToSdk()
        } else {
            do { try sdkSetCarrierPreference(prefs: []) }
            catch { NSLog("CarrierPreferences.pushActiveToSdk (clear): \(error)") }
        }
    }
}

/// Shared dev passcode — same literal AxiomKiddo's SettingsView uses for
/// its FATMAMA add-account gate (`kFatmamaPasscode`). One passcode across
/// both apps so the dev-toggle UX is identical.
private let kFatmamaPasscode = "fatmama approve axiom"

/// Whether the FATMAMA row appears in the picker at all. The formal-release
/// build configuration defines `AXIOM_RELEASE_BUILD`; dev/demo builds do
/// not, so FATMAMA is visible (and still passcode-gated for the actual
/// tick). When hidden, FATMAMA isn't merely greyed-out — it does not appear
/// in the menu at all and cannot be added even with the passcode.
private var fatmamaVisibleInUI: Bool {
    #if AXIOM_RELEASE_BUILD
    return false
    #else
    return true
    #endif
}

/// Scheme chips this build can offer in the picker — `email` is always
/// supported (protocol floor); `tot` is always supported; `fatmama` is
/// only shown in dev builds. The strings match what `schemeChip` /
/// `colourForScheme` (in SettingsView.swift) render for the validator
/// hints table, so the picker's "this build supports" chips look
/// identical to the carrier chips on the validator rows.
private var supportedChipSchemes: [String] {
    var s: [String] = ["email", "tot"]
    if fatmamaVisibleInUI { s.append("fatmama") }
    return s
}

// =================================================================
// Picker view — embedded in Settings → Network.
// =================================================================
struct CarrierPreferencesView: View {
    @EnvironmentObject private var session: AppSession

    @State private var prefs: CarrierPreferences = .empty
    @State private var showPasscode: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Text("This build supports")
                    .font(DesignTokens.Typography.sectionLabel)
                    .foregroundStyle(DesignTokens.textSecondary)
                ForEach(supportedChipSchemes, id: \.self) { s in
                    schemeChip(s)
                }
                Spacer(minLength: 0)
            }

            Text("The wallet picks validators advertising your preferred carriers, top to bottom. Email is always at the bottom — every validator advertises it (YP §27.5.2), and the wallet falls back to email-only when it can't form a witness round on your preferred carriers.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: DesignTokens.Spacing.xxs) {
                ForEach(Array(prefs.priority.enumerated()), id: \.element.id) { idx, scheme in
                    selectedRow(scheme: scheme, index: idx)
                }
                emailRow
            }
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .padding(.horizontal, DesignTokens.Spacing.xs)
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))

            addCarrierMenu
        }
        .onAppear(perform: load)
        .onChange(of: session.activePairIndex) { _ in load() }
        .sheet(isPresented: $showPasscode) {
            PickerPasscodeSheet { entered in
                showPasscode = false
                if entered == kFatmamaPasscode {
                    add(.fatmama)
                }
            }
        }
    }

    // MARK: - rows

    private func selectedRow(scheme: CarrierScheme, index: Int) -> some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(DesignTokens.statusCleanFg)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Text(scheme.displayName)
                        .font(DesignTokens.Typography.labelStrong)
                    if scheme == .fatmama {
                        Text("DEV ONLY")
                            .font(DesignTokens.Typography.chip)
                            .tracking(0.3)
                            .padding(.horizontal, DesignTokens.Spacing.xxs).padding(.vertical, 1)
                            .background(DesignTokens.statusScarredBg)
                            .foregroundStyle(DesignTokens.statusScarredFg)
                            .clipShape(Capsule())
                    }
                }
                Text(scheme.subtitle)
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineSpacing(1)
            }
            Spacer(minLength: DesignTokens.Spacing.xs)
            Button(action: { moveUp(index) }) {
                Image(systemName: "arrow.up").font(DesignTokens.Typography.micro)
            }
            .buttonStyle(.plain)
            .disabled(index == 0)
            .foregroundStyle(index == 0 ? DesignTokens.textTertiary.opacity(0.3) : DesignTokens.textTertiary)
            .help("Move up (higher priority)")
            Button(action: { moveDown(index) }) {
                Image(systemName: "arrow.down").font(DesignTokens.Typography.micro)
            }
            .buttonStyle(.plain)
            .disabled(index == prefs.priority.count - 1)
            .foregroundStyle(index == prefs.priority.count - 1 ? DesignTokens.textTertiary.opacity(0.3) : DesignTokens.textTertiary)
            .help("Move down")
            Button(action: { remove(scheme) }) {
                Image(systemName: "xmark").font(DesignTokens.Typography.chip)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.textTertiary)
            .help("Remove from priority list")
        }
        .padding(.horizontal, DesignTokens.Spacing.xxs)
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    private var emailRow: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8))
                .foregroundStyle(DesignTokens.textTertiary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Text("Email")
                        .font(DesignTokens.Typography.labelStrong)
                        .foregroundStyle(DesignTokens.textSecondary)
                    Text("FALLBACK")
                        .font(DesignTokens.Typography.chip)
                        .tracking(0.3)
                        .padding(.horizontal, DesignTokens.Spacing.xxs).padding(.vertical, 1)
                        .background(DesignTokens.bgTertiary)
                        .foregroundStyle(DesignTokens.textTertiary)
                        .clipShape(Capsule())
                }
                Text(CarrierScheme.email.subtitle)
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .lineSpacing(1)
            }
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.xxs)
        .padding(.vertical, DesignTokens.Spacing.xxs)
        .opacity(0.85)
    }

    private var addCarrierMenu: some View {
        let candidates = CarrierScheme.allCases.filter { c in
            c != .email
                && !prefs.priority.contains(c)
                && (c != .fatmama || fatmamaVisibleInUI)
        }
        return Menu {
            ForEach(candidates) { c in
                Button(action: { requestAdd(c) }) {
                    Label(c.displayName, systemImage: c == .fatmama ? "lock" : "plus")
                }
            }
        } label: {
            Label("Add carrier", systemImage: "plus.circle")
                .font(DesignTokens.Typography.caption)
        }
        .disabled(candidates.isEmpty)
        .fixedSize()
    }

    // MARK: - actions

    private func load() {
        guard let w = session.activeWallet else { prefs = .empty; return }
        prefs = CarrierPreferences.load(for: w)
    }

    private func saveIfNeeded() {
        guard let w = session.activeWallet else { return }
        prefs.save(for: w)
    }

    private func requestAdd(_ scheme: CarrierScheme) {
        if scheme == .fatmama {
            showPasscode = true
        } else {
            add(scheme)
        }
    }

    private func add(_ scheme: CarrierScheme) {
        guard !prefs.priority.contains(scheme) else { return }
        prefs.priority.append(scheme)
        saveIfNeeded()
    }

    private func remove(_ scheme: CarrierScheme) {
        prefs.priority.removeAll { $0 == scheme }
        saveIfNeeded()
    }

    private func moveUp(_ index: Int) {
        guard index > 0, index < prefs.priority.count else { return }
        prefs.priority.swapAt(index, index - 1)
        saveIfNeeded()
    }

    private func moveDown(_ index: Int) {
        guard index >= 0, index < prefs.priority.count - 1 else { return }
        prefs.priority.swapAt(index, index + 1)
        saveIfNeeded()
    }
}

// =================================================================
// Dev-passcode sheet — same shape as AxiomKiddo's PasscodeGateSheet,
// duplicated here because Swift doesn't import private views across
// targets. Same UX: one SecureField, OK / Cancel, silent on wrong.
// =================================================================
private struct PickerPasscodeSheet: View {
    let onSubmit: (String) -> Void
    @State private var entered: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("DEV PASSCODE")
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            Text("FATMAMA is a developer carrier (YPX-019). Enter the dev passcode to add it to the priority list.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Passcode", text: $entered)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Cancel") { onSubmit("") }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button("OK") { onSubmit(entered) }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(width: 360)
    }
}
