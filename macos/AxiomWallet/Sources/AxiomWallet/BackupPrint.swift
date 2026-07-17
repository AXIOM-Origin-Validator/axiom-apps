import SwiftUI
import AppKit
import AxiomSdk

// =================================================================
// BackupPrint — paper-friendly rendering of the wallet_secret pair.
//
// Triggered from the onboarding Step 4 ("Back up your wallet
// secrets") via the Print button. Renders a US Letter page with:
//
//   - Pair name + email (so the operator knows what this paper is)
//   - Generation timestamp
//   - Network fingerprint (so the secrets are identified with the
//     network they belong to — wrong-network paper is worthless)
//   - Address per mode (Normal + Ark)
//   - 4×8 hex-byte grid for each secret
//   - Full hex string as a fallback
//   - Warning text matching the on-screen warning
//
// Colors are forced black-on-white regardless of the app's color
// scheme — this is paper. The `NSPrintOperation` uses a hosting
// view at exact letter dimensions; the macOS print dialog handles
// scaling, margins, multi-page if needed, and printer selection.
// =================================================================

// @MainActor — ImageRenderer is main-actor isolated, and the only
// caller is the onboarding "back up your wallet secrets" Print
// button, which is already on the main actor.
@MainActor
func printBackup(state: OnboardingState) {
    let printable = BackupPrintableView(
        pairName: state.pairName.isEmpty ? "(unnamed)" : state.pairName,
        email: state.email,
        normalHex: state.normalWallet?.walletSecretHex() ?? "",
        normalAddress: (try? state.normalWallet?.address()) ?? nil,
        arkHex: state.arkWallet?.walletSecretHex() ?? "",
        arkAddress: (try? state.arkWallet?.address()) ?? nil,
        fingerprint: networkFingerprint(),
        generatedAt: Date()
    )

    let pageSize = NSSize(width: 612, height: 792) // US Letter, 72 dpi

    // Render the SwiftUI view to a bitmap via ImageRenderer rather
    // than handing a live NSHostingView straight to NSPrintOperation.
    // The hosting-view path prints a BLANK page: SwiftUI lays out and
    // draws on a display cycle, but NSPrintOperation.run() snapshots
    // the view synchronously, before that cycle ever happens — so the
    // print captures an undrawn view. ImageRenderer does a synchronous
    // layout + draw, so the snapshot is guaranteed populated.
    // scale 4 ≈ 288 dpi: crisp enough for OCR / hand-transcription of
    // the hex grid (standard document-scan resolution is 300 dpi).
    let renderer = ImageRenderer(content: printable)
    renderer.proposedSize = ProposedViewSize(pageSize)
    renderer.scale = 4.0

    guard let image = renderer.nsImage else {
        NSLog("printBackup: ImageRenderer produced no image — print aborted")
        return
    }
    // Pin the logical size to exactly one Letter page; the 4× backing
    // rep rides along, so the print stays high-resolution.
    image.size = pageSize

    let imageView = NSImageView(frame: NSRect(origin: .zero, size: pageSize))
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.imageAlignment = .alignTopLeft

    let printInfo = NSPrintInfo.shared
    printInfo.orientation = .portrait
    printInfo.topMargin = 36
    printInfo.bottomMargin = 36
    printInfo.leftMargin = 36
    printInfo.rightMargin = 36
    printInfo.horizontalPagination = .fit
    printInfo.verticalPagination = .fit

    let op = NSPrintOperation(view: imageView, printInfo: printInfo)
    op.jobTitle = "AXIOM Wallet Backup — \(state.pairName)"
    op.showsPrintPanel = true
    op.showsProgressPanel = true
    op.run()
}

// =================================================================
// The paper layout. Self-contained — does not consume DesignTokens
// (which carry brand colors) so it stays true black-on-white for
// printer-friendly output and OCR-friendly hex.
// =================================================================
struct BackupPrintableView: View {
    let pairName: String
    let email: String
    let normalHex: String
    let normalAddress: String?
    let arkHex: String
    let arkAddress: String?
    let fingerprint: String
    let generatedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            metadata
            warningBox
            secretSection(
                label: "NORMAL MODE — everyday wallet (k=3 quorum)",
                hex: normalHex,
                address: normalAddress
            )
            secretSection(
                label: "ARK MODE — offline wallet (k=0, partition-tolerant)",
                hex: arkHex,
                address: arkAddress
            )
            Spacer()
            footer
        }
        .padding(28)
        .frame(width: 612, height: 792, alignment: .topLeading)
        .background(Color.white)
        .foregroundColor(.black)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            // Official horizontal lockup. Forced .black for paper —
            // the printable view ignores the app theme so the seal
            // prints crisp regardless of the screen palette.
            AxiomHorizontalLockup(
                sealHeight: 38,
                color: .black,
                showTagline: false
            )
            Text("Wallet Secret Backup")
                .font(.system(size: 12))
                .foregroundColor(.black.opacity(0.6))
                .padding(.leading, 8)
            Spacer()
            Text(formatDate(generatedAt))
                .font(.system(size: 10))
                .foregroundColor(.black.opacity(0.6))
        }
        .padding(.bottom, 4)
        .overlay(
            Rectangle().fill(Color.black).frame(height: 0.75),
            alignment: .bottom
        )
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            metaRow("Wallet set", pairName)
            metaRow("Email", email)
            metaRow("Network fingerprint", fingerprint)
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .medium))
                .tracking(0.4)
                .foregroundColor(.black.opacity(0.55))
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.black)
        }
    }

    // MARK: - Warning

    private var warningBox: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("WARNING — anyone with these bytes can spend the wallets they identify.")
                .font(.system(size: 11, weight: .medium))
            Text("AXIOM cannot recover lost secrets. There is no support line. Treat this paper like cash. Lock it offline.")
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            Rectangle().strokeBorder(Color.black, lineWidth: 0.75)
        )
    }

    // MARK: - Secret blocks

    @ViewBuilder
    private func secretSection(label: String, hex: String, address: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(label))
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.4)
                Spacer()
                if let address {
                    Text(address)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.black.opacity(0.6))
                }
            }
            secretGrid(hex: hex)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("HEX")
                    .font(.system(size: 7, weight: .medium))
                    .tracking(0.4)
                    .foregroundColor(.black.opacity(0.55))
                Text(formatHexInGroups(hex))
                    .font(.system(size: 9, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .overlay(
            Rectangle().strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func secretGrid(hex: String) -> some View {
        let bytes: [(Int, String)] = stride(from: 0, to: hex.count, by: 2).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: min(2, hex.count - i))
            return (i / 2, String(hex[start..<end]))
        }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(bytes, id: \.0) { idx, byte in
                VStack(spacing: 0) {
                    Text(String(format: "%02d", idx + 1))
                        .font(.system(size: 7, weight: .medium))
                        .tracking(0.4)
                        .foregroundColor(.black.opacity(0.55))
                    Text(byte)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.black)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .overlay(
                    Rectangle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Rectangle().fill(Color.black).frame(height: 0.5)
            Text("AXIOM Wallet · \(AxiomVersion.app) · Backup ceremony at install time.")
                .font(.system(size: 8))
                .foregroundColor(.black.opacity(0.55))
                .padding(.top, 2)
            Text("Verify the network fingerprint at the top against the value published in the Yellow Paper, on axiom.dev, or in a signed press release before trusting these secrets.")
                .font(.system(size: 8))
                .foregroundColor(.black.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Formatting helpers

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Group the 64-char hex string as 4-char groups separated by
    /// thin spaces, mirroring the network-fingerprint formatting and
    /// making manual transcription resistant to drift.
    private func formatHexInGroups(_ hex: String) -> String {
        guard !hex.isEmpty else { return "—" }
        var out = ""
        for (i, ch) in hex.enumerated() {
            if i > 0 && i % 4 == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }
}
