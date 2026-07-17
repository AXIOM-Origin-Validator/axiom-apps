import Foundation
import SwiftUI

// DEBUG-only: the entire fault-injection surface compiles out of the
// release build. `swift build` (dev) defines DEBUG; `swift build -c
// release` (release-dmg.sh) does not — so the shipped app has no fault
// UI at all. This aligns with the Rust side: the SDK `chaos` feature is
// off in the release lib, so even a stray env var is a no-op. Both gates
// are belt-and-suspenders; either alone neuters fault injection in release.
#if DEBUG

// =================================================================
// FaultInjection — tester-facing fault switches (dev builds).
//
// The Rust SDK reads its chaos hooks from process environment
// variables at OPERATION TIME (per-call `std::env::var`), and the FFI
// runs IN-PROCESS, so a Swift `setenv`/`unsetenv` flips the next SDK
// call's behavior live — no new FFI, no protocol surface, no restart.
// This is the same mechanism the soak harness uses from the shell;
// here it's a tickable menu in Dev Tools so a tester can generate
// failures on demand (scarred sends, Core-rejected sends, …).
//
// Only knobs the SDK ACTUALLY reads are listed — a toggle that did
// nothing would be worse than no toggle. Current live knobs:
//   • AXIOM_CHAOS_NABLA_REGISTER_FAIL_RATE (sdk/client/src/nabla.rs)
//   • AXIOM_OODS_INJECT                     (sdk/client/src/send.rs)
//
// Persistence: each switch is @AppStorage-backed and re-applied to the
// process env at launch (applyPersistedAtLaunch), so a Finder-launched
// .app behaves like a terminal launch that exported the var. Because a
// left-on fault is dangerous, `anyActive` drives a always-visible
// banner (see ActiveFaultsBanner) and Dev Tools shows the armed set.
// =================================================================

enum FaultInjection {

    // ── Persisted switch state (UserDefaults keys) ─────────────────
    // Not @AppStorage here (this is a plain helper, not a View); we
    // read/write UserDefaults directly and expose an ObservableObject
    // (FaultInjectionModel) for the UI.
    private static let keyRegisterFail = "axiom.fault.nablaRegisterFail"        // Bool
    private static let keyRegisterRate = "axiom.fault.nablaRegisterFailRate"    // Int (1-in-N)
    private static let keyOodsInject   = "axiom.fault.oodsInject"               // String mode ("" = off)

    /// Env-var names the SDK reads. Kept next to the keys so a rename
    /// in the SDK is a one-line change here.
    static let envRegisterFail = "AXIOM_CHAOS_NABLA_REGISTER_FAIL_RATE"
    static let envOodsInject   = "AXIOM_OODS_INJECT"
    static let envDieAtHop     = "AXIOM_CHAOS_SEND_DIE_AT_HOP"
    static let envDieMode      = "AXIOM_CHAOS_SEND_DIE_MODE"

    /// The two ways a partial commit arises, tester-selectable
    /// (sdk/client/src/send.rs witness loop).
    static let dieModes: [(id: String, label: String)] = [
        ("before", "Validator never receives the request"),
        ("after",  "Validator witnesses, client fails to receive"),
    ]

    /// The three OODS corruption modes the SDK dispatches on
    /// (send.rs) — each makes Core hard-reject the send.
    static let oodsModes: [(id: String, label: String)] = [
        ("tamper_sig",   "Tamper attestation signature"),
        ("strip_anchor", "Strip root-authority anchor"),
        ("foreign_pk",   "Foreign Nabla node key"),
    ]

    // ── Apply / clear against the live process env ─────────────────

    static func applyRegisterFail(_ on: Bool, rate: Int) {
        if on {
            setenv(envRegisterFail, String(max(1, rate)), 1)
        } else {
            unsetenv(envRegisterFail)
        }
    }

    static func applyOodsInject(_ mode: String) {
        if mode.isEmpty {
            unsetenv(envOodsInject)
        } else {
            setenv(envOodsInject, mode, 1)
        }
    }

    static func applyDieAtHop(_ on: Bool, hop: Int, mode: String) {
        if on {
            setenv(envDieAtHop, String(max(1, hop)), 1)
            setenv(envDieMode, mode.isEmpty ? "after" : mode, 1)
        } else {
            unsetenv(envDieAtHop)
            unsetenv(envDieMode)
        }
    }

    /// Re-apply every persisted switch to the process env. Call once at
    /// launch (AppDelegate) so a packaged .app matches a shell that
    /// exported the vars. Safe to call before the SDK is set up — these
    /// are read per-operation, not at setup.
    static func applyPersistedAtLaunch() {
        let d = UserDefaults.standard
        applyRegisterFail(d.bool(forKey: keyRegisterFail),
                          rate: d.integer(forKey: keyRegisterRate))
        applyOodsInject(d.string(forKey: keyOodsInject) ?? "")
        applyDieAtHop(d.bool(forKey: keyDieAtHop),
                      hop: d.integer(forKey: keyDieAtHopN),
                      mode: d.string(forKey: keyDieMode) ?? "after")
    }

    private static let keyDieAtHop  = "axiom.fault.sendDieAtHop"       // Bool
    private static let keyDieAtHopN = "axiom.fault.sendDieAtHopN"      // Int (round)
    private static let keyDieMode   = "axiom.fault.sendDieMode"        // String
}

/// Observable UI model for the Dev Tools fault card + the active banner.
/// Writes UserDefaults AND applies the env change on every mutation so
/// the toggle takes effect immediately (no relaunch).
@MainActor
final class FaultInjectionModel: ObservableObject {
    @AppStorage("axiom.fault.nablaRegisterFail")
    var registerFail: Bool = false {
        didSet { apply() }
    }
    /// 1-in-N: 1 = every send fails to register (scars every send),
    /// higher = intermittent. Defaults to 1 (the scar-consent flow
    /// wants every send scarred).
    @AppStorage("axiom.fault.nablaRegisterFailRate")
    var registerFailRate: Int = 1 {
        didSet { apply() }
    }
    /// "" = off, else one of FaultInjection.oodsModes ids.
    @AppStorage("axiom.fault.oodsInject")
    var oodsInject: String = "" {
        didSet { apply() }
    }

    /// Partial-commit injection: abort the witness round at a chosen hop.
    @AppStorage("axiom.fault.sendDieAtHop")
    var dieAtHop: Bool = false {
        didSet { apply() }
    }
    /// 1-indexed witness round to die at (1 = first validator).
    @AppStorage("axiom.fault.sendDieAtHopN")
    var dieAtHopN: Int = 2 {
        didSet { apply() }
    }
    /// "before" (validator never receives) / "after" (validator
    /// witnesses, client fails to receive).
    @AppStorage("axiom.fault.sendDieMode")
    var dieMode: String = "after" {
        didSet { apply() }
    }

    var anyActive: Bool { registerFail || !oodsInject.isEmpty || dieAtHop }

    /// One-line human summary of the armed set, for the banner.
    var activeSummary: String {
        var parts: [String] = []
        if registerFail {
            parts.append(registerFailRate <= 1
                ? "Nabla register fails (every send scars)"
                : "Nabla register fails 1-in-\(registerFailRate)")
        }
        if !oodsInject.isEmpty {
            let label = FaultInjection.oodsModes.first { $0.id == oodsInject }?.label ?? oodsInject
            parts.append("OODS inject: \(label) (Core rejects send)")
        }
        if dieAtHop {
            let m = dieMode == "before" ? "validator not contacted" : "validator witnessed, client abandons"
            parts.append("Die at witness hop \(dieAtHopN) (\(m))")
        }
        return parts.joined(separator: " · ")
    }

    /// Push current state to the process env.
    func apply() {
        FaultInjection.applyRegisterFail(registerFail, rate: registerFailRate)
        FaultInjection.applyOodsInject(oodsInject)
        FaultInjection.applyDieAtHop(dieAtHop, hop: dieAtHopN, mode: dieMode)
    }

    /// Disarm everything (banner "Clear all" + Dev Tools).
    func clearAll() {
        registerFail = false
        oodsInject = ""
        dieAtHop = false
        // registerFailRate / dieAtHopN / dieMode left as-is (preferences,
        // harmless when off).
    }
}

// =================================================================
// ActiveFaultsBanner — always-visible strip while any fault is armed.
//
// A left-on fault silently corrupts every send; the banner makes the
// armed state impossible to miss and offers a one-tap disarm.
// =================================================================
struct ActiveFaultsBanner: View {
    @EnvironmentObject private var faults: FaultInjectionModel

    var body: some View {
        if faults.anyActive {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "ladybug.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
                Text("FAULT INJECTION ACTIVE — \(faults.activeSummary)")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DesignTokens.Spacing.xs)
                Button("Clear all") { faults.clearAll() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .frame(maxWidth: .infinity)
            .background(DesignTokens.statusRejectedBgSoft)
            .overlay(
                Rectangle().fill(DesignTokens.statusRejectedFg.opacity(0.4))
                    .frame(height: DesignTokens.hairline),
                alignment: .bottom
            )
        }
    }
}

/// Stable scene id for the standalone fault-injection window. Opened
/// from Dev Tools via `openWindow(id:)`; co-exists with the main
/// wallet window so a tester can arm/disarm faults WHILE driving the
/// wallet (a modal sheet would block the very thing under test).
let faultInjectionWindowID = "axiom-fault-injection"

// =================================================================
// FaultInjectionPanel — the standalone-window body.
//
// Hosts the tickable menu in its own resizable window. Same
// FaultInjectionModel the main window + banner read (injected by the
// Window scene), so a toggle here takes effect on the next SDK call
// the main window makes.
// =================================================================
struct FaultInjectionPanel: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: "ladybug.fill")
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                    Text("Fault Injection")
                        .font(.system(size: 16, weight: .semibold))
                }
                Text("This panel stays open alongside the wallet. Arm a fault, run the operation in the main window, then clear it. Switches are live (no relaunch) and persist across launches — the red banner on the main window shows whatever is armed.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                FaultInjectionCard()
                Spacer(minLength: 0)
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .frame(minWidth: 440, minHeight: 520)
        .background(DesignTokens.bgPrimary)
    }
}

// =================================================================
// FaultInjectionCard — the tickable menu (shared by the panel).
// =================================================================
struct FaultInjectionCard: View {
    @EnvironmentObject private var faults: FaultInjectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Fault injection — generate failures on demand")
                .font(.system(size: 13, weight: .medium))
            Text("Switches the SDK's chaos hooks live (in-process env vars, read per operation — no relaunch). Use to reproduce scarred sends, the scar-consent gate, and Core-rejected sends. Turn OFF when done — a left-on fault corrupts every send. Only knobs the SDK actually reads are listed.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            // ── Nabla register-fail (scar generator) ───────────────
            Toggle(isOn: $faults.registerFail) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nabla register fails → scarred send")
                        .font(.system(size: 12, weight: .medium))
                    Text("The witness round succeeds but the txid never registers with Nabla, so the new FACT link stays unresolved (a genuine scar). The next send from this wallet then trips the scar-consent gate. \(FaultInjection.envRegisterFail)")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if faults.registerFail {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text("Rate: 1 in")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.textSecondary)
                    Stepper(value: $faults.registerFailRate, in: 1...50) {
                        Text("\(faults.registerFailRate)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(minWidth: 22)
                    }
                    Text(faults.registerFailRate <= 1 ? "(every send)" : "sends")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                .padding(.leading, 40)
            }

            Divider().padding(.vertical, 2)

            // ── OODS attestation corruption (Core reject) ──────────
            VStack(alignment: .leading, spacing: 2) {
                Text("OODS attestation corruption → Core rejects send")
                    .font(.system(size: 12, weight: .medium))
                Text("Corrupts the OODS attestation the SDK carries so Core hard-rejects the send with E_OODS_ATTESTATION_INVALID. \(FaultInjection.envOodsInject)")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $faults.oodsInject) {
                    Text("Off").tag("")
                    ForEach(FaultInjection.oodsModes, id: \.id) { mode in
                        Text(mode.label).tag(mode.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .padding(.leading, 4)
            }

            Divider().padding(.vertical, 2)

            // ── Partial commit: die at a chosen witness hop ────────
            Toggle(isOn: $faults.dieAtHop) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Partial commit → die at witness hop")
                        .font(.system(size: 12, weight: .medium))
                    Text("Aborts the witness round at the round you pick, so the send never reaches quorum. Exercises the partial-commit / heal-forward recovery path. \(FaultInjection.envDieAtHop)")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if faults.dieAtHop {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Text("Die at witness round")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.textSecondary)
                        Stepper(value: $faults.dieAtHopN, in: 1...5) {
                            Text("\(faults.dieAtHopN)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .frame(minWidth: 22)
                        }
                        Text("(1 = first validator)")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignTokens.textTertiary)
                    }
                    Picker("", selection: $faults.dieMode) {
                        ForEach(FaultInjection.dieModes, id: \.id) { m in
                            Text(m.label).tag(m.id)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Text("Rounds beyond the recipient's tier (k) never fire — a k=3 send has rounds 1–3.")
                        .font(.system(size: 9))
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                .padding(.leading, 40)
            }

            if faults.anyActive {
                Divider().padding(.vertical, 2)
                HStack {
                    Label("Faults are armed — remember to clear before real testing.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.statusScarredFg)
                    Spacer()
                    Button("Clear all") { faults.clearAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#endif // DEBUG
