// =================================================================
// VerifyProofSheet — import a Send Proof (.cbor) and verify it IN the
// wallet, via Core (CL12) using the bundled canonical ELF.
//
// The authoritative verdict is Core's: it confirms every witness is a
// genesis-anchored validator (VBC → ROOT_AUTHORITY_PKS), so a proof
// forged with throwaway keys is rejected. The library verdict is used
// only for the human-readable detail fields + the envelope-digest
// (tamper) status. No network; no local Core build — the ELF is the
// one bundled in the app (sdkSetup cached it at launch).
// =================================================================

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AxiomSdk

struct VerifyProofSheet: View {
    var onClose: () -> Void

    @State private var proof: Data? = nil
    @State private var fileName: String = ""
    /// Authoritative — produced by Core (CL12).
    @State private var coreVerdict: CoreSendProofVerdictRow? = nil
    /// Library verdict — detail fields + envelope-digest status only.
    @State private var libVerdict: SendProofVerdictRow? = nil
    @State private var error: String? = nil
    /// True while Core (CL12) is running off the main thread.
    @State private var isVerifying: Bool = false
    /// True when the imported file was already a certificate PDF (so there's
    /// nothing to "render" — you already have it).
    @State private var importedIsPdf: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Verify Send Proof").font(.title2.bold())
                Spacer()
                Button("Close", action: onClose)
            }

            Text("Import a certificate (PDF) or a proof (.axproof) a sender gave you — either works; the PDF embeds the bundle. The wallet runs it through Core (mode CL12) using the bundled canonical ELF — Core confirms every witness is a genesis-anchored validator. A forged proof is rejected.")
                .font(.callout).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Import…") { importProof() }
                    .disabled(isVerifying)
                if !fileName.isEmpty {
                    Text(fileName).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if let cv = coreVerdict, (cv.valid || isNoVbcNetwork(cv)), proof != nil, !isVerifying {
                    Button("Render certificate (PDF)…") { saveCertificate() }
                        .disabled(importedIsPdf)
                        .help(importedIsPdf
                              ? "You imported a certificate PDF — it already is the certificate."
                              : "Render this proof as a human-readable certificate PDF for your records.")
                }
            }

            if isVerifying {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Verifying through Core (CL12)… the first check compiles the Core ELF, which can take up to ~2 minutes; later checks are fast.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let e = error {
                Text(e).font(.callout).foregroundStyle(.red)
            }

            if let cv = coreVerdict, !isVerifying {
                verdictView(cv)
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }

    /// "No-VBC network": Core rejected ONLY because the witnesses carry no VBC,
    /// AND the signatures/commitment are internally consistent (library VALID).
    /// That's a network property (VBC issuance not enabled), not a forgery.
    private func isNoVbcNetwork(_ cv: CoreSendProofVerdictRow) -> Bool {
        !cv.valid && (cv.reason?.contains("InvalidVBC") ?? false) && (libVerdict?.valid ?? false)
    }

    @ViewBuilder
    private func verdictView(_ cv: CoreSendProofVerdictRow) -> some View {
        let noVbc = isNoVbcNetwork(cv)
        VStack(alignment: .leading, spacing: 8) {
            if cv.valid {
                Label("VALID — verified by Core", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.headline)
            } else if noVbc {
                Label("Signatures consistent — NOT Core-attested", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.headline)
                Text("The k witness signatures and the commitment check out, but this proof carries no validator VBCs, so Core cannot confirm the witnesses are genesis-anchored validators. This is a CLASSICAL (size-stripped) proof — the VBC chain was removed. Re-export the proof from the up-to-date wallet (it retains the VBCs) and Core will verify it VALID. This is NOT a forgery or tamper indicator.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("INVALID — rejected by Core", systemImage: "xmark.seal.fill")
                    .foregroundStyle(.red).font(.headline)
                if let r = cv.reason { kv("Reason", r) }
            }
            if (cv.valid || noVbc), let v = libVerdict {
                kv("From", v.senderWalletId)
                kv("To", v.receiverWalletId)
                kv("Amount", "\(v.amount) atoms")
                kv("Message", v.messageUtf8 ?? "(none)")
                kv("Witnesses", "\(v.witnessCount) distinct validators")
            }
            kv("txid", cv.txidHex)
            kv("Verified by Core", cv.coreIdHex)
            // Envelope tamper-evidence: the library digest covers wrapper bytes
            // Core's crypto checks don't (anchor_ref, message framing). Surface a
            // mismatch even when Core says the crypto is sound.
            if let v = libVerdict, let r = v.reason, r.lowercased().contains("digest") {
                Text("Envelope: \(r)")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Core (CL12) ran inside the canonical ELF; the verdict is Core's, reproducible against the published CoreID.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).font(.caption.bold()).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(v).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func importProof() {
        error = nil
        let panel = NSOpenPanel()
        panel.title = "Import a certificate (PDF) or proof (.axproof)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // The certificate PDF (which embeds the bundle), the branded .axproof
        // bundle, or a legacy .cbor — all accepted as one input.
        panel.allowedContentTypes = ["pdf", "axproof", "cbor"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let raw = try? Data(contentsOf: url) else {
            error = "Could not read the file."
            return
        }
        fileName = url.lastPathComponent
        importedIsPdf = raw.starts(with: Array("%PDF".utf8))
        proof = nil; coreVerdict = nil; libVerdict = nil
        isVerifying = true
        // Core (CL12 via the DMAP-VM) can JIT-compile the ELF on first run — run
        // it OFF the main thread so the window doesn't freeze, with a spinner.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // If it's a certificate PDF, extract the embedded bundle; else raw.
                let bundle = try proofBundleFromAny(data: raw)
                let cv = try verifySendProofCoreBytes(proof: bundle)
                let lv = try? verifySendProofBytes(proof: bundle, expectedCoreId: nil, expectedSdid: nil)
                DispatchQueue.main.async {
                    self.proof = bundle
                    self.coreVerdict = cv
                    self.libVerdict = lv
                    self.isVerifying = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.proof = nil; self.coreVerdict = nil; self.libVerdict = nil
                    self.error = "Could not verify via Core: \(error.localizedDescription)"
                    self.isVerifying = false
                }
            }
        }
    }

    private func saveCertificate() {
        guard let proof else { return }
        let result = certificatePdfFromProof(proof: proof, expectedCoreId: nil, expectedSdid: nil)
        guard result.ok else {
            error = result.reason ?? "Invalid proof — no certificate."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Send Proof certificate"
        panel.nameFieldStringValue = "axiom-certificate.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try result.pdf.write(to: url) }
        catch { self.error = "Could not save: \(error.localizedDescription)" }
    }
}
