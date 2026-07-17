import SwiftUI
import AxiomSdk

// =================================================================
// ChangeKeySheet — routine wallet_key rotation for logged-in users.
//
// Triggered from WalletsView's "Change key" button on a pair card.
// Asks for current password (proof of authorisation) + new password
// (confirmed), calls `wallet.changeWalletKey` for both pair members
// (Normal + Ark share the same wallet_key per the option-(a) onboarding
// decision, so we rotate both atomically).
//
// Failure modes:
//   - Wrong current password → WalletKeyMismatch (no state change).
//   - New password too short → blocked on canSubmit.
//   - Mid-call failure on the Ark member after Normal succeeded → the
//     pair is in a split-key state; the user has to either retry with
//     the new password as the "current" on Normal + old on Ark, or
//     use the Recovery flow with wallet_secret backups. We surface
//     a clear error in that case.
//
// No protocol-side broadcast — this is pure local auth_hash rewrite.
// No carrier, no Timer.
// =================================================================

struct ChangeKeySheet: View {
    @EnvironmentObject private var session: AppSession
    let pair: LoadedPair
    let onSuccess: (String) -> Void

    @State private var oldKey: String = ""
    @State private var newKey: String = ""
    @State private var confirmKey: String = ""
    @State private var errorMessage: String? = nil
    @State private var isWorking: Bool = false
    @FocusState private var oldFocused: Bool

    private var canSubmit: Bool {
        !oldKey.isEmpty
            && newKey.count >= 8
            && newKey == confirmKey
            && !isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CHANGE PASSWORD")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Rotate the wallet_key for \(pair.name)")
                    .font(DesignTokens.Typography.heading)
            }

            descBox

            field(label: "CURRENT PASSWORD") {
                SecureField("Enter your current wallet key", text: $oldKey)
                    .textFieldStyle(.roundedBorder)
                    .focused($oldFocused)
                    .disabled(isWorking)
            }

            field(label: "NEW PASSWORD") {
                SecureField("8 characters minimum", text: $newKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
            }

            field(label: "CONFIRM NEW PASSWORD") {
                SecureField("Re-enter the new password", text: $confirmKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
                if !confirmKey.isEmpty && newKey != confirmKey {
                    Text("Passwords don't match.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.statusRejectedFg)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.statusRejectedFg)
            }

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Cancel") { onSuccess("") }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isWorking)
                    .frame(maxWidth: .infinity)
                Button("Change password") { performChange() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.brandPrimary)
                    .controlSize(.large)
                    .disabled(!canSubmit)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 460)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                oldFocused = true
            }
        }
    }

    private var descBox: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("Rotates the password for both wallets in the set (Normal + Ark share the same wallet_key by design). Your wallet_secret backups stay valid — they're independent.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(2)
            Text("If you've forgotten your current password, cancel and use 'Forgot app password?' from the login screen instead — that flow uses your wallet_secret backup paper.")
                .font(DesignTokens.Typography.micro)
                .foregroundStyle(DesignTokens.textTertiary)
                .lineSpacing(2)
                .padding(.top, 2)
        }
        .padding(EdgeInsets(top: DesignTokens.Spacing.xs,
                            leading: DesignTokens.Spacing.sm,
                            bottom: DesignTokens.Spacing.xs,
                            trailing: DesignTokens.Spacing.sm))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    private func field<C: View>(label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(LocalizedStringKey(label))
                .font(DesignTokens.Typography.sectionLabel)
                .tracking(0.4)
                .foregroundStyle(DesignTokens.textTertiary)
            content()
        }
    }

    private func performChange() {
        errorMessage = nil
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            // Verify old key against Normal once so we surface a single
            // friendly error instead of a Rust-side mismatch on the
            // first FFI call.
            guard pair.normal.verifyWalletKey(walletKey: oldKey) else {
                errorMessage = "Current password is incorrect."
                return
            }
            do {
                try pair.normal.changeWalletKey(oldWalletKey: oldKey, newWalletKey: newKey)
                if let ark = pair.ark {
                    do {
                        try ark.changeWalletKey(oldWalletKey: oldKey, newWalletKey: newKey)
                    } catch {
                        errorMessage = "Normal updated but Ark failed: \(error.localizedDescription). The wallet set is now split — rerun this dialog to align Ark."
                        return
                    }
                }
                onSuccess("Password changed for \(pair.name)\(pair.ark == nil ? "" : " (Normal + Ark)").")
            } catch {
                errorMessage = "Couldn't change password: \(error.localizedDescription)"
            }
        }
    }
}
