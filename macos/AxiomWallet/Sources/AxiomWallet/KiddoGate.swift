import SwiftUI
import AppKit

// =================================================================
// KiddoGate — reusable pre-flight controller for wallet actions
// that depend on AxiomKiddo (send, redeem, heal, fund_genesis).
//
// The wallet writes UMP envelopes to outbox/ and blocks on
// maildir/inbox/ for cheques (per CLAUDE.md §8). If Kiddo is the
// configured relay and it isn't running, those envelopes sit forever
// and the wallet appears to hang. KiddoGate turns that silent hang
// into an explicit "Launch Kiddo?" alert.
//
// Usage:
//   @StateObject private var kiddoGate = KiddoGate()
//   ...
//   .kiddoGateAlert(kiddoGate)  // attach the alert at the view root
//   ...
//   Button("Send") {
//       kiddoGate.check(email: wallet.email()) {
//           // ready — actually start the send
//           coordinator.start(...)
//       }
//   }
//
// GenesisClaimSheet uses a richer full-panel preflight UI (since
// onboarding is the one place we expect the user to actually need to
// install Kiddo from scratch). KiddoGate is the lightweight version
// for the steady-state actions where the user has Kiddo configured
// but maybe quit it mid-session.
// =================================================================

@MainActor
final class KiddoGate: ObservableObject {

    /// Non-nil when the gate is waiting for the user to make a
    /// decision. Drives the alert visibility.
    @Published var pendingState: KiddoPreflightState? = nil

    /// True from the moment "Launch Kiddo" is tapped until the
    /// re-check fires. Greys the button so the user doesn't double-tap.
    @Published var launchInProgress: Bool = false

    /// The email the most-recent `check` was made against. Used by
    /// the launch path's re-check so callers don't have to re-supply.
    private var pendingEmail: String = ""

    /// The wallet directory that email belongs to, when the caller knew it.
    /// Needed to hand the address to Kiddo (`axiomkiddo://prepare` wants the
    /// directory too — it is named after the PAIR and cannot be derived from
    /// an address). Optional so a caller that doesn't know it still compiles,
    /// and simply falls back to opening plain Settings.
    private var pendingWalletDir: String?

    /// The closure to run once Kiddo passes the check. Cleared on
    /// success and on cancel.
    private var onProceed: (() -> Void)?

    /// Synchronous Kiddo check. On `.ready`, runs `onProceed`
    /// immediately. Otherwise stashes the state + closure so the
    /// alert can render and the launch path can finish what was
    /// started.
    func check(email: String, walletDir: String? = nil, onProceed: @escaping () -> Void) {
        pendingWalletDir = walletDir
        let state = KiddoPreflight.checkNow(walletEmail: email)
        if case .ready = state {
            onProceed()
            return
        }
        self.pendingEmail = email
        self.pendingState = state
        self.onProceed = onProceed
    }

    /// "Launch Kiddo" button handler. Fires `KiddoPreflight.launchKiddo()`
    /// then waits a beat (the OS can take ~1 s to spin up the .app +
    /// AccountStore + reconcileTimer) before re-checking. On success,
    /// runs the stashed `onProceed`; on continued failure, re-renders
    /// the alert with the latest state.
    func launchAndRecheck() {
        let email = pendingEmail
        launchInProgress = true
        _ = KiddoPreflight.launchKiddo()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            self.launchInProgress = false
            let state = KiddoPreflight.checkNow(walletEmail: email)
            if case .ready = state {
                let proceed = self.onProceed
                self.cancel()
                proceed?()
            } else {
                self.pendingState = state
            }
        }
    }

    /// "Open Kiddo Settings" handler — for the `.noAccountForEmail`
    /// state, the user needs to add an account, not relaunch the app.
    /// Hand the address over when the caller told us which wallet it is;
    /// otherwise plain Settings.
    ///
    /// This gate is the path a user actually hits — it fires from Send,
    /// Receive, Heal, HAL and Recall, i.e. every attempt to transact without
    /// a Kiddo account. It was the one handoff still making the user retype
    /// their address into another app, which is exactly what got reported
    /// (the owner, 2026-09-12: "the email address was not passed").
    func openKiddoSettings() {
        if let dir = pendingWalletDir, !pendingEmail.isEmpty {
            let label = (dir as NSString).lastPathComponent
                .replacingOccurrences(of: "-normal", with: "")
            KiddoPreflight.openKiddoForSetup(walletEmail: pendingEmail,
                                             walletDir: dir,
                                             label: label)
            cancel()
            return
        }
        KiddoPreflight.openKiddoForSettings()
        cancel()
    }

    /// Dismiss the alert without running `onProceed`.
    func cancel() {
        pendingState = nil
        onProceed = nil
        pendingEmail = ""
        launchInProgress = false
    }

    /// Title for the alert. Generic — the body carries the
    /// state-specific detail.
    var alertTitle: String { "AxiomKiddo isn't ready" }

    /// Body copy keyed off the current pendingState.
    var alertMessage: String {
        switch pendingState {
        case nil, .ready:
            return ""
        case .notInstalled:
            return "AxiomKiddo isn't installed at \(KiddoPreflight.installPath). Install it from the same DMG as this wallet — without Kiddo, cheques (incoming or outgoing) won't be relayed."
        case .notRunning:
            return "AxiomKiddo is installed but isn't running. Cheques won't be delivered or sent until it's launched. Launch it now?"
        case .noAccountForEmail(let email):
            return "AxiomKiddo is running but has no account configured for \(email). Open Kiddo Settings, add an account for this wallet, then return."
        }
    }
}

extension View {
    /// Attaches the standard KiddoGate alert. Place once at the view
    /// root that owns the gate; the gate publishes `pendingState`
    /// and the alert renders accordingly.
    func kiddoGateAlert(_ gate: KiddoGate) -> some View {
        self.alert(
            gate.alertTitle,
            isPresented: Binding(
                get: { gate.pendingState != nil },
                set: { if !$0 { gate.cancel() } }
            ),
            actions: {
                if case .notRunning = gate.pendingState {
                    Button(gate.launchInProgress ? "Launching…" : "Launch Kiddo") {
                        gate.launchAndRecheck()
                    }
                    .disabled(gate.launchInProgress)
                } else if case .noAccountForEmail = gate.pendingState {
                    Button("Open Kiddo Settings") {
                        gate.openKiddoSettings()
                    }
                }
                Button("Cancel", role: .cancel) {
                    gate.cancel()
                }
            },
            message: {
                Text(gate.alertMessage)
            }
        )
    }
}
