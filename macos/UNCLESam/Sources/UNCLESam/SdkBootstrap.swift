import SwiftUI
import Foundation
import AxiomSdk

// =================================================================
// SdkBootstrap — UNCLE SAM's launch-time AXIOM-SDK initialiser.
//
// Mirrors AxiomWallet's bootstrap path but with UNCLE-SAM-shaped
// paths: app dir under `~/Library/Application Support/UNCLESam`,
// seed files copied from the bundle (validators.list +
// nabla-nodes.list + axiom.conf with maildir line stamped in),
// Core ELF path exposed via $AXIOM_CORE_ELF before sdkSetup().
//
// On failure UNCLE SAM shows SdkSetupErrorView with the searched
// paths and refuses to open the institutional wallet — same
// posture as AxiomWallet.
// =================================================================

@MainActor
final class SdkBootstrap: ObservableObject {
    enum State: Equatable {
        case pending
        case ready
        case failed(String)
    }
    @Published var state: State = .pending

    func run() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let dir = uncleAppDir()
            exportUncleBundledElfPath()
            uncleSeedHintFilesIfMissing(appDir: dir)

            let result: Result<Void, Error> = Result {
                try sdkSetup(appDir: dir)
                // Carrier preference for outbound witness UMPs.
                // Order matters — SDK tries the first matching
                // carrier per validator hint.
                //
                //   tot:   primary witness-delivery transport
                //          (TCP, low-latency, what wallet.send wants
                //           to use for the round). Most validators
                //          advertise this; needs the validator's
                //          tot:<host>:<port> exposed to the bank
                //          network.
                //   uncle: secondary. UNCLE's primary role is
                //          stored-cheque pickup on the receive side,
                //          NOT witness delivery, but its
                //          submit_send handler still routes UMPs to
                //          the validator maildir when no other
                //          carrier is reachable.
                //
                // Operator can override via @AppStorage.
                let pref = UserDefaults.standard.string(
                    forKey: "uncle.sam.sdk.carrier_preference")
                    ?? "tot,uncle"
                let prefs = pref.split(separator: ",")
                    .map { String($0.trimmingCharacters(in: .whitespaces)) }
                    .filter { !$0.isEmpty }
                if !prefs.isEmpty {
                    try? sdkSetCarrierPreference(prefs: prefs)
                    NSLog("[UNCLESam] sdk carrier preference = \(prefs.joined(separator: ","))")
                }
            }
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success:
                    self.state = .ready
                case .failure(let e):
                    self.state = .failed(e.localizedDescription)
                }
            }
        }
    }
}

/// Canonical app directory for UNCLE SAM. Distinct from
/// AxiomWallet's `Application Support/Axiom/` so the two apps
/// can coexist with separate identities + seed files + wallet
/// directories on the same Mac.
func uncleAppDir() -> String {
    let fm = FileManager.default
    if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        return appSupport.appendingPathComponent("UNCLESam").path
    }
    return NSHomeDirectory() + "/Library/Application Support/UNCLESam"
}

/// Resource lookup for the bundled Core ELF + seed defaults.
/// For the packaged `.app` we go through `Bundle.main`, which
/// finds anything copied into `Contents/Resources/` by
/// build-dev-app.sh. For `swift run` dev mode UNCLE SAM doesn't
/// need this lookup — the SDK falls back to the dev
/// `~/axiom/src/core/avm-guest/target/` search path and there's
/// no need to ship resources alongside.
func uncleBundledResource(_ name: String, withExtension ext: String) -> URL? {
    if Bundle.main.bundleURL.pathExtension == "app" {
        return Bundle.main.url(forResource: name, withExtension: ext)
    }
    return nil
}

/// Set `AXIOM_CORE_ELF` to the bundled Core ELF path so
/// `sdkSetup()` finds it via its highest-priority override. The
/// packaged .app needs this; dev (`swift run`) leaves the env var
/// unset and lets the SDK fall through to its `~/axiom/src/...`
/// dev search paths.
func exportUncleBundledElfPath() {
    // MUST match the filename build-dev-app.sh stages into Resources/
    // (axiom-core.elf). Drift here = packaged .app can't find its ELF and
    // falls back to dev source-tree paths (absent on a client) → "CL1: Core
    // ELF not found". Same class as the AxiomWallet fix (fbe4f8a7).
    if let url = uncleBundledResource("axiom-core", withExtension: "elf") {
        setenv("AXIOM_CORE_ELF", url.path, 1)
    }
}

/// Seed validators.list / nabla-nodes.list / axiom.conf from the
/// bundle when they're absent (or stub-only). Same logic shape
/// as AxiomWallet — but uses UNCLE SAM's app dir.
func uncleSeedHintFilesIfMissing(appDir: String) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: appDir, withIntermediateDirectories: true)

    let seeds: [(bundleName: String, ext: String, target: String, rewriteMaildir: Bool)] = [
        ("validators.list", "default", "validators.list", false),
        ("nabla-nodes.list", "default", "nabla-nodes.list", false),
        ("axiom.conf", "default", "axiom.conf", true),
    ]

    for seed in seeds {
        let dest = "\(appDir)/\(seed.target)"
        if uncleFileHasUsableContent(at: dest) { continue }
        guard let url = uncleBundledResource(seed.bundleName, withExtension: seed.ext),
              var contents = try? String(contentsOf: url, encoding: .utf8) else {
            continue
        }
        if seed.rewriteMaildir {
            contents = "maildir = \(appDir)/maildir\n" + contents
        }
        try? contents.write(toFile: dest, atomically: true, encoding: .utf8)
        NSLog("%@", "[UNCLESam seedHint] wrote \(seed.target) from bundled .default")
    }
}

private func uncleFileHasUsableContent(at path: String) -> Bool {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        return false
    }
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if !line.isEmpty && !line.hasPrefix("#") {
            return true
        }
    }
    return false
}

// =================================================================
// SdkSetupErrorView — shown instead of the main shell when
// `sdkSetup()` fails (typically: Core ELF missing). Banker-tone
// error UI: the institution cannot operate without the AXIOM-side
// crypto, so we refuse to fall through to the demo mock.
// =================================================================

struct SdkSetupErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.shield.fill")
                .font(.system(size: 36))
                .foregroundStyle(DesignTokens.statusRejectedFg)
            Text("UNCLE SAM cannot start")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DesignTokens.textPrimary)
            Text("The AXIOM SDK failed to initialise.")
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.textSecondary)
            Text(message)
                .font(DesignTokens.monoSmallFont)
                .foregroundStyle(DesignTokens.textSecondary)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: 560)
                .background(DesignTokens.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Without a working SDK, UNCLE SAM cannot move AXC or generate the AXIOM-anchored half of the dual-record. Quit and reinstall, or check that the Core ELF is bundled.")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandNavy)
                .controlSize(.large)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bgPrimary)
    }
}

// =================================================================
// SdkLoadingView — pending-state spinner while sdkSetup() runs.
// =================================================================

struct SdkLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("UncleSamLogo", bundle: .main)
                .resizable()
                .scaledToFit()
                .frame(height: 90)
            ProgressView()
                .controlSize(.regular)
            Text("Loading AXIOM SDK…")
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.bgPrimary)
    }
}
