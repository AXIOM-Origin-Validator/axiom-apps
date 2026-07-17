import SwiftUI

// =================================================================
// UNCLEOnboardingView — single-screen institutional setup.
//
// Shown when the SDK is ready but no wallet exists yet at
// `<appDir>/wallets/treasury-normal/`. Captures:
//
//   • Bank profile: name, BIC, jurisdiction (free text — would
//     be SSO/registry-sourced in a real deployment).
//   • Wallet identity: email (becomes the AXIOM wallet's
//     wallet_id email half), wallet key (per-wallet sign-time
//     passphrase).
//   • Admin tier choice: Secure+ (k=5 DMAP) or AAA+ (k=5 ZKVM).
//     Locked in at first save — operators cannot change this.
//
// Submit → InstitutionSession.completeOnboarding() →
// createWalletPair + AxiomWallet.open. Failure surfaces inline.
//
// Deliberately one screen, not a multi-step wizard: institutional
// setup is admin-driven, not consumer-onboarding-style. One
// careful pass, all required fields visible.
// =================================================================

struct UNCLEOnboardingView: View {
    @EnvironmentObject private var session: InstitutionSession

    @State private var bankName: String = ""
    @State private var bankBIC: String = ""
    @State private var jurisdiction: String = ""
    @State private var walletEmail: String = ""
    @State private var walletKey: String = ""
    @State private var walletKeyConfirm: String = ""
    @State private var tier: BankTier = .securePlus

    @State private var submitting: Bool = false
    @State private var submitError: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                cardStack
            }
            .frame(maxWidth: 720)
            .padding(EdgeInsets(top: 32, leading: 32, bottom: 48, trailing: 32))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DesignTokens.bgPrimary)
    }

    // ── Header ───────────────────────────────────────────────

    private var header: some View {
        VStack(spacing: 8) {
            Image("UncleSamLogo", bundle: .main)
                .resizable()
                .scaledToFit()
                .frame(height: 110)
            Text("Institutional setup")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignTokens.textSecondary)
                .padding(.top, -8)
            Text("One-time configuration. Admin-only. The tier choice below is locked once the wallet is created — it determines the bank's published AXIOM identity (Secure+ k=5 DMAP or AAA+ k=5 ZKVM).")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .padding(.horizontal, 24)
        }
        .padding(.bottom, 28)
    }

    // ── Cards ────────────────────────────────────────────────

    private var cardStack: some View {
        VStack(alignment: .leading, spacing: 20) {
            card(title: "Institution profile") {
                field("Bank name", placeholder: "Demo Treasury Bank",
                      text: $bankName)
                field("BIC (8 or 11 characters)",
                      placeholder: "DEMOBKHKXXX",
                      text: $bankBIC, mono: true)
                field("Jurisdiction (ISO 3166-1 alpha-2)",
                      placeholder: "HK",
                      text: $jurisdiction, mono: true)
            }
            card(title: "AXIOM wallet identity") {
                field("Wallet email",
                      placeholder: "treasury@demobank.example",
                      text: $walletEmail, mono: true)
                field("Wallet key (sign-time passphrase)",
                      placeholder: "minimum 8 characters",
                      text: $walletKey, mono: true, secure: true)
                field("Confirm wallet key", placeholder: "re-enter",
                      text: $walletKeyConfirm, mono: true, secure: true)
                Text("This key signs every outbound message. Store it in the institution's secret manager — losing it means the wallet cannot be reopened.")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            card(title: "Admin: Bank tier (locked at create time)") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(BankTier.allCases) { t in
                        tierRow(t)
                    }
                }
                Text("Both options are k=5 (five-witness quorum). The choice is between DMAP-proof (lighter compute, faster witness round) and ZKVM-proof (heaviest, strongest cryptographic defensibility). Confirm with the bank's compliance officer before continuing — this cannot be changed without creating a new wallet.")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = submitError {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.shield.fill")
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.statusRejectedBg)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            HStack {
                Spacer()
                Button {
                    submit()
                } label: {
                    HStack(spacing: 6) {
                        if submitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.shield")
                        }
                        Text(submitting
                             ? "Creating wallet…"
                             : "Create institutional wallet")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandNavy)
                .disabled(!isReady || submitting)
            }
        }
    }

    @ViewBuilder
    private func card<C: View>(title: String,
                               @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(DesignTokens.labelFont)
                .tracking(0.5)
                .foregroundStyle(DesignTokens.textTertiary)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(DesignTokens.borderSecondary, lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func field(_ label: String,
                       placeholder: String,
                       text: Binding<String>,
                       mono: Bool = false,
                       secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignTokens.textTertiary)
            if secure {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(mono ? DesignTokens.monoFont : .system(size: 13))
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(mono ? DesignTokens.monoFont : .system(size: 13))
            }
        }
    }

    @ViewBuilder
    private func tierRow(_ t: BankTier) -> some View {
        Button(action: { tier = t }) {
            HStack(spacing: 10) {
                Image(systemName: tier == t
                      ? "largecircle.fill.circle"
                      : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(tier == t
                                     ? DesignTokens.brandNavy
                                     : DesignTokens.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignTokens.textPrimary)
                    Text(t == .securePlus
                         ? "DMAP-proof k=5 — lighter compute, faster witness round."
                         : "ZKVM-proof k=5 — heaviest crypto, strongest defensibility.")
                        .font(.system(size: 10))
                        .foregroundStyle(DesignTokens.textTertiary)
                }
                Spacer()
            }
            .padding(10)
            .background(tier == t
                        ? DesignTokens.brandNavySoft
                        : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    // ── Submit ───────────────────────────────────────────────

    private var isReady: Bool {
        !bankName.isEmpty
        && bankBIC.count >= 8
        && bankBIC.count <= 11
        && jurisdiction.count == 2
        && walletEmail.contains("@")
        && walletKey.count >= 8
        && walletKey == walletKeyConfirm
    }

    private func submit() {
        submitting = true
        submitError = nil
        // Hop briefly off the runloop so the spinner can paint
        // before the (potentially blocking) createWalletPair call.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            let err = session.completeOnboarding(
                appDir: uncleAppDir(),
                bankName: bankName,
                bankBIC: bankBIC,
                jurisdiction: jurisdiction,
                walletEmail: walletEmail,
                walletKey: walletKey,
                tier: tier
            )
            submitting = false
            submitError = err
        }
    }
}
