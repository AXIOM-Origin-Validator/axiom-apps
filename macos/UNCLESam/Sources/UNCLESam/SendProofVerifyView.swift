// =================================================================
// SendProofVerifyView — adjudicate an imported AXIOM Send Proof.
//
// UNCLE imports a `.cbor` Send Proof bundle and verifies it OFFLINE via the
// SDK (verifySendProofBytes — no network, no wallet): the protocol-level facts
// are decided by the network's witnesses, NOT by UNCLE.
//
// Identity is a SEPARATE, composable exhibit: UNCLE looks up the sender's
// wallet identifier in its counterparty book and surfaces the bilateral PGP
// identity it holds. UNCLE may PGP-countersign that wallet<->entity binding as
// its own record — but that attestation is NEVER entangled with the protocol
// proof. Validity = the witnesses; identity = UNCLE's exhibit. Two columns,
// never merged.
// =================================================================

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AxiomSdk

struct SendProofVerifyView: View {
    var onClose: () -> Void

    @State private var proof: Data? = nil
    @State private var fileName: String = ""
    /// AUTHORITATIVE verdict — produced by Core (CL12 inside the ELF).
    @State private var coreVerdict: CoreSendProofVerdictRow? = nil
    /// Library verdict — used only for the human-readable detail fields
    /// (sender/receiver/amount/witnesses); NOT the authority.
    @State private var verdict: SendProofVerdictRow? = nil
    @State private var error: String? = nil
    /// True while Core (CL12) is running off the main thread.
    @State private var isVerifying: Bool = false
    /// True when the imported file was already a certificate PDF.
    @State private var importedIsPdf: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Verify Send Proof").font(.title2.bold())
                Spacer()
                Button("Close", action: onClose)
            }

            Text("Import a certificate (PDF) or proof (.axproof). The verdict is produced by Core (mode CL12) running inside the canonical Core ELF — Core confirms every witness is a genesis-anchored validator. UNCLE does not decide validity.")
                .font(.callout).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Import…") { importProof() }
                    .disabled(isVerifying)
                if !fileName.isEmpty {
                    Text(fileName).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if coreVerdict?.valid == true, !isVerifying {
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
                    Text("Verifying through Core (CL12)… the first check compiles the Core ELF (up to ~2 minutes); later checks are fast.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if let e = error {
                Text(e).font(.callout).foregroundStyle(.red)
            }

            if let cv = coreVerdict, !isVerifying {
                HStack(alignment: .top, spacing: 18) {
                    protocolColumn(cv, details: verdict)
                    Divider()
                    identityColumn(verdict)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.08)))
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
    }

    // ── Column 1: the CORE-ATTESTED verdict (CL12 inside the ELF) ───────────
    /// "No-VBC network": Core rejected ONLY because the witnesses carry no VBC,
    /// while the signatures/commitment are internally consistent (library VALID).
    /// A network property (VBC issuance off), not a forgery.
    private func isNoVbcNetwork(_ cv: CoreSendProofVerdictRow, _ details: SendProofVerdictRow?) -> Bool {
        !cv.valid && (cv.reason?.contains("InvalidVBC") ?? false) && (details?.valid ?? false)
    }

    private func protocolColumn(_ cv: CoreSendProofVerdictRow, details: SendProofVerdictRow?) -> some View {
        let noVbc = isNoVbcNetwork(cv, details)
        return VStack(alignment: .leading, spacing: 6) {
            if cv.valid {
                Label("VALID — verified by Core", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.headline)
            } else if noVbc {
                Label("Signatures consistent — NOT Core-attested", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.headline)
                Text("The k witness signatures and the commitment check out, but this proof carries no validator VBCs, so Core cannot confirm the witnesses are genesis-anchored validators. This is a CLASSICAL (size-stripped) proof — the VBC chain was removed. A PQ proof (the .axproof the up-to-date wallet exports) retains the VBCs and verifies VALID. NOT a forgery indicator.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("INVALID — rejected by Core", systemImage: "xmark.seal.fill")
                    .foregroundStyle(.red).font(.headline)
                if let r = cv.reason { Text(r).font(.callout).foregroundStyle(.red) }
            }
            if (cv.valid || noVbc), let v = details {
                row("From", v.senderWalletId)
                row("To", v.receiverWalletId)
                row("Amount", "\(v.amount) atoms")
                row("Message", v.messageUtf8 ?? "(none)")
                row("Witnesses", "\(v.witnessCount) distinct validators")
            }
            row("txid", cv.txidHex)
            row("Verified by Core", cv.coreIdHex)
            Text("Core (CL12) ran inside the canonical ELF. On a VBC-enabled network it confirms every witness's VBC chains to the genesis root, REJECTING any proof signed by keys that are not genesis-anchored validators.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── Column 2: the IDENTITY exhibit (UNCLE's SEPARATE record) ────────────
    @ViewBuilder
    private func identityColumn(_ v: SendProofVerdictRow?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Identity exhibit").font(.headline)
            Text("A separate, composable attestation — NOT part of the protocol proof.")
                .font(.caption).foregroundStyle(.secondary)
            if let v, let cp = counterparty(for: v.senderWalletId) {
                row("Entity", cp.name)
                row("PGP", cp.pgpFingerprint)
                Text("UNCLE may PGP-countersign this wallet ↔ entity binding as its own exhibit; it does not change the protocol verdict.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            } else {
                Text("No counterparty on file for this sender wallet — identity is unattested. The protocol proof stands on its own regardless.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ k: String, _ val: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).font(.caption.bold()).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(val).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    /// Best-effort counterparty lookup by AXIOM address. Identity is advisory.
    private func counterparty(for walletId: String) -> Counterparty? {
        CounterpartyStore.demo.first { rec in
            !rec.axiomTierAddress.isEmpty &&
            (walletId == rec.axiomTierAddress || walletId.hasPrefix(rec.axiomTierAddress) || rec.axiomTierAddress.hasPrefix(walletId))
        }
    }

    // ── Actions ─────────────────────────────────────────────────────────────
    private func importProof() {
        error = nil
        let panel = NSOpenPanel()
        panel.title = "Import a certificate (PDF) or proof (.axproof)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // The certificate PDF (embeds the bundle), the branded .axproof bundle,
        // or a legacy .cbor — all accepted as one input.
        panel.allowedContentTypes = ["pdf", "axproof", "cbor"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let raw = try? Data(contentsOf: url) else {
            error = "Could not read the file."
            return
        }
        fileName = url.lastPathComponent
        importedIsPdf = raw.starts(with: Array("%PDF".utf8))
        proof = nil; coreVerdict = nil; verdict = nil
        isVerifying = true
        // Core (CL12 via the DMAP-VM) JIT-compiles the ELF on first run — run it
        // off the main thread so the window doesn't freeze, with a spinner.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try proofBundleFromAny(data: raw)
                let cv = try verifySendProofCoreBytes(proof: data)
                let lv = try? verifySendProofBytes(proof: data, expectedCoreId: nil, expectedSdid: nil)
                DispatchQueue.main.async {
                    self.proof = data
                    self.coreVerdict = cv
                    self.verdict = lv
                    self.isVerifying = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.proof = nil; self.coreVerdict = nil; self.verdict = nil
                    self.error = "Could not verify via Core: \(error.localizedDescription)"
                    self.isVerifying = false
                }
            }
        }
    }

    private func saveCertificate() {
        guard let proof else { return }
        let result = certificatePdfFromProof(proof: proof, expectedCoreId: nil, expectedSdid: nil)
        guard result.ok else { error = result.reason ?? "Invalid proof — no certificate."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "axiom-certificate.pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try result.pdf.write(to: url) }
        catch { self.error = "Could not save: \(error.localizedDescription)" }
    }
}
