# AxiomKiddo — macOS mail-shaped gateway for AXIOM wallets

> **This is a reference example for SDK consumers, not a shipping
> product.** AxiomKiddo.app demonstrates how to build a transport
> daemon that bridges the AXIOM SDK's filesystem-of-record (outbox/,
> inbox/) to standard mail protocols. Real deployments would use
> postfix + dovecot, a real custodial gateway, or whatever production
> mail stack fits — Kiddo exists to show what *shape* such a thing
> takes when it honours the CLAUDE.md §8 SDK ↔ transport boundary.
> See `docs/AXIOM_DESIGN_MacOSReferenceApps.md`.

## What it does

Kiddo runs as a menu-bar app next to AxiomWallet.app. For each
configured account, it owns two background loops:

1. **Outbox watcher.** Watches `<walletDir>/outbox/new/` using
   `DispatchSource.makeFileSystemObjectSource`. For each new .eml
   file: parse `From:` / `To:` headers, deliver via SMTP, move to
   `outbox/sent/` on success or `outbox/failed/` on hard parse
   failure. Transient SMTP errors keep the file in `new/` for retry
   on the next filesystem event.
2. **POP3 poller.** Every `pop3PollSecs` (default 3s): open a POP3
   session against the configured server, drain all messages with
   RETR + DELE, QUIT to commit, and write each into
   `<walletDir>/maildir/inbox/new/` using the standard maildir
   tmp + rename pattern.

Kiddo **never touches the wallet's CBOR** and **never speaks AXIOM
protocol**. It only understands envelopes — From: / To: headers
plus an opaque body. The wallet is the only thing that knows what's
in the body.

```
        ┌─────────────────┐
        │ AxiomWallet.app │
        └─────────────────┘
            │           ▲
            ▼           │
       outbox/      inbox/   ← shared filesystem (the only IPC)
            │           ▲
            ▼           │
        ┌─────────────────┐
        │ AxiomKiddo.app  │   ← this app
        └─────────────────┘
            │           ▲
            ▼           │
           SMTP        POP3
            │           │
            ▼           │
        ┌─────────────────┐
        │   Mail relay    │
        │   (FATMAMA or   │
        │   real provider)│
        └─────────────────┘
```

## Quick start

Prereqs: the dev env from `scripts/axiom-env.py` (or any standards-
compliant SMTP + POP3 stack reachable on the network). AxiomWallet
already installed and pointed at the same dev env.

```bash
cd apps/macos/AxiomKiddo
./build.sh
swift run AxiomKiddo
```

The app drops into the menu bar (envelope icon). Click the icon to
see status; click **Open Settings…** to add an account:

- **Label** — friendly name (e.g. "Local dev").
- **Wallet email** — the AXIOM address the wallet uses
  (e.g. `alice@axiom`). Kiddo polls POP3 for this mailbox.
- **Wallet directory** — pick the wallet's data dir (typically
  `~/Library/Application Support/Axiom/wallets/<pair>-normal/`).
- **SMTP host/port** — the relay's outbound endpoint. Defaults
  127.0.0.1:2525 (matches FATMAMA's dev port).
- **POP3 host/port** — the inbound server. Defaults 127.0.0.1:2527
  (matches FATMAMA's POP3 listener — see step 3a of the migration
  plan in `AXIOM_DESIGN_MacOSReferenceApps.md`).
- **Poll interval** — how often to fetch via POP3. 3s is reasonable
  for dev.

Once added, the status row in the menu bar shows live counts of
sent / pulled / queued items.

## Layout

```
apps/macos/AxiomKiddo/
├── Package.swift              swift-tools-version 5.9, pure Swift
├── build.sh                   wraps `swift build`
└── Sources/AxiomKiddo/
    ├── AxiomKiddoApp.swift    @main, MenuBarExtra, Settings scene
    ├── Account.swift          KiddoAccount model + dev defaults
    ├── AccountStore.swift     JSON persistence
    ├── AccountWorker.swift    outbox watcher + POP3 poller per account
    ├── WorkerRegistry.swift   live worker collection, status fan-in
    ├── EnvelopeParser.swift   From: / To: extraction from EML headers
    ├── SmtpClient.swift       minimal RFC 5321 (+ TcpConn helper)
    ├── Pop3Client.swift       minimal RFC 1939
    └── SettingsView.swift     master/detail account editor
```

## v0 limits (deliberate)

- **No TLS.** Plain SMTP and POP3 only. Sufficient for the dev env;
  production deployments need TLS-enabled clients before this is
  safe to point at anything beyond localhost.
- **No AUTH.** POP3 password defaults to a placeholder; FATMAMA
  accepts anything. Production: USER/PASS or APOP plus credentials
  in Keychain.
- **One wallet per account.** Multi-wallet support is a follow-up.
- **No security-scoped bookmarks.** The wallet directory is just a
  path string. Required only if Kiddo gets sandboxed for App Store
  distribution — not on the v0 roadmap.
- **POP3 only inbound.** IMAP (with IDLE for push-style delivery) is
  step 4 of the migration plan.

## Build outputs

```
.build/                        Swift build artefacts (gitignored)
```

Pure `swift build`. No Rust dependency — Kiddo is intentionally a
mail-protocol-only app, no AXIOM crypto, no UMP parsing.

## What it doesn't do (by design)

- Decrypt UMP / inspect message contents.
- Read or write `wallet.cbor`.
- Talk to Nabla. (Nabla is the wallet's job per §8.)
- Decide whether a message is "valid" — Kiddo is a pipe.

If your gateway needs any of those, you're building something more
than a transport carrier — but consider whether the wallet should be
doing it instead.

## See also

- `docs/AXIOM_DESIGN_MacOSReferenceApps.md` — full architecture +
  migration plan (Kiddo is step 3b).
- `apps/macos/AxiomWallet/README.md` — the wallet counterpart.
- `scripts/fatmama.py` — the dev env's mail relay; SMTP (2525) +
  HTTP /pop (2526) + POP3 (2527).
- CLAUDE.md §8 — the boundary this app helps demonstrate.
