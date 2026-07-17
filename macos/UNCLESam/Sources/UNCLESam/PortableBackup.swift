import Foundation
import CryptoKit
import CommonCrypto
import Security

// PortableBackup — the cross-platform, password-encrypted wallet export format.
//
// The on-disk keystore is sealed under the Mac's Keychain device key (WalletVault,
// AXMK) — device-bound, NOT portable. To MOVE a wallet, Export decrypts that to the
// canonical AXWL and re-encrypts it here under the user's WALLET KEY into a portable
// "AXPW" file. That file is what crosses to the web wallet / another device, where it
// is decrypted with the same wallet key and re-sealed locally. So the keys never
// leave the Mac in plaintext, and the export requires the wallet key (authorization +
// encryption in one).
//
// AXPW frame (interoperable with WebCrypto on the web side):
//   "AXPW" | ver(1)=1 | kdf(1)=1 | salt(16) | nonce(12) | AES-256-GCM(ciphertext‖tag)
//   key = PBKDF2-HMAC-SHA256( "AXIOM_PORTABLE_WALLET_v1"||0x00||walletKey , salt, 600k )
enum PortableBackup {
    static let magic: [UInt8] = [0x41, 0x58, 0x50, 0x57] // "AXPW"
    static let version: UInt8 = 1
    static let kdfPBKDF2SHA256: UInt8 = 1
    static let iters: UInt32 = 600_000
    static let saltLen = 16, nonceLen = 12, keyLen = 32, headerLen = 6 // magic(4)+ver+kdf
    static let domain = "AXIOM_PORTABLE_WALLET_v1"

    enum BackupError: Error { case badFrame, decryptFailed, kdfFailed, rngFailed }

    static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        var material = Data(domain.utf8); material.append(0x00); material.append(Data(password.utf8))
        var derived = [UInt8](repeating: 0, count: keyLen)
        let status = material.withUnsafeBytes { mat in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    mat.baseAddress!.assumingMemoryBound(to: Int8.self), material.count,
                    s.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iters,
                    &derived, keyLen)
            }
        }
        guard status == kCCSuccess else { throw BackupError.kdfFailed }
        return SymmetricKey(data: Data(derived))
    }

    private static func randomData(_ n: Int) throws -> Data {
        var d = Data(count: n)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) == errSecSuccess }
        guard ok else { throw BackupError.rngFailed }
        return d
    }

    /// canonical AXWL bytes + wallet key → AXPW portable backup bytes.
    static func seal(_ axwl: Data, password: String) throws -> Data {
        let salt = try randomData(saltLen)
        let key = try deriveKey(password: password, salt: salt)
        let nonce = try AES.GCM.Nonce(data: randomData(nonceLen))
        let box = try AES.GCM.seal(axwl, using: key, nonce: nonce)
        var out = Data(magic); out.append(version); out.append(kdfPBKDF2SHA256)
        out.append(salt); out.append(Data(nonce)); out.append(box.ciphertext); out.append(box.tag)
        return out
    }

    /// AXPW portable backup bytes + wallet key → canonical AXWL bytes.
    static func open(_ frame: Data, password: String) throws -> Data {
        guard frame.count > headerLen + saltLen + nonceLen + 16,
              Array(frame.prefix(4)) == magic else { throw BackupError.badFrame }
        let b = Array(frame)
        let salt = Data(b[headerLen ..< headerLen + saltLen])
        let nonce = Data(b[headerLen + saltLen ..< headerLen + saltLen + nonceLen])
        let ctTag = Data(b[headerLen + saltLen + nonceLen ..< b.count])
        let ct = ctTag.prefix(ctTag.count - 16)
        let tag = ctTag.suffix(16)
        let key = try deriveKey(password: password, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ct, tag: tag)
            return try AES.GCM.open(box, using: key)
        } catch { throw BackupError.decryptFailed }
    }

    static func isPortableFrame(_ d: Data) -> Bool {
        d.count >= 4 && Array(d.prefix(4)) == magic
    }
}
