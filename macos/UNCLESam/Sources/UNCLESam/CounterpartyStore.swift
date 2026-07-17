import Foundation

// =================================================================
// CounterpartyStore — bilateral counterparty arrangements.
//
// In real production this would be the bank's RMA + SSI + FX
// agreement registry, populated through onboarding workflows.
// For the design preview it's a static seed list used by:
//
//   • CounterpartiesView   — the address-book section
//   • WireView (composer)  — the per-payment counterparty picker
//                            that auto-fills BIC + pulls FX rate
//   • PgpEnvelopeHandler   — looks up sender PGP pubkey by
//                            fingerprint for inbound NotifyCheques
//                            verification (Bucket 2)
//
// AXIOM has no global FX exchange — each pair of banks arranges
// its own AXC ↔ fiat rate. This store is the practical
// equivalent of SWIFT's RMA (relationship management) + SSI
// (standing settlement instructions) + per-counterparty FX rate.
//
// Each counterparty also carries:
//   - pgpFingerprint + pgpPublicKey: transport-layer identity for
//     the bilateral UNCLE SAM peer envelope
//   - operatorEd25519PubkeyHex: signing key for the NotifyCheques
//     canonical bytes (Transaction-level intent, defense in depth
//     against PGP-key compromise)
// Operators provision both at the same bilateral ceremony as the
// PGP fingerprint. Two of the demo entries carry placeholder values
// to demonstrate the provisioned UI path; the rest are left empty
// to demonstrate the not-yet-provisioned path.
// =================================================================

enum CounterpartyStore {
    /// Demo counterparties — the `axiomTierAddress` field holds a
    /// placeholder; in a real deployment the operator pastes the
    /// counterparty bank's actual k=5 tier address (the same
    /// string a real `wallet.allAddresses()` call returns at the
    /// counterparty side). Demo values are address-shaped so the
    /// composer's picker can route to them once real addresses
    /// are pasted in via the "Edit arrangement" flow.
    static let demo: [Counterparty] = [
        // Cross-process smoke counterparty — repurposed to carry
        // Linux's uncle-sam-stub test keys so the bilateral peer-wire
        // smoke (commit e7acb8e0 on the Linux side) lands a verified
        // NotifyCheques. Real demo content for this row gets restored
        // once the smoke is signed off; or this row migrates to a
        // dedicated "Test counterparty" entry. For now, BANCO
        // ATLANTICO SA's PGP / ed25519 fields are the smoke-fixture
        // values from Linux's gen-ed25519-key + PGP keygen output.
        Counterparty(
            name: "BANCO ATLANTICO SA", bic: "BATLESMMXXX",
            jurisdiction: "ES",
            peerEndpoint: "unclesam.batlescommex.com:9090",
            relationshipSince: "2024-03-12",
            axiomTierAddress: "(paste BATLESMM's k=5 tier address here)",
            fxRate: 0.9132, fxCounterCurrency: "EUR",
            dailyLimit: 5_000_000,
            pgpFingerprint: "2BD944F61E27FEB8F257F0BB27C533C94A4744F7",
            pgpPublicKey: linuxSmokeArmouredKey,
            operatorEd25519PubkeyHex: "0f6e7d9712e150bb7a44827c535fece1904e197aaf6597b649276243dab2f9e4"),
        Counterparty(
            name: "EXPORT FINANCE LTD", bic: "EXPFKHKXXX",
            jurisdiction: "HK",
            peerEndpoint: "unclesam.expfinhk.com:9090",
            relationshipSince: "2024-09-04",
            axiomTierAddress: "(paste EXPFKHKXXX's k=5 tier address here)",
            fxRate: 7.8001, fxCounterCurrency: "HKD",
            dailyLimit: 25_000_000,
            pgpFingerprint: "F23B 8841 7029 CA5E 9D14 BB67 0238 1A9C E445 0192",
            pgpPublicKey: demoArmouredKey,
            operatorEd25519PubkeyHex: "f23b884170293ca5e9d14bb6702381a9ce4450192f23b884170293ca5e9d14bb"),
        Counterparty(
            name: "MERIDIAN BANK CORP", bic: "MRDNGB2LXXX",
            jurisdiction: "GB",
            peerEndpoint: "unclesam.meridiangb.com:9090",
            relationshipSince: "2025-01-22",
            axiomTierAddress: "(paste MRDNGB2L's k=5 tier address here)",
            fxRate: 0.7926, fxCounterCurrency: "GBP",
            dailyLimit: 3_000_000,
            pgpFingerprint: "5D91 02AC 3E76 88F1 4422 9D08 BB31 7740 C512 6EE3",
            pgpPublicKey: "",
            operatorEd25519PubkeyHex: ""),
        Counterparty(
            name: "DAIIWA NORTH HOLDINGS", bic: "DAIWJPJTXXX",
            jurisdiction: "JP",
            peerEndpoint: "unclesam.daiwajp.com:9090",
            relationshipSince: "2025-04-08",
            axiomTierAddress: "(paste DAIWJPJT's k=5 tier address here)",
            fxRate: 148.32, fxCounterCurrency: "JPY",
            dailyLimit: 500_000_000,
            pgpFingerprint: "8E13 4477 02C9 BB58 91FA 33D6 1170 EE82 4439 057C",
            pgpPublicKey: "",
            operatorEd25519PubkeyHex: ""),
        Counterparty(
            name: "VENTURA TRADE PARTNERS", bic: "VENTUS33XXX",
            jurisdiction: "US",
            peerEndpoint: "unclesam.ventura.us:9090",
            relationshipSince: "2025-07-14",
            axiomTierAddress: "(paste VENTUS33's k=5 tier address here)",
            fxRate: 1.0000, fxCounterCurrency: "USD",
            dailyLimit: 10_000_000,
            pgpFingerprint: "1A05 9921 DD42 EF73 6B14 88AC 5512 0937 BB10 F8E5",
            pgpPublicKey: "",
            operatorEd25519PubkeyHex: ""),
        Counterparty(
            name: "INDIGO HOLDINGS LTD", bic: "INDGAU2SXXX",
            jurisdiction: "AU",
            peerEndpoint: "unclesam.indigo-au.com:9090",
            relationshipSince: "2025-11-30",
            axiomTierAddress: "(paste INDGAU2S's k=5 tier address here)",
            fxRate: 1.5212, fxCounterCurrency: "AUD",
            dailyLimit: 4_000_000,
            pgpFingerprint: "",
            pgpPublicKey: "",
            operatorEd25519PubkeyHex: ""),
        Counterparty(
            name: "FEN HUANG TECH GROUP", bic: "FENGCNSHXXX",
            jurisdiction: "CN",
            peerEndpoint: "unclesam.fenghuang.cn:9090",
            relationshipSince: "2026-02-18",
            axiomTierAddress: "(paste FENGCNSH's k=5 tier address here)",
            fxRate: 7.1840, fxCounterCurrency: "CNY",
            dailyLimit: 30_000_000,
            pgpFingerprint: "",
            pgpPublicKey: "",
            operatorEd25519PubkeyHex: ""),
    ]

    /// Find a counterparty by BIC — used by the composer to pull
    /// FX rate automatically once the operator has picked or
    /// typed the beneficiary BIC. Checks selfEntry first so
    /// composing a wire to BIC=SELFXXXXXXX routes the wallet.send
    /// to the loopback receiver account configured in Settings →
    /// Self identity, then fires NotifyCheques to 127.0.0.1:9090
    /// via the post-send wire-up.
    @MainActor
    static func by(bic: String) -> Counterparty? {
        if let s = selfEntry, s.bic == bic { return s }
        return demo.first { $0.bic == bic }
    }

    /// All counterparties available for the composer picker —
    /// runtime selfEntry first (if registered) then static demo
    /// list. Composer surfaces this so the operator can pick
    /// "Self (this terminal)" without typing the magic BIC.
    @MainActor
    static func allForPicker() -> [Counterparty] {
        var out: [Counterparty] = []
        if let s = selfEntry { out.append(s) }
        out.append(contentsOf: demo)
        return out
    }

    /// Runtime-registered "self" counterparty — Mac receiving a
    /// NotifyCheques signed by its OWN PGP key (loopback self-send
    /// test, or any future scenario where a bank routes a payment
    /// from one of its accounts to another via the peer wire). When
    /// non-nil, byPgpFingerprint checks this entry FIRST before
    /// falling through to the static demo list, so a self-fingerprint
    /// match always resolves to the dynamic self entry rather than
    /// stale demo data.
    ///
    /// Populated by UNCLESamApp when the operator finishes loading
    /// the PGP key AND has provided the self PGP pubkey + self
    /// ed25519 pubkey hex in Settings → Self identity.
    @MainActor
    static var selfEntry: Counterparty?

    /// Find a counterparty by PGP fingerprint. Inbound NotifyCheques
    /// verification uses this — the PGP envelope peek gives a
    /// fingerprint, we look up which bilateral counterparty it
    /// belongs to, and retrieve their pgpPublicKey (for outer-layer
    /// verify) + operatorEd25519PubkeyHex (for inner-layer verify).
    ///
    /// Match is normalised (whitespace-stripped, case-folded) AND
    /// suffix-tolerant: sequoia's `peek_signer_fingerprint` can
    /// return either the full 40-char fingerprint or just the
    /// 16-char KeyID (last 16 hex of the fingerprint) depending on
    /// the signature packet shape. Linux hit the same issue at
    /// commit d13ce1b6 (KeyID-suffix cache lookup). We match by
    /// suffix so either form resolves.
    @MainActor
    static func byPgpFingerprint(_ fingerprint: String) -> Counterparty? {
        let needle = normalizeFp(fingerprint)
        if let s = selfEntry,
           fingerprintsMatch(stored: normalizeFp(s.pgpFingerprint),
                             needle: needle) {
            return s
        }
        return demo.first {
            !$0.pgpFingerprint.isEmpty &&
            fingerprintsMatch(stored: normalizeFp($0.pgpFingerprint),
                              needle: needle)
        }
    }

    private static func normalizeFp(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "")
         .replacingOccurrences(of: ":", with: "")
         .lowercased()
    }

    /// Suffix-tolerant fingerprint match. Both args already
    /// normalized. Returns true when one is a suffix of the other —
    /// covers full-fingerprint (40 hex) vs KeyID (last 16 hex)
    /// drift between peek_signer_fingerprint and the stored value.
    private static func fingerprintsMatch(stored: String,
                                           needle: String) -> Bool {
        if stored == needle { return true }
        if stored.hasSuffix(needle) { return true }
        if needle.hasSuffix(stored) { return true }
        return false
    }
}

/// Demo placeholder armoured PGP key block. Cosmetic only — the
/// inner base64 is deliberately bogus so anyone copy-pasting it
/// into a real PGP toolchain gets a clear parse error rather than
/// a real-but-fake key. Used by demo seed entries to demonstrate
/// the "armoured block visible" UI path; other entries carry an
/// empty string to demonstrate the not-yet-provisioned path. Real
/// deployments paste a real ASCII-armoured public key here at
/// counterparty-onboarding time.
private let demoArmouredKey: String = """
-----BEGIN PGP PUBLIC KEY BLOCK-----
Comment: DEMO PLACEHOLDER — replace at counterparty onboarding

mQINBGZxDZsBEADM3pYK4ezqo9YK7vMaR8GQ4NNFcSpw+TF1qLpVwG5BcKdN9LWZ
qLqM8WmcZJWqdpEvKLp9qSKLLrHwrSwR9hLNyqEcKcMpkRpvqJQK9NJsRdLNqJ5l
oJUaW8RGJ9TKKp9rL8jJqRRZqW2Cy1QJK0vqUvL5qSqLqQKlNJsRdLNqJ5loJUaW
8RGJ9TKKp9rL8jJqRRZqW2Cy1QJK0vqUvL5qSqLqQKlNJsRdLNqJ5loJUaW8RGJ
+   THIS BLOCK IS A DEMO PLACEHOLDER — NOT A REAL PGP KEY
+   REAL DEPLOYMENTS PASTE THE COUNTERPARTY'S ACTUAL ARMOURED
+   PUBLIC KEY HERE AT ONBOARDING TIME, THEN VERIFY THE
+   FINGERPRINT OUT-OF-BAND BEFORE TRUSTING THIS BLOCK.
=DEMO
-----END PGP PUBLIC KEY BLOCK-----
"""

/// Linux uncle-sam-stub's armoured PGP public key — verbatim from
/// Linux's commit e7acb8e0 cross-process smoke message. Carried in
/// BANCO ATLANTICO SA's row so Mac's verify finds the counterparty
/// when Linux's stub sends a NotifyCheques signed by the matching
/// ed25519 secret. Smoke-fixture data; gets removed when the smoke
/// is signed off and the row's demo identity is restored.
///
/// Fingerprint:    2BD944F61E27FEB8F257F0BB27C533C94A4744F7
/// User ID:        Linux UNCLE SAM Stub <linux-stub@axiom.dev>
/// ed25519 pubkey: 0f6e7d9712e150bb7a44827c535fece1904e197aaf6597b649276243dab2f9e4
private let linuxSmokeArmouredKey: String = """
-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEahu6bhYJKwYBBAHaRw8BAQdAaKAYqCooKBWxKavxCSwynm3LmSjhYlaOCSFm
PS8Jrwe0K0xpbnV4IFVOQ0xFIFNBTSBTdHViIDxsaW51eC1zdHViQGF4aW9tLmRl
dj6IkwQTFgoAOxYhBCvZRPYeJ/648lfwuyfFM8lKR0T3BQJqG7puAhsjBQsJCAcC
AiICBhUKCQgLAgQWAgMBAh4HAheAAAoJECfFM8lKR0T3MmMBAKvUfMVabIUs+WFq
befB6NnsAv8ujFpUIvz8R4VTLmL0AQDSpz0hBNVG3Vy3OT+p8aOqtH3lUDoHikgb
zTydStYuDLg4BGobum4SCisGAQQBl1UBBQEBB0BchWKoYtmThplMJ+G/pkc+Nve6
m4fAnh6YEwmc+1dmXQMBCAeIeAQYFgoAIBYhBCvZRPYeJ/648lfwuyfFM8lKR0T3
BQJqG7puAhsMAAoJECfFM8lKR0T3UooBAMQFwInhtH5zQulsEm7Kesgvr1UDHnYR
taYNC+e52b1mAQDBQ8EFHkiAEf5ugkk5D18q8VAQyddKapILuVMiy7BWDg==
=C5VY
-----END PGP PUBLIC KEY BLOCK-----
"""
