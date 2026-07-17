import Foundation

// =================================================================
// Account — one mail-gateway configuration.
//
// Two kinds of accounts coexist (see AccountKind):
//
//   .email     — a real mail provider (Gmail / Fastmail / Proton /
//                self-hosted) over TLS, with username + password auth.
//                The common case; what the obvious "+" button in
//                Settings creates.
//   .axiomDev  — plain-text SMTP + POP3 against axiom-env.py's
//                FATMAMA. The dev / reviewer path; hidden behind
//                Option-click on "+" plus a passcode gate so a
//                casual user never stumbles into it.
//
// Phase 1 captures and persists the .email shape but the worker
// transport still does plain-text talk — Phase 2 wires up STARTTLS
// + AUTH PLAIN. Until then .email accounts won't connect end-to-end.
// =================================================================

/// Which transport profile this account expects. Tagged in
/// accounts.json; missing on legacy entries decodes as .axiomDev
/// so pre-Phase-1 setups keep working unchanged.
enum AccountKind: String, Codable, Equatable {
    case email
    case axiomDev
}

struct KiddoAccount: Codable, Identifiable, Equatable {
    var id: UUID = UUID()

    /// Transport profile. Drives which sections the editor shows and
    /// (Phase 2) which dialect the worker speaks.
    var kind: AccountKind = .axiomDev

    /// Human label shown in the menu bar / Settings.
    var label: String

    /// Absolute path to the wallet directory. Kiddo will watch
    /// `<walletDir>/outbox/new/` and write to
    /// `<walletDir>/maildir/inbox/new/`.
    var walletDir: String

    /// The wallet's email address — used as the POP3 mailbox to poll.
    /// Kiddo doesn't read the wallet's CBOR, so the user supplies this
    /// at account-setup time. (Per design doc §3, the wallet itself
    /// already has this in `validators.list` / its own state — for the
    /// reference example we just ask the user to type it.)
    var walletEmail: String

    /// SMTP/POP3 defaults are loaded from `axiom.conf` at account-create
    /// time (`KiddoAccount.devDefault`). Empty here is intentional —
    /// `devDefault` overrides via `AxiomConfDefaults`. The field stays
    /// declared so existing on-disk `accounts.json` files keep decoding.
    var smtpHost: String = ""
    var smtpPort: Int = 2525
    var pop3Host: String = ""
    var pop3Port: Int = 2527

    /// TLS toggles. Default off because that matches `axiomDev` (plain
    /// text against the dev FATMAMA). `emailDefault` flips both on and
    /// picks provider-standard ports (587 STARTTLS / 995 POP3S).
    var smtpUseTLS: Bool = false
    var pop3UseTLS: Bool = false

    /// Auth credentials — only meaningful for `.email`. Shared across
    /// SMTP+POP3 because the dominant case (Gmail-style providers) uses
    /// the same login on both. `password` is a **transient** in-memory
    /// buffer used by the editor; it never reaches `accounts.json`
    /// (see custom `encode(to:)` below). The keychain — keyed by
    /// `id` — is the sole persistent store. `hasKeychainPassword`
    /// reflects whether the keychain currently holds an entry, so
    /// the UI can show "stored" vs "not set" without leaking the
    /// password back into memory.
    var username: String = ""
    var password: String = ""
    var hasKeychainPassword: Bool = false

    /// How often to poll POP3 in seconds. The dev env's FATMAMA
    /// snapshot-and-drain semantics mean cheques arrive in batches
    /// matching validator witness rounds; 3-5 seconds keeps the
    /// wallet's inbox warm without thrashing.
    var pop3PollSecs: Int = 3
}

extension KiddoAccount {
    enum CodingKeys: String, CodingKey {
        case id, kind, label, walletDir, walletEmail
        case smtpHost, smtpPort, pop3Host, pop3Port
        case smtpUseTLS, pop3UseTLS, username
        // `password` is decoded for one-shot Phase-1/2 → keychain
        // migration in `AccountStore`, never written back to disk by
        // `encode(to:)`. Stays in `CodingKeys` only so `decodeIfPresent`
        // has a key to look up.
        case password
        case hasKeychainPassword
        case pop3PollSecs
    }

    /// Custom decoder so existing `accounts.json` files — written
    /// before `kind` / TLS / auth fields existed — keep decoding with
    /// sensible defaults. Synthesised Codable would reject missing
    /// keys outright. Defined in an extension so the synthesised
    /// memberwise initialiser stays available on the main type.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id          = try c.decodeIfPresent(UUID.self,        forKey: .id)          ?? UUID()
        self.kind        = try c.decodeIfPresent(AccountKind.self, forKey: .kind)        ?? .axiomDev
        self.label       = try c.decode(String.self, forKey: .label)
        self.walletDir   = try c.decode(String.self, forKey: .walletDir)
        self.walletEmail = try c.decode(String.self, forKey: .walletEmail)
        self.smtpHost    = try c.decodeIfPresent(String.self, forKey: .smtpHost)    ?? ""
        self.smtpPort    = try c.decodeIfPresent(Int.self,    forKey: .smtpPort)    ?? 2525
        self.pop3Host    = try c.decodeIfPresent(String.self, forKey: .pop3Host)    ?? ""
        self.pop3Port    = try c.decodeIfPresent(Int.self,    forKey: .pop3Port)    ?? 2527
        self.smtpUseTLS  = try c.decodeIfPresent(Bool.self,   forKey: .smtpUseTLS)  ?? false
        self.pop3UseTLS  = try c.decodeIfPresent(Bool.self,   forKey: .pop3UseTLS)  ?? false
        self.username    = try c.decodeIfPresent(String.self, forKey: .username)    ?? ""
        self.password    = try c.decodeIfPresent(String.self, forKey: .password)    ?? ""
        self.hasKeychainPassword = try c.decodeIfPresent(Bool.self, forKey: .hasKeychainPassword) ?? false
        self.pop3PollSecs = try c.decodeIfPresent(Int.self,   forKey: .pop3PollSecs) ?? 3
    }

    /// Custom encoder. Synthesised `encode(to:)` would have written
    /// `password` to `accounts.json` — exactly what Phase 3 exists to
    /// avoid. Every other field encodes as usual.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(label, forKey: .label)
        try c.encode(walletDir, forKey: .walletDir)
        try c.encode(walletEmail, forKey: .walletEmail)
        try c.encode(smtpHost, forKey: .smtpHost)
        try c.encode(smtpPort, forKey: .smtpPort)
        try c.encode(pop3Host, forKey: .pop3Host)
        try c.encode(pop3Port, forKey: .pop3Port)
        try c.encode(smtpUseTLS, forKey: .smtpUseTLS)
        try c.encode(pop3UseTLS, forKey: .pop3UseTLS)
        try c.encode(username, forKey: .username)
        // `password` deliberately omitted — keychain is the only
        // persistent store for it.
        try c.encode(hasKeychainPassword, forKey: .hasKeychainPassword)
        try c.encode(pop3PollSecs, forKey: .pop3PollSecs)
    }
}

/// Minimal `validators.list` parser. Kiddo derives the FATMAMA host
/// from the first non-comment row's `address` column when `axiom.conf`
/// doesn't pin one explicitly. Per the seed-file convention in
/// `sdk/core/src/app.rs::ValidatorHint` the address column is the
/// operator-cluster's edge MTA host (one FATMAMA per cluster, all
/// validators in the cluster share it). YP §27.5.2 registers
/// `fatmama:host:port` as a carrier scheme for exactly this shape.
///
/// Kiddo deliberately doesn't link AxiomSdk (Package.swift comment),
/// so the parser is a copy of the SDK's lightweight whitespace splitter
/// rather than an FFI call.
struct ValidatorsListDefaults {
    var fatmamaHost: String?

    /// Read `~/Library/Application Support/Axiom/validators.list` and
    /// return the first non-comment row's address column. Returns an
    /// empty struct if the file is missing or no valid rows are found
    /// — the caller decides whether to fall back further.
    static func load() -> ValidatorsListDefaults {
        let path = NSHomeDirectory()
            + "/Library/Application Support/Axiom/validators.list"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ValidatorsListDefaults()
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // Whitespace-separated columns: name  address  email  [ed25519_pk]
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 {
                return ValidatorsListDefaults(fatmamaHost: String(parts[1]))
            }
        }
        return ValidatorsListDefaults()
    }
}

/// Minimal `axiom.conf` parser. Kiddo deliberately has no AxiomSdk
/// dependency (per Package.swift — "Kiddo doesn't know the AXIOM
/// protocol"), so we re-implement the SDK's tiny key=value reader
/// here rather than link the FFI. Same file format, intentionally:
/// the wallet writes axiom.conf, Kiddo reads it. One source of truth
/// for SMTP/POP3 host defaults across the two apps.
struct AxiomConfDefaults {
    var smtpHost: String?
    var smtpPort: Int?
    var pop3Host: String?
    var pop3Port: Int?

    /// Read `~/Library/Application Support/Axiom/axiom.conf`. Any value
    /// not present in the file is left `nil` — the caller decides
    /// whether to fall back to a placeholder.
    static func load() -> AxiomConfDefaults {
        let path = NSHomeDirectory()
            + "/Library/Application Support/Axiom/axiom.conf"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return AxiomConfDefaults()
        }
        var out = AxiomConfDefaults()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "smtp_host": out.smtpHost = value
            case "smtp_port": out.smtpPort = Int(value)
            case "pop3_host": out.pop3Host = value
            case "pop3_port": out.pop3Port = Int(value)
            default: break
            }
        }
        return out
    }
}

extension KiddoAccount {
    /// macOS convention: AxiomWallet creates wallets at
    /// `~/Library/Application Support/Axiom/wallets/<pair>-<mode>/`,
    /// and wallet-import does the same (copies the source .cbor into
    /// that layout). "Personal-normal" is the onboarding default pair
    /// name — pointing Kiddo there out of the box means a typical
    /// single-wallet user just clicks + → Save.
    static var defaultWalletDir: String {
        NSHomeDirectory() + "/Library/Application Support/Axiom/wallets/Personal-normal"
    }

    /// Default for the Option-click + passcode path in Settings —
    /// the FATMAMA / axiom-env.py setup. SMTP/POP3 host fallback chain:
    ///
    ///   1. axiom.conf `smtp_host` / `pop3_host` (explicit override),
    ///   2. first non-comment row's `address` column in validators.list
    ///      (the operator-cluster's FATMAMA host per YP §27.5.2),
    ///   3. leave blank — user fills in manually.
    ///
    /// Ports come from axiom.conf only; if the user wants non-default
    /// FATMAMA ports they uncomment + set them in axiom.conf. The
    /// validators.list scheme is one operator-cluster = one
    /// host:port for everyone in it, so deriving the host from any
    /// row is correct.
    ///
    /// Kiddo can't read wallet.axiom (forbidden — see Package.swift) so
    /// the user still fills in `walletEmail` manually.
    static var devDefault: KiddoAccount {
        let conf = AxiomConfDefaults.load()
        let seed = ValidatorsListDefaults.load()
        var acct = KiddoAccount(
            label: "Local dev (axiom-env.py)",
            walletDir: defaultWalletDir,
            walletEmail: ""
        )
        acct.kind = .axiomDev
        if let h = conf.smtpHost {
            acct.smtpHost = h
        } else if let h = seed.fatmamaHost {
            acct.smtpHost = h
        }
        if let p = conf.smtpPort { acct.smtpPort = p }
        if let h = conf.pop3Host {
            acct.pop3Host = h
        } else if let h = seed.fatmamaHost {
            acct.pop3Host = h
        }
        if let p = conf.pop3Port { acct.pop3Port = p }
        return acct
    }

    /// Default for the plain "+" path in Settings — a real mail
    /// provider over TLS. Ports pre-filled with the *implicit-TLS*
    /// standards (SMTPS 465 / POP3S 995) because that's what the
    /// transport actually supports today — Network.framework can't
    /// upgrade a plain connection mid-session, so STARTTLS on the
    /// SMTP-submission port 587 is deferred to a future iteration.
    /// Gmail / Fastmail / iCloud all publish 465 + 995 alongside
    /// their STARTTLS ports, so the modal case works out of the box.
    /// User types host + credentials; wallet directory points at the
    /// onboarding default so a typical solo user only fills in the
    /// mail-provider fields.
    static var emailDefault: KiddoAccount {
        var acct = KiddoAccount(
            label: "New email account",
            walletDir: defaultWalletDir,
            walletEmail: ""
        )
        acct.kind        = .email
        acct.smtpHost    = ""
        acct.smtpPort    = 465
        acct.smtpUseTLS  = true
        acct.pop3Host    = ""
        acct.pop3Port    = 995
        acct.pop3UseTLS  = true
        acct.username    = ""
        acct.password    = ""
        return acct
    }

    /// True when `email`'s domain is `@axiom.internal` — the dev
    /// (FATMAMA) class. Same string rule R1 enforces in Core
    /// (`is_dev_wallet`), re-implemented locally because Kiddo
    /// deliberately doesn't link AxiomSdk. The canonical rule lives in
    /// `docs/AXIOM_DESIGN_FactClassIsolation.md` §2. Case-insensitive
    /// on the domain; anything else (incl. no `@`) is non-dev.
    static func isDevEmail(_ email: String) -> Bool {
        guard let atIdx = email.firstIndex(of: "@") else { return false }
        return email[email.index(after: atIdx)...].lowercased() == "axiom.internal"
    }

    /// Read the wallet's email from any existing `.eml` envelope.
    /// Kiddo is allowed to look at envelopes — that's its job — and
    /// MUST NOT read `wallet.axiom` (per design doc §4). This helper
    /// keeps Kiddo on the right side of that boundary while still
    /// giving the user one fewer field to fill in.
    ///
    /// Scan order — first match wins:
    ///   1. `outbox/sent` + `outbox/new`: From: header (the wallet
    ///      wrote it, so From: is its own address)
    ///   2. `maildir/inbox/cur` + `maildir/inbox/new`: To: header
    ///      (mail was delivered to the wallet, so To: is its own
    ///      address). Covers wallets that have only received cheques.
    static func detectWalletEmail(walletDir: String) -> String? {
        let fm = FileManager.default

        // Outbox direction — `From:` is the wallet itself.
        for sub in ["outbox/sent", "outbox/new"] {
            let dir = "\(walletDir)/\(sub)"
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() {
                let path = "\(dir)/\(name)"
                guard let data = fm.contents(atPath: path),
                      let env = EnvelopeParser.parse(data),
                      !env.from.isEmpty else { continue }
                return env.from
            }
        }

        // Inbound direction — `To:` is the wallet itself. Lets a
        // receive-only wallet still auto-detect.
        for sub in ["maildir/inbox/cur", "maildir/inbox/new"] {
            let dir = "\(walletDir)/\(sub)"
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() {
                let path = "\(dir)/\(name)"
                guard let data = fm.contents(atPath: path),
                      let env = EnvelopeParser.parse(data),
                      !env.to.isEmpty else { continue }
                return env.to
            }
        }

        return nil
    }
}

// =================================================================
// WalletCandidate — one wallet directory on disk that's available
// to attach to a Kiddo account. Produced by
// `KiddoAccount.scanAvailableWallets`; consumed by the "Pick wallet…"
// menu in Settings.
// =================================================================

struct WalletCandidate: Identifiable, Hashable {
    /// The absolute walletDir doubles as a stable identity (one
    /// directory == one wallet, even if you create two accounts
    /// pointing at it).
    var id: String { walletDir }
    /// Last path component — "Personal-normal" / "Treasury-ark".
    /// What the user sees in the menu.
    var displayName: String
    var walletDir: String
    /// Auto-detected via outbox/inbox envelopes. `nil` when the
    /// wallet has never sent or received anything (then the user
    /// types it in by hand).
    var walletEmail: String?
}

extension KiddoAccount {
    /// Parent directory holding every wallet — `AxiomWallet` writes
    /// every `<pair>-<mode>` subdir here. Single source of truth
    /// shared with the wallet app.
    static var defaultWalletsParent: String {
        NSHomeDirectory() + "/Library/Application Support/Axiom/wallets"
    }

    /// Enumerate every wallet directory under `defaultWalletsParent`
    /// that (a) contains `wallet.axiom` (excludes scratch dirs, the
    /// `pairs.json` index, etc.) and (b) is not in the `excluding`
    /// set — typically the walletDirs that the user has already
    /// attached to a Kiddo account.
    static func scanAvailableWallets(excluding taken: Set<String>) -> [WalletCandidate] {
        let fm = FileManager.default
        let parent = defaultWalletsParent
        guard let entries = try? fm.contentsOfDirectory(atPath: parent) else {
            return []
        }
        var out: [WalletCandidate] = []
        for name in entries.sorted() {
            let dir = "\(parent)/\(name)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            // `wallet.axiom` is the AxiomWallet's per-wallet secret +
            // state blob. Its presence is what makes a subdir a wallet.
            guard fm.fileExists(atPath: "\(dir)/wallet.axiom") else { continue }
            if taken.contains(dir) { continue }
            let email = detectWalletEmail(walletDir: dir)
            out.append(WalletCandidate(displayName: name,
                                       walletDir: dir,
                                       walletEmail: email))
        }
        return out
    }
}
