import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// =================================================================
// AddressQRSheet — QR-code rendering of an AXIOM address.
//
// Triggered from the Receive view's "QR" button. Renders a QR code
// using Core Image's `CIFilter.qrCodeGenerator()`, scaled up via a
// nearest-neighbour transform so the modules stay crisp on retina
// displays. The address is shown below as text with a Copy button
// in case the camera scan fails or the user prefers manual entry.
//
// Pure local — no network involvement. The error-correction level
// is set to `H` (high) so the code survives partial print smudges
// or screen reflections, since AXIOM addresses are short enough
// that the extra redundancy doesn't bloat the symbol size.
// =================================================================

struct AddressQRSheet: View {
    let address: String
    let tierName: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
                qrCodeView
                Text(address)
                    .font(DesignTokens.Typography.monoSmall)
                    .foregroundStyle(DesignTokens.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, DesignTokens.Spacing.sm)

                // Class chip — surfaces @public / @axiom.internal /
                // protocol-address explicitly so the recipient (or
                // scanner) sees the class boundary before they take
                // any action with this address.
                WalletClassChip(cls: walletClass(of: address))

                HStack(spacing: DesignTokens.Spacing.xs) {
                    Button {
                        copyAddress()
                    } label: {
                        Label("Copy address", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    ShareLink(item: address) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Text("Scan with the recipient's camera or Wallet app, or share the address through any normal channel — both forms encode identical bytes.")
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(DesignTokens.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, DesignTokens.Spacing.xxs)
                    .padding(.horizontal, DesignTokens.Spacing.md)
            }
            .padding(EdgeInsets(top: DesignTokens.Spacing.lg, leading: DesignTokens.Spacing.xl, bottom: DesignTokens.Spacing.xl, trailing: DesignTokens.Spacing.xl))
        }
        .frame(width: 380)
        .background(DesignTokens.bgPrimary)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("RECEIVE QR · \(tierName.uppercased())")
                    .font(DesignTokens.Typography.sectionLabel)
                    .tracking(0.4)
                    .foregroundStyle(DesignTokens.textTertiary)
                Text("Scan or share")
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
        .padding(EdgeInsets(top: DesignTokens.Spacing.md, leading: DesignTokens.Spacing.lg, bottom: DesignTokens.Spacing.sm, trailing: DesignTokens.Spacing.lg))
    }

    @ViewBuilder
    private var qrCodeView: some View {
        if let qrImage = generateQR(from: address) {
            Image(nsImage: qrImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 240, height: 240)
                .padding(DesignTokens.Spacing.xs)
                .background(Color.white) // QR needs a light background (app is light-mode-only)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                        .strokeBorder(DesignTokens.borderTertiary, lineWidth: DesignTokens.hairline)
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        } else {
            VStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(DesignTokens.statusScarredFg)
                Text("Couldn't generate QR for this address.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            .frame(width: 240, height: 240)
            .background(DesignTokens.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
        }
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    /// Render the address as a QR code via Core Image's
    /// `qrCodeGenerator`. Error-correction level `H` (highest), then
    /// scaled up with a nearest-neighbour transform so the modules
    /// stay crisp at display size. Returns nil if Core Image fails.
    private func generateQR(from string: String) -> NSImage? {
        guard !string.isEmpty,
              let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }

        // Scale to ~512px so the rendered NSImage is sharp at 240pt.
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 16, y: 16))

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
