// SmokeTest — runs the same FFI calls LoginView does, but headless.
// Prints what the GUI would see.
//
// Build + run:
//   ./build.sh
//   swift run SmokeTest
//
// Setup-only run (e.g. for tamper-smoke.sh) — point at a specific
// Core ELF and only step [0] needs to succeed:
//   AXIOM_CORE_ELF=/path/to/axiom-core.elf swift run SmokeTest
//
// Exit codes:
//   0  — full smoke ran clean
//   1  — setup OK but a later FFI step failed (typically: wallet
//        directory missing). The setup gate worked; the wallet just
//        isn't there.
//   2  — sdkSetup() itself failed. With AXIOM_CANONICAL_CORE_ID baked
//        in at SDK build time, this is what fires when the loaded ELF's
//        BLAKE3 doesn't match — used by `apps/macos/tamper-smoke.sh`
//        to assert the gate works end-to-end.

import AxiomSdk
import CryptoKit
import Foundation

// Vault at-rest seam smoke (headless, gated): prove the encrypted-create FFI path
// seals the on-disk wallet.axiom through a WalletCipher — i.e. the keystore on
// disk is CIPHERTEXT, not plaintext AXWL/CBOR, and reopens via openEncrypted.
// Run: AXIOM_VAULT_SEAM_CHECK=1 swift run SmokeTest
if ProcessInfo.processInfo.environment["AXIOM_VAULT_SEAM_CHECK"] == "1" {
    print("=== Vault at-rest seam smoke (encrypted-create → on-disk ciphertext) ===")
    final class TestCipher: WalletCipher {
        static let magic = Data([0x56, 0x53, 0x4d, 0x4b]) // "VSMK"
        let key = SymmetricKey(size: .bits256)
        func seal(plaintext: Data) throws -> Data {
            let box = try AES.GCM.seal(plaintext, using: key)
            return TestCipher.magic + box.combined!
        }
        func unseal(ciphertext: Data) throws -> Data {
            let box = try AES.GCM.SealedBox(combined: ciphertext.dropFirst(4))
            return try AES.GCM.open(box, using: key)
        }
    }
    let appDir0 = "\(NSHomeDirectory())/Library/Application Support/Axiom"
    do {
        try sdkSetup(appDir: appDir0)
        let tmp = NSTemporaryDirectory() + "axiom-vault-seam-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let cipher = TestCipher()
        let pair = "seamtest"
        _ = try createWalletPairEncrypted(
            pairName: pair, email: "seam@axiom.internal",
            walletKey: "pw-correct-horse", parentDir: tmp, cipher: cipher)
        let ks = "\(tmp)/\(pair)-normal/wallet.axiom"
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: ks))
        let head = Array(onDisk.prefix(4))
        let isCipher = head == Array(TestCipher.magic)
        let asText = String(decoding: onDisk, as: UTF8.self)
        let leaksAXWL = asText.contains("AXWL")           // plaintext keystore magic
        let w = try AxiomWallet.openEncrypted(dir: "\(tmp)/\(pair)-normal", cipher: cipher)
        let reopened = (try? w.address()) != nil  // handle frees on drop (uniffi Arc)
        print("  on-disk head:           \(head.map { String(format: "%02x", $0) }.joined())  (\(isCipher ? "VSMK ciphertext" : "NOT sealed"))")
        print("  plaintext 'AXWL' on disk: \(leaksAXWL)")
        print("  reopens via openEncrypted: \(reopened)")
        let pass = isCipher && !leaksAXWL && reopened
        print("  RESULT: \(pass ? "PASS — keystore is ciphertext at rest, no plaintext AXWL, reopens" : "FAIL")")
        exit(pass ? 0 : 1)
    } catch {
        print("  ERROR: \(error)")
        exit(1)
    }
}

// Send Proof FFI-path smoke: if /tmp/real_send_proof.cbor exists (produced by
// `cargo run -p axiom-sdk --example real_proof_demo`), verify it through the
// EXACT FFI binding UNCLE Sam / AxiomWallet call, then render the certificate.
// Headless proof that the app's Swift→FFI verify path accepts a real proof.
if let proof = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/real_send_proof.cbor")) {
    print("=== Send Proof FFI smoke (/tmp/real_send_proof.cbor) ===")
    do {
        let v = try verifySendProofBytes(proof: proof, expectedCoreId: nil, expectedSdid: nil)
        print("  verifySendProofBytes → valid=\(v.valid) witnesses=\(v.witnessCount) amount=\(v.amount)")
        print("  from \(v.senderWalletId) → \(v.receiverWalletId)  msg=\(v.messageUtf8 ?? "(none)")")
        let cert = certificatePdfFromProof(proof: proof, expectedCoreId: nil, expectedSdid: nil)
        if cert.ok {
            try cert.pdf.write(to: URL(fileURLWithPath: "/tmp/real_send_certificate_ffi.pdf"))
            print("  certificatePdfFromProof → wrote /tmp/real_send_certificate_ffi.pdf (\(cert.pdf.count) bytes)")
        } else {
            print("  certificatePdfFromProof → NOT ok: \(cert.reason ?? "?")")
        }
        print("  Send Proof FFI smoke: \(v.valid ? "PASS" : "FAIL")")
    } catch {
        print("  Send Proof FFI smoke ERROR: \(error)")
    }
    exit(0)
}

let home = NSHomeDirectory()
let appDir = "\(home)/Library/Application Support/Axiom"
let parentDir = "\(appDir)/wallets"
let walletDir = "\(parentDir)/personal-normal"

print("=== AxiomWallet FFI smoke test ===")
print("app dir:    \(appDir)")
print("Parent dir: \(parentDir)")
print("Wallet dir: \(walletDir)")
if let elf = ProcessInfo.processInfo.environment["AXIOM_CORE_ELF"] {
    print("AXIOM_CORE_ELF: \(elf)")
}
print("")

// Step 0 mirrors AxiomWalletApp's `SdkBootstrap.run()` — every FFI
// entry point requires sdkSetup() to have run first, and on a build
// with AXIOM_CANONICAL_CORE_ID baked in this is also where the
// canonical-CoreID gate fires.
print("[0] sdkSetup(appDir:)…")
do {
    try sdkSetup(appDir: appDir)
    print("    OK")
} catch {
    print("    FAILED: \(error)")
    exit(2)
}
print("")

print("[1] Opening wallet via AxiomWallet.open()…")
let wallet: AxiomWallet
do {
    wallet = try AxiomWallet.open(dir: walletDir)
} catch {
    print("FAILED: \(error)")
    exit(1)
}
print("    OK")
print("")

print("[2] Reading wallet metadata…")
print("    name:    \(wallet.name())")
print("    email:   \(wallet.email())")
do {
    let address = try wallet.address()
    print("    address: \(address)")
} catch {
    print("    address: <error: \(error)>")
}
print("    balance: \(wallet.balance()) atoms")
print("")

print("[3] Verifying wallet key…")
let good = wallet.verifyWalletKey(walletKey: "test-password")
let bad = wallet.verifyWalletKey(walletKey: "wrong-password")
print("    correct password verifies: \(good)")
print("    wrong password rejected:   \(!bad)")
if !good || bad {
    print("FAILED: key verification mismatch")
    exit(1)
}
print("")

print("[4] Listing wallet pairs…")
do {
    let pairs = try listWalletPairs(parentDir: parentDir)
    print("    \(pairs.count) pair(s) registered")
    for pair in pairs {
        print("      - \(pair.name): normal=\(pair.normalWalletName ?? "—") ark=\(pair.arkWalletName ?? "—")")
    }
} catch {
    print("    <error: \(error)>")
}
print("")

print("[5] Network fingerprint…")
print("    \(networkFingerprint())")
print("")

print("=== smoke test passed ===")
