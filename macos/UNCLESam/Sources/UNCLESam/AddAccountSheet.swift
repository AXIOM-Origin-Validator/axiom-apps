import SwiftUI

// =================================================================
// AddAccountSheet — stand up a new institutional account on this
// UNCLE SAM install.
//
// Each account is a distinct AxiomWallet on disk — own keypair,
// own AXC balance, own tier address. The operator picks the
// purpose (Treasury / FX Desk / Branch / Customer Pool / Settlement
// / Operating / Nostro-Vostro) so the role is explicit in audit
// trails + the composer's "Send from" picker.
//
// Form mirrors UNCLEOnboardingView's wallet-identity card but
// scoped to one account, not the whole institution. Bank profile
// (BIC, jurisdiction, tier) stays institution-level and isn't
// reproduced here.
// =================================================================

struct AddAccountSheet: View {
    @EnvironmentObject private var session: InstitutionSession
    let onDone: () -> Void

    @State private var displayName: String = ""
    @State private var purpose: AccountPurpose = .treasury
    @State private var subBIC: String = ""
    @State private var walletEmail: String = ""
    @State private var walletKey: String = ""
    @State private var walletKeyConfirm: String = ""
    @State private var color: AccountColor = .navy

    @State private var submitting: Bool = false
    @State private var submitError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            purposePicker
            field("Display name", placeholder: "e.g. HK Branch · FX Desk · Customer Pool A",
                  text: $displayName)
            field("Sub-BIC (optional — leave blank if this account uses the HQ BIC)",
                  placeholder: "e.g. DEMOBKHKBRA",
                  text: $subBIC, mono: true)
            field("Wallet email (AXIOM identity for this account)",
                  placeholder: "fx-desk@\(emailDomain)",
                  text: $walletEmail, mono: true)
            field("Wallet key (sign-time passphrase)",
                  placeholder: "8 characters minimum",
                  text: $walletKey, mono: true, secure: true)
            field("Confirm wallet key", placeholder: "re-enter",
                  text: $walletKeyConfirm, mono: true, secure: true)
            colorPicker
            Text("Each account holds its own AXC float and signs its own outbound TXs. Store the wallet key in the institution's secret manager — losing it means the account's wallet cannot be re-opened.")
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
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
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onDone)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button {
                    submit()
                } label: {
                    HStack(spacing: 6) {
                        if submitting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "plus.circle.fill") }
                        Text(submitting ? "Creating…" : "Create account")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.brandNavy)
                .disabled(!isReady || submitting)
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.rectangle.on.folder")
                .font(.system(size: 18))
                .foregroundStyle(DesignTokens.brandGold)
            VStack(alignment: .leading, spacing: 2) {
                Text("New institutional account")
                    .font(.system(size: 15, weight: .semibold))
                Text("Stand up a fresh AxiomWallet for this funded position.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            Spacer()
        }
    }

    /// Chrome-strip accent colour. When this account is active
    /// the top bar tints to the chosen colour — gives the operator
    /// a glanceable cue of which funded position they're on
    /// without having to read labels.
    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Chrome-strip accent colour")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.textTertiary)
                Spacer()
                Text(color.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            HStack(spacing: 8) {
                ForEach(AccountColor.allCases) { c in
                    Button {
                        color = c
                    } label: {
                        Circle()
                            .fill(c.color)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle()
                                    .strokeBorder(color == c
                                                  ? DesignTokens.brandGold
                                                  : DesignTokens.borderPrimary,
                                                  lineWidth: color == c ? 2.5 : 1)
                            )
                            .overlay(
                                color == c
                                ? Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                : nil
                            )
                    }
                    .buttonStyle(.plain)
                    .help(c.label)
                }
                Spacer()
            }
            // Preview the chrome strip with the chosen colour.
            // Icon is bright white — gold reads as almost black on
            // the darker tints (navy, burgundy, forest) which
            // defeats the preview's purpose.
            HStack(spacing: 10) {
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white)
                Text(displayName.isEmpty ? "Display name" : displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("preview")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .background(color.color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var purposePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Purpose")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignTokens.textTertiary)
            Picker("", selection: $purpose) {
                ForEach(AccountPurpose.allCases) { p in
                    HStack {
                        Image(systemName: p.icon)
                        Text(p.label)
                    }.tag(p)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Text(purpose.explanation)
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func field(_ label: String, placeholder: String,
                       text: Binding<String>,
                       mono: Bool = false, secure: Bool = false) -> some View {
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

    private var emailDomain: String {
        // Use the institution's existing wallet email's domain so the
        // suggested placeholder reads as a coherent bank-wide email.
        let parts = session.walletEmail.split(separator: "@")
        return parts.count == 2 ? String(parts[1]) : "bank.example"
    }

    private var isReady: Bool {
        !displayName.isEmpty
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
            let err = session.addAccount(
                appDir: uncleAppDir(),
                displayName: displayName,
                purpose: purpose,
                subBIC: subBIC,
                walletEmail: walletEmail,
                walletKey: walletKey,
                color: color
            )
            submitting = false
            if let err {
                submitError = err
            } else {
                onDone()
            }
        }
    }
}
