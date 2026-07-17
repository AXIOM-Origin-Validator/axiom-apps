import Foundation
import CryptoKit
import Security
import AxiomSdk

// WalletVault — macOS app-layer at-rest encryption for the wallet keystore
// (the `wallet.axiom` blob). This is the macOS sibling of the webclient's
// vault.js, and like it the crypto lives ENTIRELY in the app: axiom-sdk is
// protocol-security-only and ships no at-rest cipher (docs/AXIOM_YellowPaper_SDK.md
// §4.2). The SDK calls this object's seal()/open() at its storage boundary
// through the GENERIC `WalletCipher` FFI seam — the same seam any native binding
// (iOS Swift, Android Kotlin) implements with its own platform keystore. Nothing
// here is in the SDK; nothing in the SDK is macOS-specific.
//
// Model (one mode, by design): the keystore is sealed with a random 256-bit DATA
// KEY held in the macOS Keychain, device-bound
// (kSecAttrAccessibleWhenUnlockedThisDeviceOnly — never synced to iCloud). The
// device login + the app's existing Touch-ID gate are the unlock; seal/open
// never prompt per-save (the key is cached in memory for the session). Losing
// the Keychain key = the on-disk keystore is unrecoverable — recovery is the
// explicit decrypted-AXWL Export, which is also how the wallet moves to other
// platforms (the data key never leaves this Mac).
//
// On-disk frame (LOCAL only — never the cross-platform artifact):
//   "AXMK" | ver(1) | AES-256-GCM combined(nonce12 | ciphertext | tag16)
// The portable artifact is always the decrypted canonical AXWL (see Export).
final class WalletVault: WalletCipher {
    private static let magic: [UInt8] = [0x41, 0x58, 0x4D, 0x4B] // "AXMK"
    private static let version: UInt8 = 1
    private static let headerLen = 5 // magic(4) + version(1)

    private let key: SymmetricKey

    /// The one app-level vault, lazily bound to the device key on first use
    /// (Swift `static let` is lazy — the Keychain is touched once per session).
    static let shared = WalletVault(key: WalletKeychain.loadOrCreateDeviceKey())

    private init(key: SymmetricKey) { self.key = key }

    // MARK: WalletCipher — invoked by the SDK at its storage boundary.

    func seal(plaintext: Data) throws -> Data {
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.seal(plaintext, using: key)
        } catch {
            throw FfiError.StorageError(message: "vault seal failed: \(error)")
        }
        guard let combined = box.combined else {
            throw FfiError.StorageError(message: "vault seal produced no combined box")
        }
        var out = Data(WalletVault.magic)
        out.append(WalletVault.version)
        out.append(combined)
        return out
    }

    func unseal(ciphertext: Data) throws -> Data {
        // Fail closed on anything that isn't our frame — e.g. a legacy plaintext
        // AXWL wallet (clean break: re-create it) — never silently pass plaintext.
        guard ciphertext.count > WalletVault.headerLen,
              Array(ciphertext.prefix(4)) == WalletVault.magic,
              ciphertext[ciphertext.startIndex + 4] == WalletVault.version
        else {
            throw FfiError.StorageError(
                message: "not an AXMK keystore (legacy/plaintext — re-create the wallet, or restore from a backup)")
        }
        let combined = ciphertext.dropFirst(WalletVault.headerLen)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            // Wrong device key / tampered blob. This IS the at-rest unlock gate.
            throw FfiError.StorageError(message: "keystore decryption failed (wrong device or tampered)")
        }
    }

    // MARK: Portable export — decrypt a sealed keystore to canonical AXWL.

    /// Decrypt an on-disk AXMK keystore blob back to the canonical, cross-platform
    /// `wallet.axiom` (AXWL) bytes — the form every platform's SDK imports. Used
    /// by the Export flow; the data key never leaves the Mac.
    func decryptToCanonical(_ sealed: Data) throws -> Data {
        try unseal(ciphertext: sealed)
    }

    /// Read a wallet's sealed on-disk keystore and write the DECRYPTED canonical
    /// `wallet.axiom` (AXWL) to `destURL`. This is the portable, cross-platform
    /// backup — it imports on web (WASM) and any other device via the standard
    /// `fromFile` path, which re-seals it under that device's own key. The Mac's
    /// device key never leaves this machine. (The raw on-disk file is AXMK
    /// ciphertext and is intentionally NOT portable; always export through here.)
    func exportCanonicalBackup(walletDir: String, to destURL: URL) throws {
        let sealedURL = URL(fileURLWithPath: walletDir).appendingPathComponent("wallet.axiom")
        let sealed = try Data(contentsOf: sealedURL)
        let canonical = try decryptToCanonical(sealed)
        try canonical.write(to: destURL, options: .atomic)
    }
}

// WalletKeychain — stores ONLY the 256-bit data key (not the wallet) in the
// macOS Keychain, device-bound and non-syncing. The wallet ciphertext lives in
// the file; the key lives here. Generic-password item, update-then-add.
enum WalletKeychain {
    private static let service = "org.axiom.AxiomWallet.vault"
    private static let account = "keystore-data-key-v1"

    /// Set true when the Keychain reports the device key EXISTS but access was
    /// DENIED or unavailable (the user clicked Deny on the "wants to use a key
    /// in your keychain" prompt, the keychain is locked, interaction wasn't
    /// allowed, …). The login UI reads this to show a "grant access" recovery
    /// message instead of a misleading "wrong password".
    ///
    /// CRITICAL: in this state we NEVER mint or store a replacement key. Doing
    /// so — the pre-2.21.1 bug — overwrote the ONLY copy of the DEK (`store`
    /// did `SecItemDelete` + `SecItemAdd`), permanently orphaning `wallet.axiom`
    /// (still encrypted under the old, now-destroyed key) and surfacing as
    /// "password is wrong". A key we can't read is NOT a key that's absent.
    private(set) static var accessBlocked = false

    /// Load the existing device key, or create one ONLY on a genuine first
    /// run (the item truly does not exist). If the item exists but the
    /// Keychain denies access, this returns an ephemeral throwaway key and
    /// sets `accessBlocked` — it does NOT overwrite the stored key. The
    /// ephemeral key simply fails to decrypt (cleanly), and the caller shows
    /// the recovery message; the real key stays intact for a later grant.
    static func loadOrCreateDeviceKey() -> SymmetricKey {
        switch loadDetailed() {
        case .found(let key):
            accessBlocked = false
            return key
        case .notFound:
            // Genuine first run — no key has ever existed here. Safe to create.
            accessBlocked = false
            let key = SymmetricKey(size: .bits256)
            _ = addNew(key)   // add-only; never deletes an existing item
            return key
        case .accessDenied:
            // The key EXISTS but macOS blocked us. Do NOT touch it. Return a
            // throwaway so the vault fails-closed (decrypt errors), and flag
            // the UI to prompt the user to re-grant access + restart.
            accessBlocked = true
            return SymmetricKey(size: .bits256)
        }
    }

    /// True iff a device key already exists on this Mac (readable OR merely
    /// access-blocked — both mean an encrypted wallet was created here).
    /// Callers use this to distinguish genuine first-run from key-loss.
    static func deviceKeyExists() -> Bool {
        switch loadDetailed() {
        case .found, .accessDenied: return true
        case .notFound: return false
        }
    }

    private enum LoadResult { case found(SymmetricKey), notFound, accessDenied }

    private static func loadDetailed() -> LoadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else { return .notFound }
            return .found(SymmetricKey(data: data))
        case errSecItemNotFound:
            // The ONLY status that means "no key here" → safe to create one.
            return .notFound
        default:
            // errSecAuthFailed (user Deny), errSecInteractionNotAllowed
            // (locked / no UI), errSecMissingEntitlement, … — the item may
            // well EXIST. Treat every non-notFound failure as "blocked", NEVER
            // as "absent", so we never overwrite a key we simply couldn't read.
            return .accessDenied
        }
    }

    /// Add a brand-new device key. ADD-ONLY: no `SecItemDelete`, so it can
    /// never destroy an existing key. If an item already exists this returns
    /// `errSecDuplicateItem` and we leave the existing one untouched (the
    /// caller only reaches here on `.notFound`, so a duplicate means a race —
    /// keep the winner).
    @discardableResult
    private static func addNew(_ key: SymmetricKey) -> Bool {
        let data = key.withUnsafeBytes { Data(Array($0)) }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

// Vaulted entry points — the ONE place the app injects WalletVault.shared into
// the SDK's encrypted constructors. Every wallet the app creates/opens/restores
// goes through these, so the keystore is always sealed at rest. (The SmokeTest
// target deliberately stays on the plaintext path — it tests the SDK, not the
// vault, and runs against its own throwaway wallets.)
extension AxiomWallet {
    static func openVaulted(dir: String) throws -> AxiomWallet {
        try AxiomWallet.openEncrypted(dir: dir, cipher: WalletVault.shared)
    }

    static func fromFileVaulted(
        sourcePath: String, parentDir: String, walletName: String
    ) throws -> AxiomWallet {
        // The backup is plaintext canonical AXWL. Copy it to a temp file whose
        // name does NOT end in `/wallet.axiom`, so the cipher treats the source
        // as a pass-through read (not an AXMK keystore to decrypt) — only the
        // TARGET `wallet.axiom` gets sealed under this device's key.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("axiom-restore-\(UUID().uuidString).axwlblob")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: tmp)
        return try AxiomWallet.fromFileEncrypted(
            sourcePath: tmp.path, parentDir: parentDir,
            walletName: walletName, cipher: WalletVault.shared)
    }
}

func createWalletPairVaulted(
    pairName: String, email: String, walletKey: String, parentDir: String
) throws -> CreatedPair {
    try createWalletPairEncrypted(
        pairName: pairName, email: email, walletKey: walletKey,
        parentDir: parentDir, cipher: WalletVault.shared)
}
