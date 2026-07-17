# AXIOM macOS apps — release log

DMG artifacts are produced by `apps/macos/release-dmg.sh` from a clean
master tree. Each row pins the DMG SHA-256 against the Core ELF
CoreID (BLAKE3) it bundles, so users can verify both the wrapper AND
the binary it runs.

The `dist/` directory itself is gitignored (binary artifacts don't go
in source); this file is the tracked record.

## Clients · Core `5f5a6797` — Ark single-keypair convergence · wallet 2.24.1 / kiddo 2.15.0 / webclient 3.3.0

CoreID **ROTATED** `ce00aacc` → `5f5a6797`. Two guest-ELF changes: genesis `state_id` is now tier-aware (`… ‖ k ‖ proof_type`) and the §11.9 Ark rules use `verify_pk_binding` (not email strings) + a new W7 (online Ark→Ark → `ArkOnlineTradeRejected`). This lands the single-keypair model — the Ark wallet is the k=0 tier address of the SAME keypair (YPX-010 §10), with Lambda wallet-state re-keyed by `(pk, k, proof_type)`. **MANDATORY** update (a different CoreID hard-locks old clients). Env deployed with `rotate --wipe` (fresh genesis — the genesis-formula change makes old state un-loadable); env smoke `genesis_claim_smoke.py` passed E2E. Worldline flipped `ce00aacc` → `5f5a6797`. Accept-set blesses prior `d0900069` (not `ce00aacc` — moot, env wiped). DMG SHA-256 `a1f2c1087785f8288b378974a3559be1adbda9193d8e6a57b0002e61393f0fcb`; tag `axiomwallet-5f5a6797-2.24.1-20260717`. Webclient republished `webclient-5f5a6797-3.3.0`. Includes the macOS address-book fix (one row per wallet — new pairs share one address).

## Clients · Core `ce00aacc` — Wallet own-wallet address book · wallet 2.24.1 / kiddo 2.15.0

CoreID **UNCHANGED** (`ce00aacc`) — macOS app only, no ELF/protocol/wire change. **OPTIONAL** update over 2.24.0. `ce00aacc` was established by the 2.24.0 rotation (CoreID lineage accept-set: it blesses prior CoreID `d0900069`, so outstanding `d0900069` cheques still redeem under it — see `docs/AXIOM_DESIGN_CoreUpgradeMigration.md` §11).

- **AxiomWallet 2.24.1 — own wallets auto-added to the address book.** This Mac's own wallet addresses are added to the contact list automatically, so sending between your own wallets no longer needs copy/paste. `contacts.json` is a local convenience file with no FFI/wire surface. Includes a contact-avatar fix (an avatar showed "P(" for "Personal (Ark)").
- **DMG**: `axiomwallet-ce00aacc-2.24.1.dmg` SHA-256 `1cfe4f7586bcc7cd69d7c36c23c84d7a7454d1e7780e5e338b96070e3bc3de56`
  Release: https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/axiomwallet-ce00aacc-2.24.1-20260717 (releases.json `products.axiomwallet` → 2.24.1)

(Release-log gap: 2.24.0 — the `d0900069 → ce00aacc` rotation that established this CoreID (folded in the CoreID-lineage accept-set + pending source; wallet 2.24.0 + webclient 3.3.0 republished) — shipped without an entry here; 2.24.1 is the first logged build on `ce00aacc`.)

## Clients · Core `42285e6b` — Kiddo dev-account clean-up + Wallet per-slot default names · wallet 2.22.4 / kiddo 2.15.0

CoreID **UNCHANGED** (`42285e6b`) — Swift app + release-script only, no ELF change. **OPTIONAL** update for anyone already on `42285e6b` (2.22.3); **MANDATORY** for anyone on an earlier CoreID (the worldline hard-lock forces the pin). `42285e6b` was established by the 2.22.3 username-scrub rotation (`--remap-path-prefix`, functionally identical Core to `e10df125`).

- **AxiomKiddo 2.15.0 — "Clean up dev accounts…" control** (Settings sidebar, red/destructive, dev-only — shown only when `@axiom.internal` accounts exist). Resyncs Kiddo ↔ FATMAMA for the dev class, which the fire-and-forget SMTP/POP3 carrier can silently desync (a dropped `XAXIOM-REGISTER` or a stale `fatmama-mailbox` leaves a wallet unable to collect witness responses). It deletes every dev route (Kiddo account + FATMAMA mailbox via `POST /routes/delete`, `with_maildir`), then recreates exactly one account per `@axiom.internal` wallet on disk (deduped by walletDir — collapses duplicate accounts) and re-registers each. DEV-ONLY: real `.email` accounts are never read or touched; FATMAMA hard-protects validator routes server-side. Confirmation is a reliable `.alert` on the always-present container (a modifier on the conditional button silently no-op'd — the "nothing happened" bug). New `FatmamaRoutes.swift` (HTTP delete client + parsed summary), `TcpConn.readUntilClose()`, `KiddoAccount.isDevEmail(_:)`.
- **AxiomWallet 2.22.4 — per-slot default wallet-set names.** The "+" → Create-new sheet no longer defaults every set to "Treasury"; it pre-fills the next unused name from an ordered list matching `MAX_PAIRS` (5): Personal → Treasury → Operations → Savings → Reserve, falling back to "Wallet N" past the list.
- **Build hygiene — identity-leak guard now enforced in `release-dmg.sh`.** `assert_no_identity` scans every file in each finished `.app` for the builder username (catches `/Users/<user>`, `/home/<user>`, `<user>@…`, bare mention) and FAILS the build if any is found; both apps verified identity-clean. Previously hand-verified only.
- **DMG**: `axiomwallet-42285e6b-2.22.4.dmg` SHA-256 `09d9a1f77a38f78592717a42662187ad78a374ddf14c43552f358edef1326aef`
  Release: (set at publish — releases.json `products.axiomwallet` → 2.22.4, kiddo → 2.15.0)

(Release-log gap: 2.22.2 (dev recall-hibernation-window 20→60, CoreID `e10df125`) and 2.22.3 (username-scrub, which established `42285e6b`) shipped from the box without entries here; 2.22.4 supersedes 2.22.3 as the first logged build on `42285e6b`.)

## Clients · Core `78a500` — RECALL redesign (Activity button) + recall witness-overlap fix · wallet 2.22.1

CoreID **UNCHANGED** (`78a500`) — Swift + SDK, **OPTIONAL** update over 2.22.0.

- **Recall is now a single stateful button on each sent transaction** (Activity → tap a send). It walks the whole lifecycle from where the proof export lives: greyed "Recall in …" countdown (estimated locally from the wallet's own send time) → enabled "Recall" → "Hibernating · …" → "Finish Recall" → terminal ("Redeemed — can't recall" / "Recalled ✓" / "window closed"). The old "Recall a payment" sheet + Settings recall buttons are removed. Honest outcomes (no false "committed"); self-correcting countdown that tightens from a TOO_EARLY response.
- **Recall witness-overlap fix (SDK, Linux `39a93205`)**: the shared heal/recall engine excluded the wallet's prior witnesses as "stale" — right for heal, wrong for recall (recall MUST overlap the completed send's own witnesses). `order_witness_validators()` is now kind-aware. Live-validated on 78a500: 4 reclaimed / 0 leak / hibernation locked (pre-fix: 0 responses).
- **DMG**: `axiomwallet-78a500aa-2.22.1.dmg` — sha256 recorded at publish. Webclient rebuilt on 78a500 (carries the same recall fix).

## Clients · Core `ec8f640b` — OODS two-value display: "Nabla size" + "Writers ~N" · wallet 2.21.3

CoreID **UNCHANGED** (`ec8f640b`) — Swift-only, **OPTIONAL** update. All protocol/lineage work this session was Nabla-side (server); the wallet talks to the network exactly as before.

- **Overview now shows two distinct OODS-derived readings** (YPX-021 §6.2), settled naming:
  - **"Nabla size N"** — the network node count (OODS-gossip, from `last_receipt_oods_flag().oods_size`).
  - **"Writers ~N"** — a rough per-node estimate of active tick-producing nodes (writers), from `wallet.lastTardisDepth()`. The `~` + tooltip ("Rough estimate of active tick-producing nodes (writers), as seen from this node. Approximate and varies per node — not an exact count.") keep it from reading as a precise network-wide total. Shows "Writers —" when 0 (n/a: pre-first-register on a run, or while a send holds the lock). Informational only — never a gate.
  - The live TARDIS topology is a closed ring (no root), so the earlier "depth" framing was dropped; the accessor keeps its historical name `lastTardisDepth()`.
- **DMG**: `axiomwallet-ec8f640b-2.21.3.dmg` — see release tag below.

## Clients · Core `ec8f640b` — resumable-send card reference + SDK §4.6 docs · wallet 2.21.2

CoreID **UNCHANGED** (`ec8f640b`) — Swift/docs only, **OPTIONAL** update.

- **Resumable-send card is now a reusable component** (`ResumableSendCard.swift`); the live Send pane renders it unchanged, and a permanent, read-only **reference render** was added to the passcode-gated Dev tools sheet ("Send-state reference") so contributors can see the affordance without reproducing a timed-out round. Reference copy is generic (no amount / signature count) with an explicit note that the live card only appears on the Send pane when a send is actually resumable.
- **Docs**: `AXIOM_YellowPaper_SDK.md` §4.6 "Resumable sends — late-response salvage" (NORMATIVE) — witnessing has no protocol expiry; a per-hop timeout persists a `pending_round`, `resume_send()` sweeps late responses + continues the same tx (idempotent redelivery), latest-wins, verdict-discard. API list updated.
- **DMG**: `axiomwallet-ec8f640b-2.21.2.dmg` — see release tag below.

## Clients · Core `ec8f640b` — 2.21.1 HOTFIX: keychain device-key never overwrites on access-denial (login lockout) · wallet 2.21.1

CoreID **UNCHANGED** (`ec8f640b`) — Swift-only hotfix over 2.21.0, **OPTIONAL** update (same-CoreID), but strongly recommended: fixes a wallet-lockout footgun.

- **Root cause of the 2.21.0 "password is wrong" lockout**: `WalletKeychain.loadOrCreateDeviceKey` treated *any* Keychain read-failure — including a user **Deny** on the "wants to use a key in your keychain" prompt — the same as "no key exists", so it minted a fresh key and `store()` did `SecItemDelete` + `SecItemAdd`, **overwriting the only copy of the at-rest device key**. `wallet.axiom` (still encrypted under the destroyed key) then decrypted to garbage and surfaced as a wrong password. Self-signed apps re-prompt on every update (new code hash, same cert), so a tester who clicked Deny bricked their wallet.
- **Fix**: only create on `errSecItemNotFound`; every other status is treated as "the key exists, we just can't read it" → never overwrite (`SecItemDelete` removed entirely; the sole write is an add-only `SecItemAdd`). On a blocked read the login shows a real recovery message ("macOS blocked the key — NOT a wrong password; reopen and click Always Allow; do NOT reset") instead of "wrong password". Deny is now fully recoverable — nothing is destroyed.
- **DMG**: `axiomwallet-ec8f640b-2.21.1.dmg` SHA-256 `d88c38ed0ff2bc5c27c8920ff49e57b18b27422c594d90a7d49a6bba8580c7ec`
  Release: https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/axiomwallet-ec8f640b-2.21.1-20260707

## Clients · Core `ec8f640b` — RECALL repurpose (retract undelivered payments) + resumable sends + wasm parity · wallet 2.21.0

CoreID **ROTATED** `688b5d3a` → `ec8f640b` (quorum gate YP §17.1.2 + YPX-022 §2.2.2 OODS exit gate + ONE-txid-domain fixes) — **MANDATORY** update via the worldline hard-lock; `seeds/worldline.json` + `releases.json` cut over together.

- **RECALL repurposed (YPX-022, 2026-07-07)**: recalls now retract a **COMPLETED-but-undelivered** payment (a failed send is a no-op under the quorum gate — nothing to reclaim). New "Recall a payment" surface (sent payments + claim status + window countdown), receiver-side "sender is retracting — redeem now" / "retracted by the sender" notices, recall-aware hibernation banner. Full parity in the webclient (`webclient-ec8f640b-3.3.0`, gh-pages + zip/html republished same cutover).
- **Resumable witness rounds**: a per-hop timeout persists the round; "Resume send" sweeps late responses (witnessing never expires) and finishes the remaining hops — same tx, same txid. Latest-wins: a new send abandons the old round. Idempotent per-hop request_id redelivery.
- **Single-flight UX**: Send/Receive nav greys during an in-flight send/redeem/claim; dev-passcode prompt is an inline step (nested sheet was silently dropped while the Settings window was open).
- **DMG**: `axiomwallet-ec8f640b-2.21.0.dmg` SHA-256 `81b331ab4d0c2d2917dbd519a15adcaaf28cf155db9de58d618f8b76e036e8a3`
  Release: https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/axiomwallet-ec8f640b-2.21.0-20260707
  (releases.json `products.axiomwallet` → 2.21.0; `web.webclient` → 3.3.0 @ ec8f640b; stable URL serves it.)

(Release-log gap: 2.19.0/2.20.0/2.20.1 shipped without entries here — see axiom-dist release tags for their records.)

## Clients · Core `5564323f` — ERASE EVERYTHING now actually wipes everything · wallet 2.17.18

CoreID **UNCHANGED** (`5564323f…`) — Swift app only (`RecoveryView.swift`), **OPTIONAL** update, no wallet re-pin.

- **Recovery → "Erase everything" now removes the whole `~/Library/Application Support/Axiom/` folder** when all three filesystem categories are selected — instead of a hardcoded allow-list (`wallets/`, the `.list` files, `axiom.conf`, `.seeds_version`, `maildir`, `cache`) that silently **left behind** anything not on it: stale artifacts from older app versions, a leftover key/DEK envelope, `logs/`, any future sidecar. A surviving state file could make a "wiped" install behave like it still held old data — which is why a true `rm -rf` of the folder behaved differently from the dialog. A whitelist wipe is always one app-version behind the files on disk; only `removeItem(base)` actually matches `rm -rf`. À-la-carte (partial) erase is unchanged — untick a category to preserve exactly that piece.

- **DMG**: `axiomwallet-5564323f-2.17.18.dmg` SHA-256 `4e67a628db3be4ff2758cc314256e0d11082b31ea27b66ad3163f7cdebe1c401`
  Release: https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/axiomwallet-5564323f-2.17.18-20260629
  (published to axiom-dist; releases.json `products.axiomwallet` → 2.17.18; stable URL serves it.)

(Version skips 2.17.17 — that tag was a §4.6 fan-out change since reverted as unnecessary; 2.17.18 supersedes it so the in-app updater re-triggers cleanly.)

## Clients · Core `5564323f` — Keychain at-rest keystore + stable signing + airdrop redeem/label fixes + Receive badge · wallet 2.17.16

CoreID **UNCHANGED** (`5564323f…`) — all macApp + app-layer FFI, **OPTIONAL** update, no
wallet re-pin. First DMG since 2.17.11; cumulative (folds in 2.17.12–2.17.16).

- **wallet.axiom encrypted at rest (Keychain device key).** The keystore is sealed with a
  random 256-bit AES-GCM key held in the macOS Keychain (`WalletVault`, device-bound,
  non-syncing). Cross-machine recovery is the encrypted AXPW portable backup. (A
  password-wrapped variant briefly shipped at 2.17.13 and was reverted; the Keychain model
  is canonical.)
- **Stable self-signed code-signing identity ("AXIØM TrustMesh Project").** Builds sign with a
  stable identity instead of ad-hoc, so the Keychain "allow access" grant pins to the cert and
  survives rebuilds — instead of re-prompting every launch (ad-hoc's per-build signature was
  re-staling the grant). Anonymous (no Apple Developer ID by design). `make-dev-signing-cert.sh`
  creates it; build scripts sign by SHA-1 hash (the non-ASCII Ø breaks codesign's by-name match).
- **Airdrop 2-step redeem fix.** "Claim — redeem later in Receive" left the genesis airdrop
  cheque pending, but redeeming it from Receive was blocked by the misfiring "claim your airdrop
  first" gate (which closed the sheet without redeeming). The gate now exempts the airdrop cheque
  itself — redeeming it IS the claim.
- **Airdrop labelled in Activity.** The redeemed genesis airdrop showed "Received from <self>";
  it now reads **"Airdrop"** (new `TxHistoryRow.is_genesis_airdrop`, same self-send +
  GENESIS_CLAIM_AMOUNT discriminator the Receive cheque label uses).
- **Receive sidebar badge.** The Receive item shows a count of COMPLETE, redeemable incoming
  cheques (k-witnessed, not partial, not rejected); `.badge(0)` renders nothing. Kept live by a
  light 4s poll + an inline bump on redeem.

- **DMG**: `axiomwallet-5564323f-2.17.16.dmg` SHA-256 `f7487fb2983307e6b281cf4fa4b0ae9a835f7221cc7147f62666186c34154640`
  Release: https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/axiomwallet-5564323f-2.17.16-20260629
  (published to axiom-dist; releases.json `products.axiomwallet` → 2.17.16; stable URL serves it.)

## Webclient · Core `5564323f` — burn_scars + per-wallet Nabla selection-mode (KI#34 WI2/WI5 wasm parity) · webclient 3.2.3 (master `564ec802`)

Webclient-only (sdk/wasm + apps/webclient); **no wallet/DMG change**, no version bump — the
browser client is CoreID-gated, version stays 3.2.3. CoreID **5564323f UNCHANGED** (ELF
byte-unchanged; `cheque_nabla_hint` is a read-only DCE-neutral accessor). Closes the two
wasm-vs-native parity gaps.

- **Explicit `burn_scars` + de-orchestrated heal.** New wasm `burnScarsFund` + a "Burn scarred
  links (destroys value)" button (user-confirmed via the masked keygate). wasm `heal_inputs`
  DROPPED its auto-burn branch — heal no longer auto-burns, matching native 2.17.7 +
  `AXIOM_DESIGN_SelfTransactions.md`. Burns one scar per run.
- **Per-wallet incoming-payment-check selector (NablaSelectionMode parity).** core
  `Wallet::cheque_nabla_hint` → wasm `chequeNablaHint`; webclient Default/Secure/Random picker
  (localStorage per wallet). Default uses the sender's hint first; Secure/Random ignore it so a
  malicious sender can't steer the check. `selectNablas` proven over 5000 randomized runs (`jsc`
  on the shipped logic): Secure never leaks the hint, Default uses it first.

- **Webclient 3.2.3** (rebuilt; CoreID-gated, version unchanged):
  `webclient-5564323f-3.2.3.html` SHA-256 `46c410bb66cf3f3259084e7e722a817b5db7b56f4f344aaf947afe592c9aff64`
  `webclient-5564323f-3.2.3.zip`  SHA-256 `0a78c69b757ad234e87f2763adc1a2381c96f6eb6bdc83328b6c43b8099cec81`
  PUBLISHED to gh-pages; releases.json `web.webclient` updated. Native equivalents env-validated
  (ki34_secure_redeem / burn-one-per-run / heal-no-auto-burn); browser-UI click-through is the
  one manual step (human-in-browser).

## Clients · Core `5564323f` — Nabla "picks" indicator + live Console-proposed dv row · wallet 2.17.11

CoreID **UNCHANGED** (`5564323f…`) — macApp only, OPTIONAL update, no wallet re-pin.
Supersedes 2.17.10 (cumulative — also carries the WI2/WI5 Incoming-payment-checks picker).

Two macApp-local additions (no SDK/FFI change — both built from data the FFI already exposes):
- **Nabla "picks" column** (Settings → Network → Nabla hints): the Nabla analogue of the
  validator picks column — per-wallet count of how many times each node has been reached by
  this wallet (incoming-payment checks + register); picks > 0 = "used previously" (highlighted).
  `NablaPickCounter` (UserDefaults per wallet) folds the `sdkNablaPickerSnapshot()` `lastOkSecs`
  deltas in at broadcast finalize, exactly where the validator counter records. Purely local.
- **Console-proposed digit_version row** now shows the live worldline-published value
  ("2 (since 2026-06-17)") instead of a stale "pending" placeholder — the Console publishes
  via worldline.json, which the app already reads (`releaseUpdate.suggestedDigitVersion`), so
  it was never actually pending. Falls back to "unavailable" only when the feed is unreachable.

- **DMG**: `axiomwallet-5564323f-2.17.11.dmg`
  SHA-256 `04b9f9b241471f261e21af565d1c141a5ddb6c820ea7489aec9153fcdabdc161`
  OPTIONAL update (CoreID 5564323f unchanged).
  Release: https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/axiomwallet-5564323f-2.17.11-20260627
  (published to axiom-dist; releases.json `products.axiomwallet` → 2.17.11; stable URL serves it.)

## Clients · Core `5564323f` — per-wallet "Incoming payment checks" picker (KI#34 WI2/WI5) · wallet 2.17.10

CoreID **UNCHANGED** (`5564323f…`) — SDK/app only, OPTIONAL update, no wallet re-pin.

KI#34 WI2/WI5: the receiver now chooses, **per wallet**, which Nabla nodes verify an incoming
payment — Settings → Network → "Incoming payment checks": **Default** (1 sender-hint + 2 random,
fast), **Secure** (1 of your own previous nodes + 2 random, sender hint IGNORED so a malicious
sender can't steer the check), **Random** (3 fully random). Safe to be a choice because a
double-spend is always caught with zero economic damage; only this receiver could briefly accept
bad money. Rust SDK + FFI authored on Linux (`NablaSelectionMode`); Swift side = the per-wallet
picker + UserDefaults-by-address persistence (not wallet.cbor) + set-before-redeem wiring
(`IncomingCheckPreference`), mirroring the carrier-preference pattern. Default = Default.
SDK behavior unit-verified: `axiom-sdk nabla::tests::consultation_set_honors_selection_mode`
(Secure excludes the sender hint) + `selection_mode_runtime_setting_roundtrips`.

- **DMG**: `axiomwallet-5564323f-2.17.10.dmg`
  SHA-256 `7886ec90668d31ed5f41f38382d73a885dc5f8e74cb564a2587fce36f0e8f21d`
  OPTIONAL update (CoreID 5564323f unchanged from 2.17.9).

## Clients · Core `5564323f` — 2.17.9 HOTFIX (update-check crash + hibernation redeem gate + dust display) · wallet 2.17.9

CoreID **UNCHANGED** (`5564323f…`) — macApp + display only, OPTIONAL update, no wallet re-pin.
Supersedes the published 2.17.8 (`7ee47571`). Cumulative — also carries the 2.17.8
de-orchestration + "1 AXC airdrop" label.

**Update-check crash (the reason for the bump).** Clicking "Check for updates" on a
published 2.17.8 failed with *"update check failed: the data couldn't be read because it
is missing."* Cause: `releases.json` now carries a `webclient` entry inside `products`
with a different shape (`html_sha256`/`zip_sha256`, **no** `dmg`/`sha256`), but the Swift
`ReleaseInfo` decoded EVERY `products` value with required `dmg`+`sha256` → `keyNotFound`
fail-decoded the whole manifest. Fix: `ReleaseInfo.dmg` + `.sha256` are now OPTIONAL (like
`url`/`notesUrl` already were) in BOTH AxiomWallet and UNCLESam; the DMG-download path
guards on them (only the pinned axiomwallet/unclesam entries are ever consumed). A
non-DMG sibling product can no longer break the update check.
  ⚠️ **Manifest-side companion fix (Linux):** already-shipped strict clients (the public
  2.17.8) will KEEP failing until `releases.json` stops putting a non-DMG entry inside
  `products`. Move `webclient` to a top-level `web` key (or give it `dmg`+`sha256`) so the
  old decoder can parse the dict again. The client fix only protects 2.17.9+.

**Hibernation redeem gate.** Receive→Redeem now greys out while hibernating (it lacked the
`!isHibernating` clause Send's `canSign` already had — Core CL5 rejects a normal redeem
with `E_WALLET_HIBERNATING`; the distress-cheque redeem goes through "Finish recovery").
`refreshHibernation()` now also fires on every tab navigation so the gate can't read stale.

**Dust display.** A real amount below 0.01 L$ (heal/HAL dust, fee residue) used to render
as the awkward "< 0.01 L$" (Activity showed "+< 0.01"). Now shows the actual figure at up
to 4 decimals — "+0.0034 L$" — falling back to "< 0.0001 L$" only for genuinely microscopic
values. Single source `axiom_denomination::format_ldollar_2dp`, so it flows to macApp
(sdk/ffi) AND webclient (sdk/wasm). Display-only; Core never references the formatter (DCE)
→ **CoreID 5564323f byte-unchanged**.

- **DMG**: `axiomwallet-5564323f-2.17.9.dmg`
  SHA-256 `6263efe85224d6c886db8904bb3916bcf2a536bf528c5fb32eb156990df84944`
  OPTIONAL update (CoreID 5564323f unchanged).
- **Webclient 3.2.3** (rebuilt for the dust fix — version unchanged; browser client is
  CoreID-gated, not version-gated):
  `webclient-5564323f-3.2.3.html` SHA-256 `0c7ddb7a82ccbfe2b8d59fe9687cc32b621e14543b66f8371ca3e5149c37b181`
  `webclient-5564323f-3.2.3.zip`  SHA-256 `563529ae266b5a007737988434be44ad34c261dc0bc8bec1ea72bdbb7a69c859`
- **Verification**: swift build clean (AxiomWallet + UNCLESam); webclient CoreID assert +
  bundle-verify passed (ELF == 5564323f). UNCLESam carries the same `ReleaseInfo` fix but
  its DMG rebuild is deferred (different CoreID `ff15b5db`; rebuild when it next ships).

## Clients · Core `5564323f` — genesis CLAIM de-orchestration (both flows: default leaves cheque PENDING in Receive; one-tap "Claim & redeem" convenience) + "1 AXC airdrop" label · wallet 2.17.8 (master `45dc832b`) — PUBLISHED

CoreID **UNCHANGED** (`5564323f…`) — SDK-only, OPTIONAL update, no wallet re-pin.

The SDK no longer auto-redeems for ANY special op. `claim_genesis_full` is now the
genesis **request leg only** — witness round + Nabla register, wait for the k validator
cheques to land PENDING — and returns `pending_cheque_id` **without redeeming** (the
wallet is NOT funded on return). `ClaimGenesisResultRow` dropped `redeemed_bundles` /
`new_balance`, added `pending_cheque_id`. The macApp demonstrates **BOTH** flows (the
compose lives in the app, never the SDK — CLAUDE.md §14 extended to HAL/HEAL/CLAIM):
the claim sheet's default **"Claim — redeem later"** runs the request leg only → the
genesis cheque sits PENDING in the **Receive** tab and the user redeems it there (true
2-step, Activity "redeem · CLAIM"); **"Claim & redeem"** is the one-tap convenience that
composes claim→redeem so the wallet funds immediately. Onboarding's first-run claim uses
the convenience compose. HAL/HEAL remain 2-step (user redeems the dust/distress cheque);
BURN is the explicit 1-step `burn_scars`. See `docs/AXIOM_DESIGN_SelfTransactions.md`.

Receive view now **labels the genesis cheque as "1 AXC airdrop"** (sub-line "Genesis
airdrop — redeem to credit your wallet") instead of a generic self-sender: a new
`ChequeBundleRow.is_genesis_airdrop` FFI flag (self-send of `GENESIS_CLAIM_AMOUNT`,
mirroring `redeem.rs` `is_airdrop_replay`; HAL/HEAL dust self-cheques don't match).

- **DMG**: `axiomwallet-5564323f-2.17.8.dmg` (PUBLISHED)
  SHA-256 `7ee475719e32d6d18baa11348ac49d75bdb0f579e41928ccd23ba5ae44ca9718`
  OPTIONAL update (CoreID 5564323f unchanged from 2.17.7).
  ⚠️ This build crashes on "Check for updates" (see 2.17.9 above) — superseded by 2.17.9.
- **Webclient**: `webclient-5564323f-3.2.3.html` SHA-256
  `efe7c4b01ca11964dc5ab283146ce50c4937caf6a9c8ad06891cc8f914ed1882`
  (`.zip` `e514d5d51f585aa25ca2cd1e9e99ed84a2a805205e0c6ad1bc1eb0984ee1a6a6`) — wasm
  rebuilt; CoreID assert + bundle-verify passed (ELF == 5564323f). Superseded by the
  dust-fixed 3.2.3 rebuild under 2.17.9.
- **Verification**: FFI + macApp swift build clean against the new `ClaimGenesisResultRow`;
  Linux env-validated the 2-step claim end-to-end (CoreID 5564323f). Live client GUI
  smoke pending env (validators were down at build time).

## Clients · Core `5564323f` — self-transaction SDK fixes (send-revert / redeem-limbo / de-orchestration + explicit burn) · wallet 2.17.7 (master `068d20af`)

CoreID **UNCHANGED** (`5564323f…`) — SDK-only, OPTIONAL update, no wallet re-pin.

Ships the self-transaction SDK fixes (all SDK; no Core/ELF change):
- **Send-side transactional commit (007/041 fix):** a wallet whose local state drifts from
  its last receipt (`E_STATE_NOT_ANCHORED`, no scar/garbage) now self-heals via
  `revert_to_last_anchored` (trustless, zero Nabla) + retry instead of bricking;
  `AnchoredSnapshot` checkpoint on every anchored commit.
- **Redeem limbo recovery:** a redeem whose §4.6 claim registered but timed out before
  finalising now re-runs and recovers on retry (was an unrecoverable "contact operators"
  dead-end).
- **De-orchestration (`docs/AXIOM_DESIGN_SelfTransactions.md`):** the SDK is an atomic-tx
  provider, not an autonomous orchestrator; self-tx = send dust + USER-triggered redeem;
  Activity rows label "redeem · HAL/HEAL".
- **heal() no longer auto-burns scarred links** (that auto-burn was the burn-treadmill
  source) — it now only REPORTS scars (`HealSummary.issues_found`). New explicit
  `burn_scars()` primitive (SDK + FFI `burnScars`); the macApp adds a deliberate,
  user-confirmed "Burn scarred links" action (Settings → Wallet recovery) — burning
  DESTROYS value, so it is user-decided.

- **DMG**: `axiomwallet-5564323f-2.17.7.dmg`
  SHA-256 `caf2cf16b5c0b09356cb8cc7b3397f5024d09d3e51354290f2dd6a7365cab87e`
  OPTIONAL update (CoreID 5564323f unchanged from 2.17.6).
- **Webclient**: `webclient-5564323f-3.2.2.html` SHA-256
  `2c2ba320001777f1835c25d24c9876e830a3c79fa07050762481879de2138b1d`
  (`.zip` `71bdf8d6bcb407b1b559eed792b1b74129281c310eda45fd972500854d4eb11d`) — wasm
  rebuilt with the same fixes; CoreID unchanged.
- **Verification**: sdk-core 214/214 unit (incl. `revert_to_last_anchored_restores_checkpoint`);
  Linux env smokes `validate_send_revert_recovery.py` + `validate_redeem_limbo_recovery.py`.
  Live client GUI verify pending env availability (validators were down at build time).

## Clients · Core `5564323f` — YPX-020 §2 stranger-redeem-hibernation carry fix · wallet 2.17.6 (master `ad3e25af`)

CoreID **UNCHANGED** (`5564323f…`) — pure SDK+Lambda fix, OPTIONAL update.

A hibernating wallet redeeming a STRANGER's incoming cheque was bricking
(E_STATE_NOT_ANCHORED, scars=0, unrecoverable): Lambda's `core_client.rs`
`validate_redeem` dropped the UMP-carried `hibernation_until` when building Core's
CL5 inputs (hardcoded `None`/`0`), so Core computed the receipt `state_hash` with
hib=0, desyncing the wallet. Fixed: Lambda carries `envelope.current_state.hibernation_until`;
SDK sends the real value + adopts Core's `state_hash`; anchor guard + `needs_resync`
recovery. The §2 acceptance test missed it (self-redeem only — where Core forces hib=0).

- **DMG**: `axiomwallet-5564323f-2.17.6.dmg`
  SHA-256 `ff4e68598f958372fdac9345118da644818e6d72a1e83ae83c4bbbb87d1c3181`
  Release tag [`axiomwallet-5564323f-2.17.6-20260624`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/axiomwallet-5564323f-2.17.6-20260624).
  OPTIONAL update (CoreID 5564323f unchanged from 2.17.5).
- **Webclient**: republished to gh-pages (wasm rebuilt with the redeem fix; CoreID unchanged);
  `webclient-5564323f-3.2.1.html` SHA-256
  `aa99e645736bcc9c4236f2eef61314ba3024c13d0d9b2b266340ef51994446b5`.
- **What's in it**: stranger-redeem-while-hibernating carry fix (Lambda + SDK + WASM machine);
  new env gate `scripts/hal_acceptance.sh` (runs BOTH self- AND stranger-redeem).
  Env-validated (`validate_stranger_redeem_hibernating.py` ALL PASS on a fresh env).

## Clients · Core `5564323f` — YPX-020 §2 (completion = redeem the distress cheque) · wallet 2.17.5 (master `270a7522`)

CoreID **ROTATED**: `8b236abc…` → `5564323f0bae46618a28d651ffae7c649f4eeb343ed5ff609814f34698d82dd5`
(YPX-020 §2: HAL completion is the redeem of the re-anchor's distress cheque — no
`HalComplete` kind. Core CL5 clears `hibernation_until` on a wallet's own self-redeem; net
−152 LoC across Core/Nabla/Lambda/ANTIE/SDK).

- **DMG**: `axiomwallet-5564323f-2.17.5.dmg`
  SHA-256 `c66b32a2a96c8d4d8ebd305c0c642868da505d2bae2881fa698d5994221319ee`
  Release tag [`axiomwallet-5564323f-2.17.5-20260623`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/axiomwallet-5564323f-2.17.5-20260623).
  **MANDATORY** update (CoreID ≠ installed 8b236abc); `releases.json` + `worldline.json` → 5564323f.
- **Webclient**: rebuilt + republished to gh-pages (ELF realigned to worldline 5564323f);
  `webclient-5564323f-3.2.0.html` SHA-256
  `702383c7cbb629c3b050eb467940df2daf24ee92bf0d98da401e2b8220ee9517`.
- **What's in it**: §2 completion (one "Finish recovery" = redeem the distress cheque);
  `TxType::HalComplete` removed (old hal_complete history rows drop silently, wallet still
  loads); hibernation-gate observability fix (greys Send/Redeem while hibernating).
  Env-validated (`validate_hal_lifecycle.py` ALL PASS; 5w chaos+HAL soak 100% real-protocol).

## Clients · Core `8b236abc` — dev HIBERNATION_WINDOW 10→50 (CoreID rotation) · wallet 2.17.4 (master `2ddaa130`)

CoreID **ROTATED**: `07c48766…` → `8b236abccc59d947b15c74e525f08d59ce1fa715e229b79d9ca84af03a77ae39`
(dev-mode `HIBERNATION_WINDOW` 10 → 50 ticks = ~250s, so the HAL convergence countdown
outlasts the witness round and is actually visible; prod 18000 ≈ 25h untouched).

- **DMG**: `axiomwallet-8b236abc-2.17.4.dmg`
  SHA-256 `60a3df47695c1ae2f55ee3aa7ddb487d1d43550ed20c5f3fd5aadd63ea583e8a`
  Release tag [`axiomwallet-8b236abc-2.17.4-20260622`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/axiomwallet-8b236abc-2.17.4-20260622).
  **MANDATORY** update (CoreID ≠ installed 07c48766); `releases.json` bumped 2.17.3 → 2.17.4.
- **Webclient**: rebuilt + republished to axiom-dist gh-pages (ELF realigned to worldline
  `8b236abc`); `webclient-8b236abc-3.2.0.html` SHA-256
  `a1afaedd8013013534418b38c3f33a2d7eabf0e4363904ad39c06d75ddfa46e9`.
- **What's in it**: visible HAL countdown (50-tick dev window) + HAL/heal sheet render-delay
  fix (no blank sheet header during the witness round). Mac-app + the dev const only — no
  SDK/protocol logic change beyond the const.

## Clients · Core `07c48766` — YPX-020 HAL + heal-burn fix · wallet 2.17.3 (master `7aecee52`)

CoreID **UNCHANGED**: `07c48766c519beb861a7fdba335157355580ae950e8748d193d2c801b9746aa7`
(committed ELF used as-is — all SDK-only changes).

- **DMG**: `axiomwallet-07c48766-2.17.3.dmg`
  SHA-256 `a1e10acd74b541c303eb4f20553767f7b5276d36e44e952383b3c37cdbb5037c`
  Release tag [`axiomwallet-07c48766-2.17.3-20260622`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/axiomwallet-07c48766-2.17.3-20260622).
  Optional update (same CoreID); in-app feed `releases.json` bumped 2.17.1 → 2.17.3.
- **What's in it** (all SDK-only, CoreID-neutral):
  - heal-burn treadmill fix (`1c2df638`): heal re-registers a state-diverged scar
    instead of burning it (DETECT divergence + re-register the fact-chain tip).
  - YPX-020 HAL Activity labels: distinct "HAL re-anchor" / "HAL complete" rows
    (`TxType::HalReanchor`/`HalComplete`, history-only) instead of "Heal".
  - The shared `HealMachine` HAL extension shipped alongside (powers the web wallet);
    Mac app behaviour unchanged beyond the Activity labels.

## Clients · Core `ff15b5db` — SDK storage renames · wallet 2.16.6 / uncle 0.3.1 (master `eb53c576`)

CoreID **UNCHANGED**: `ff15b5dba4455a7a5e508790b7d2113bc6c57f86fcf0e979458d21d081222324`
(committed ELF used as-is, not rebuilt). Two SDK storage renames (`51964564` +
`9b63f7d2`), version bump (`VERSION.toml` wallet 2.16.5→2.16.6, uncle 0.3.0→0.3.1),
and both Mac branches merged at master `eb53c576`. **No back-compat** (pre-mainnet):
- `51964564`: wallet file `wallet.cbor` → `wallet.axiom` (+ `wallet.axiom.lock`).
  Pre-change `wallet.cbor` files do NOT load — wipe dev wallets / re-onboard.
- `9b63f7d2`: validator hints cache `validator_hints.cbor` → `validator_hints.vsp`
  (a stale `.cbor` is ignored + rebuilt).

macOS apps: every `wallet.cbor` reference renamed to `wallet.axiom`
(`wallet.cbor.lock` → `wallet.axiom.lock`) across 19 Swift files; the one
user-facing `validator_hints.cbor` help string → `.vsp`. The hints cache is
SDK-managed (no functional Swift dependency). Web wallet + FFI pick up both renames
by rebuilding against the SDK.

Verified: SDK `Wallet::create` persists `wallet.axiom` + `wallet.axiom.lock`, **no
`wallet.cbor`** written; FFI (`wallet.axiom`×4, `wallet.axiom.lock`, `validator_hints.vsp`)
and WASM (`wallet.axiom`, `wallet.axiom.lock`) carry the new names, none carry the
old; a build opening a stale `wallet.cbor` dir returns `WalletNotFound` (ignores it).
`tamper-smoke.sh` canonical-CoreID gate PASSED (accepts bundled `ff15b5db`, rejects
tampered, exit 2).

Version bumped because a storage-format break that wipes wallets must NOT reuse the
version under the same CoreID — else the in-app update checker (same CoreID ⇒
optional) reads "no update" and the asset filename collides with the prior build.
Supersedes the pre-rename `clients-ff15b5db-7e22e541` publish.

**Info.plist version-sync fix (root cause of a perpetual "update available" loop):**
the bump exposed that `release-dmg.sh` only sourced the version for the DMG name +
`releases.json`, while it `cp`-d a hardcoded `Info.plist` (`CFBundleShortVersionString`
stuck at 2.16.5 / 0.3.0). The update checker reads that key, so a current build
reported the old version and prompted forever. Fixed: `release-dmg.sh` now welds
`CFBundleShortVersionString` from `VERSION.toml` (per-app) into each bundled Info.plist
at assembly time — it can no longer drift from the DMG/manifest version. Source
Info.plists also bumped (wallet 2.16.6, uncle 0.3.1). The hashes below are the
corrected rebuild (Info.plist = the right version); the first-published 2.16.6 DMGs
(`ae4e941e` / `56a9d6db`) were superseded in place on the same release tag.

| Artifact | sha256 |
|---|---|
| `axiomwallet-ff15b5db-2.16.6.dmg` (AxiomWallet + AxiomKiddo) | `61a5fc8bc7614110949d4df95b36e754cbc801302a06b67158cac56aed43a573` |
| `unclesam-ff15b5db-0.3.1.dmg` | `7e50115ad7d5309616aad1302a91a2992d68718773b69d075ea8d4bb559ad2cd` |
| `webclient-ff15b5db-3.2.0.html` (single-file) | `24a92f67aeb8df7ddaaf572cb489dd079442e54e564e40fa631d79bd84a05f2b` |
| `webclient-ff15b5db-3.2.0.zip` (hosted bundle) | `e4b863155cad40fc3a2ae3bd81e64baed6464b3ef718839505ca82b76af68c4f` |

arm64-only, dev/test — mainnet hold not lifted.

## Clients · Core `ff15b5db` — source-sync rebuild on master `7e22e541`

CoreID **UNCHANGED**: `ff15b5dba4455a7a5e508790b7d2113bc6c57f86fcf0e979458d21d081222324`.
Master `7e22e541` (`docs+test: routine Core upgrades need zero migration code (proven)`)
landed docs + a `#[cfg(test)]` guardrail test + `tests/upgrade_survival.py` +
retention-aware `scripts/axiom-env.py` clean (`6fa3f502`). **No SDK / FFI / WASM
code change and no Core ELF rebuild** — this is a pure source-sync so all shipped
artifacts trace to current master. Mac used the committed
`core/artifacts/axiom-core.elf` as-is (asserted `ff15b5db` before building).

Canonical-CoreID hard-lock verified end-to-end (`tamper-smoke.sh`): each app's
`sdkSetup()` accepts the bundled `ff15b5db` ELF and rejects a tampered ELF (exit 2).
The webclient `.html` is **byte-identical** to the prior `ff15b5db` publish
(`f52adaa3…`), confirming the WASM path is unchanged. The DMG/zip hashes differ from
the earlier `ff15b5db` build (non-deterministic link/zip timestamps) but bundle the
same `ff15b5db` ELF.

| Artifact | sha256 |
|---|---|
| `axiomwallet-ff15b5db-2.16.5.dmg` (AxiomWallet + AxiomKiddo) | `f5a596d4794c0c98d2470a920836473be9d2299f0d0dbcdbf909988d9c94cc3f` |
| `unclesam-ff15b5db-0.3.0.dmg` | `482b15a7414ef90a8fac18b2c90e11243e792adcb1a54fa7caf92039209cdb4a` |
| `webclient-ff15b5db-3.2.0.html` (single-file) | `f52adaa3be7e86195cbacbe517147c79a3ee99f832773a85fb4ab77c55967a14` |
| `webclient-ff15b5db-3.2.0.zip` (hosted bundle) | `e14c013c87a7314bc9a6a4382eb3fdf023de719d58619dc6e7ab3bb9c47417c6` |

arm64-only, dev/test — mainnet hold not lifted.

## Clients · Core `ff15b5db` (KI#33 — nabla_confirmation verify-before-store)

CoreID rotation `8e5da769` → `ff15b5dba4455a7a5e508790b7d2113bc6c57f86fcf0e979458d21d081222324`.
Master `6ff7be27` (Merge `fix-ki33-conf-bind`). **KI#33**: a `nabla_confirmation`
that didn't cryptographically bind to its FACT link could be stored and then
permanently wedge a wallet (heal→burn re-verify failed `FactInvalidSignature`
forever). Fix = verify-before-store on both confirmation-attach paths + one typed
builder (`core/logic/fact.rs::verify_nabla_confirmation`, `types.rs` serde_bytes,
`sdk/core/machines/fact_confirm.rs` + `sdk/client/nabla.rs`). All client artifacts
rebuilt + welded to the new CoreID; published as `clients-ff15b5db` (Latest), with
`releases.json` + `seeds/worldline.json` flipped to `ff15b5db`. Old `wallet.cbor`
from `8e5da769` will not load (CoreID welded into receipts) — fresh wallets only.

Mac did **not** rebuild the ELF (used the committed `core/artifacts/axiom-core.elf`,
asserted `ff15b5db` before building). Linux gate: `verify_deploy` ALL VERIFIED +
`genesis_claim_smoke` end-to-end + 5w soak on `ff15b5db`. Webclient also carries the
loaded-ELF-CoreID hard-lock fix (`mac-webclient-coreid-lock-fix`; `canonicalCoreId()`
is empty in dev WASM builds, so the Same-Core lock must compare the loaded ELF CoreID).

| Artifact | sha256 |
|---|---|
| `axiomwallet-ff15b5db-2.16.5.dmg` (AxiomWallet + AxiomKiddo) | `b13a0aa1dafe6563885b4d336442f153c69c635880501ad1e903d84d13bcbe95` |
| `unclesam-ff15b5db-0.3.0.dmg` | `5455d0749a9ea858fd0ae49bfdf2d22b4829272065837f98bf263ac2fc5f1cd5` |
| `webclient-ff15b5db-3.2.0.html` (single-file) | `f52adaa3be7e86195cbacbe517147c79a3ee99f832773a85fb4ab77c55967a14` |
| `webclient-ff15b5db-3.2.0.zip` (hosted bundle) | `19f6c46932a816789ebc626b161749bd7e111336c3ff2db6420fcffd0728786f` |

arm64-only, dev/test — mainnet hold not lifted.

## Clients · Core `8e5da769` · wallet 2.16.5 + webclient (in-app update checker + L$ digit_version UX)

Client-only rebuilds on the **same** bundled CoreID
`8e5da7699b98fd2de7563586665672ff2c6e89831005b8fcada6f14daf6c9869` (no Core
change, no re-soak). Stable URL + in-app feed (`releases.json`) updated by
`scripts/publish-mac-wallet.sh` on publish.
Release: served via the constant `AxiomWallet.dmg` asset + a dated
`axiomwallet-8e5da769-2.16.5-<date>` tag.

Wallet 2.15.3 → **2.16.5**, landed across 2.16.0–2.16.5:

- **In-app update checker** (`ReleaseUpdate.swift` / `ReleaseUpdateWatcher.swift`)
  — reads `releases.json`; **same CoreID ⇒ optional** "update when convenient"
  banner, **different CoreID ⇒ mandatory** hard-lock that disables
  Send/Redeem/Claim with a divergence warning (Same-Core invariant; YP §23.10 /
  §16.8.3). Best-effort: an unreachable feed never blocks the app.
- **`worldline.json`** — the network's current worldline Core + the Console's
  *suggested* L$ `digit_version` (+ start date). Read best-effort on launch; a
  missing feed surfaces only as a quiet About line, never a popup or blocker.
- **L$ `digit_version` UX** — 2-decimal L$ display (money-style), AXC shown
  alongside L$ on the active-wallet card, and a dv-change warning on **two**
  channels: a pre-send verify gate (1/3 → 3/3, non-ignorable, shows this send's
  amount in old/new L$ + invariant AXC) and a post-login launch popup (3 app
  starts, worked against 1 AXC). Shared `DvChangeCard` renders both, with an
  "in effect since `<date>`" line from `digit_version_started`. The launch popup
  is attached post-login so it never overlaps the bio-auth prompt.
- **Validator-hint fixes** — incoming hints merge by id/hash (carrier/IPs/name
  all update), and the per-validator pick count grows on broadcast-finalize.
- **"Wallet set"** rename (was "pair") across the app.
- **SDK doc** — new `AXIOM_YellowPaper_SDK.md` §6.1 (NORMATIVE): release /
  version / worldline checking is the front-end's job — the SDK can't open a
  non-Nabla connection (§2 boundary, grep-enforced) and a feed is distribution
  policy, not protocol. Lists the primitives the SDK does provide
  (`sdk_canonical_core_id`, `format_ldollar*`).
- **Webclient parity** (`sdk/wasm` + `apps/webclient`, version 3.2.0,
  content-refresh under the same name) — new `formatLdollarShort` WASM export;
  best-effort `worldline.json` read → 2-decimal L$ beside AXC (balance/history/
  cheques) + dv-change warning on a pre-send gate (1/3→3/3) and a post-unlock
  on-load notice (shared `dvCardHTML`, "in effect since `<date>`"); **CoreID
  Same-Core hard-lock** disabling Send/Redeem/Claim/Heal on a worldline-CoreID
  mismatch. Neither web build auto-updates — the lock's CTA is "download the
  latest from GitHub" (hosted ⇒ the operator redeploys; offline `.html` ⇒ the
  holder downloads). `pack.py` kept in sync. Applies to BOTH the single-file
  `.html` and the hosted `.zip` bundle.

| Artifact | sha256 |
|---|---|
| `axiomwallet-8e5da769-2.16.5.dmg` (AxiomWallet + AxiomKiddo) | `e8847e1187aed474f76423c901c66d9c5ebc45878da933f1cdcee88ce22d7598` |
| `webclient-8e5da769-3.2.0.html` (single-file, refreshed) | `8a190c769bd69cf5095744df50c7c0cda42a4d21608bf52f5ab4f5b1634b3ee0` |
| `webclient-8e5da769-3.2.0.zip` (hosted bundle, refreshed) | `43792e4fb44b4ee7217dcef4d025ad7477b53e7fabd29bae5d47d1a19bd1bb95` |

arm64-only, dev/test — mainnet hold not lifted. UNCLE SAM unchanged
from the 2.15.3 section below.

## Clients · Core `8e5da769` (SEC-02 + redeem hardening + Send Proof · wallet 2.15.3)

Master `e05daabf` — consolidated single source of truth (no side branches; all
Mac feature work landed). Bundled CoreID
`8e5da7699b98fd2de7563586665672ff2c6e89831005b8fcada6f14daf6c9869` (unchanged —
client-only rebuilds, no re-soak).
Release: [`clients-8e5da769`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/clients-8e5da769) (Latest).
**Live wallet (Pages):** https://axiom-origin-validator.github.io/axiom-dist/web/

Core delta over `11d5268d`: **SEC-02** — Core CL5 rejects a genesis claim whose
FACT link is not Nabla-blessed (cap-at-mint via FACT scar). SDK delta:
**redeem hardening** (`8ce4ca9c`) — a transient §4.6 Nabla cheque-claim-proof
timeout is retried instead of misclassified as a permanent failure. Features:
**Send Proof** (CL12 Core-attested verify + `.axproof` export). Mac: in-app SDK
log (with launch-crash fix `34f1716b`), active-wallet card, Activity
NET-credit + layout fixes; wallet client bumped 2.15.2 → **2.15.3** (`455d99e1`).
Webclient delta (`34dfb066`): **genesis self-redeem feeds the blessed fact_chain**
to Core CL5 so a browser genesis claim no longer rejects with
`GenesisNablaBlessingMissing` (mirror of native `redeem.rs` source-3; WASM-only,
no Core change). Webclient TLS-gateway transport (`e416cb87`): when served over
https, auto-upgrades `ws://H:P/REST → wss://axiom-dev.mooo.com/tot/P/REST` so the
hosted (Pages) wallet transacts through the Caddy front proxy (TOT/Nabla stay
plaintext + cert-free — AXIOM_DESIGN_TOT.md §4.2). Webclient bundle rebuilt —
`.html`/`.zip` hashes change.
Soak-validated: genesis gate 50/50 with 0 false rejections; redeem fix verified
over a multi-hour run (0 fatal CL5 rejects, fail=0).

| Artifact | sha256 |
|---|---|
| `axiomwallet-8e5da769-2.15.3.dmg` (AxiomWallet + AxiomKiddo) | `2b25156dc746ade714a8d5834f4e66c7de10604cac0ae8d88666615785daf910` |
| `unclesam-8e5da769-0.2.0.dmg` | `35bf38f3d405d4d87fe4314c4ce5dc4fa0b66ab446c6dc030f08067f8649b74d` |
| `webclient-8e5da769-3.2.0.html` | `fe827494525e4c8a45910cef97d2fb08500e25a736c82f2fcb2680daf82122f3` |
| `webclient-8e5da769-3.2.0.zip` | `2129aa7c6fbfeee9eb2b8269ff8c9cb358c739478c2d531f8e5d99e76ff339b8` |

arm64-only, dev/test — mainnet hold not lifted.

## Clients · Core `11d5268d` (name-[coreid]-version scheme)

First release under the `name-<coreid>-<version>` identity scheme (no umbrella
`release` version; each artifact self-identifies, PINNED clients carry the Core
fingerprint). Master `dc43ec5e`. Bundled CoreID
`11d5268dc22da817c2b5c0bd687b6451e8e34f6653fd145550948486b299aa3e`.
Release: [`clients-11d5268d`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/clients-11d5268d).
**Live wallet (Pages):** https://axiom-origin-validator.github.io/axiom-dist/web/

| Artifact | sha256 |
|---|---|
| `axiomwallet-11d5268d-2.15.2.dmg` | `98fb512df5dfab7fe4f8315d270f7e543a5353b7d7aa7ed5a0637faabd2bf2b7` |
| `unclesam-11d5268d-0.2.0.dmg` | `36e8693e55e1164e8b4f1251b72d4f1941b0407d4eb733892339d607b825827c` |
| `webclient-11d5268d-3.2.0.html` | `d4f0dc67c0db44e0bde625dffae711df76a526e887ac4523ba6c9423d4151ba8` |
| `webclient-11d5268d-3.2.0.zip` | `b9d668d1c51f4df319ae2ac45ab4c0bf6ef0c40c7c76edf2340d8a517f1df372` |

Stable aliases on the release: `AxiomWallet.dmg`, `UNCLESam.dmg`,
`axiom-webclient.html`. arm64-only, dev/test — mainnet hold not lifted.

## v3.2.0-beta5 builds

| Date (UTC+9) | Master / Branch | Core ELF | DMG SHA-256 | Notes |
|---|---|---|---|---|
| 2026-07-03 | `2.18.1` (`mac-oods-final`, on master `0a89b1f0`) | `a14e13278e4f09f54f13d9e5404f1f810ffd3e45586ca5e06174b3f419f670ae` | `95dd3b58b749c6ffb6f83355010581456e94d7bc483daefec25078984564178d` | Release: [axiomwallet-a14e1327-2.18.1-20260703](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/axiomwallet-a14e1327-2.18.1-20260703) · Stable: [`releases/latest/download/AxiomWallet.dmg`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/latest/download/AxiomWallet.dmg). **OODS reading from the STORED receipt flag (no live query).** Reconciles with Linux's register-ACK fold (`ed5e015c`): the client never separately queries Nabla — the OODS attestation rides the register response, is cached, and Core stamps `Receipt.oods_flag`. The summary page (OverviewView) shows that stored `{tick, oods_size, healthy}` under the last-known TARDIS tick (health chip + "as of tick T"); removed the 2.18.0 live Settings panel + the deleted `sdk_fetch_oods_reading` query path. Same CoreID `a14e1327` (no rotation). Also this cycle: fixed the recurring "continuous update prompt" (stale `worldline.json.core_id`) — `publish-mac-wallet.sh` now auto-syncs `worldline.json` to `CORE_ID.txt` on every publish, and the webclient was rebuilt/republished on `a14e1327`. arm64-only, dev/test — mainnet hold not lifted. |
| 2026-07-03 | `2.18.0` (`mac-oods-panel-2.18.0`, on master `9518a5ac`) | `a14e13278e4f09f54f13d9e5404f1f810ffd3e45586ca5e06174b3f419f670ae` | `70b2584db0354db6f0ec823302b9ee5148a4cc6984847f1100ba422561a5ccfc` | Release: [axiomwallet-a14e1327-2.18.0-20260703](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/axiomwallet-a14e1327-2.18.0-20260703) · Stable: [`releases/latest/download/AxiomWallet.dmg`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/latest/download/AxiomWallet.dmg). **YPX-021 §8.2 OODS health flag.** Rebuilt on CoreID `a14e1327` (rotated `5564323f → a14e1327`; Receipt-commitment + NBC-format break — a wallet-format break, old `wallet.cbor` will not load, expected pre-mainnet). New Settings → Network "Network size (OODS)" panel: live point-in-time network-size estimate + health chip (`sdk_fetch_oods_reading` FFI → `fetch_oods_attestation`, TCP-only). Env-verified on the live mesh (`oods_estimate` 10.82 → ~11, healthy). arm64-only, dev/test — mainnet hold not lifted. |
| 2026-06-11 | `1ed4bd8f`+cherry-picks (`mac-ui-overhaul`, on master `077e6cde`; row recorded pre-integration) | `3b8d3eefe45e3d80dd55bd2372ac9f812cbe9ba2a3b632f9119fa9bfd3a1fd68` | `548acb39484b793e1e285fcf57c90c9f99834db5e0be22f88487e6ec5239b6a7` | Release: [wallet-3.2.0-beta5-20260611-3b8d3eef](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/wallet-3.2.0-beta5-20260611-3b8d3eef) · Stable: [`releases/latest/download/AxiomWallet.dmg`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/latest/download/AxiomWallet.dmg). **Golden Gate UI overhaul + two tester-reported fixes.** Full visual/interaction redesign of AxiomWallet + AxiomKiddo: design-token layer (typography/spacing/radii/motion, tabular figures on all amounts, `ChequeStatusStyle`/`TierStyle` single mappings, status never color-only), sidebar shell (plain HStack — NavigationSplitView screen-height layout bug sidestepped), resizable window (min 860×600, default 1040×720), chrome-translucency preference (default Low, Reduce Transparency honored). Fixes rolled in: **KI#29** genesis-claim cheque-sweep (`413b616e`, env-smoke-verified on the live mesh 2026-06-11 — claim leaves pre-existing inbound cheques Pending; post-claim redeem credits normally) and **packaged-ELF name mismatch** (`1fc2b593` cherry-picked as `30b7be4e` — app now finds its bundled `axiom-core.elf`; beta3/4 testers saw build-machine dev paths in the setup error). Same Core ELF as beta4 (`3b8d3eef`), wire-compatible with the deployed mesh. arm64-only, dev/test — mainnet hold not lifted. |

## v3.2.0-beta3 builds

| Date (UTC+9) | Master / Branch | Core ELF | DMG SHA-256 | Notes |
|---|---|---|---|---|
| 2026-06-08 | `c5ddff69` (`mac-dmg-v3.2.0-beta3`, version bump on master `c5ddff69`) | `6197af45acb0f98f199ceba6003a67d0da84385fa5fff881da16ae7be40ad94d` | `5ac01a9b318979393597a23463de4f93dc383cad0400080ad243074bff28baa2` | **Tier 1 / SSR — silent FACT-chain corruption closed.** A wallet could persist a discontinuous FACT chain (`link[i].previous_state_id ≠ link[i-1].new_state_id`) that self-reported "healthy" via `diagnose()` but rejected every outbound send — funds receivable but unspendable, silently (real case: `uj@axiom.internal`). Fix enforces continuity at COMPOSE/STORAGE time, not just verify: Core `build_fact_link` rejects `FactChainBreak` before signing; SDK `set_fact_chain` now returns `SdkResult<()>` and refuses to persist a gapped chain via the new `commit_protocol_transition` primitive (send/redeem/heal/genesis routed through it); `diagnose()` surfaces a `fact_chain_broken` action; new `ErrorCode::FactChainCorrupted` (recovery=Fatal). CoreID rotated `9088913f → 6197af45` (Core change) — wire-incompatible with prior builds; env redeployed + verify_deploy.sh green. SDK 153 (sdk-core) + 66 (sdk) tests green incl. 8 new continuity gate tests. **Swift UX wired:** `FactChainCorrupted` (send/redeem) and the `fact_chain_broken` diagnose action both surface a shared "Wallet structurally corrupted — can receive but not send, contact operator" message (persistent Overview banner + Send/Redeem outcome banners), with NO heal/burn/wipe affordance (a continuity break isn't heal-recoverable and the keypair is fine); the diagnostic report gains an explicit `fact_chain continuity: OK/BROKEN` line so a corrupted wallet no longer reads "healthy". **Deferred to PR2:** automatic recovery for already-corrupted wallets (heal is gated on scar/garbage, both 0 on a clean continuity break). arm64-only, dev/test — mainnet hold not lifted. |

## v3.2.0-beta2 builds

| Date (UTC+9) | Master / Branch | Core ELF | DMG SHA-256 | Notes |
|---|---|---|---|---|
| 2026-06-08 | `85c25c7b` (`mac-dmg-v3.2.0-beta2`, version bump on master `1b2c528b`; row backfilled — branch not merged to master) | `9088913fc2d931be23cd47e847d55a7569eaa7b487d3c162e698b2f104306975` | `721e1d6449fca06d705030f5a0e5cf84df3f7055402f5933c8f33f622374ffa9` | Release: [wallet-3.2.0-beta2-20260608-9088913f](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/wallet-3.2.0-beta2-20260608-9088913f). **KI#13 CoreID rotation rebuild.** Rebuilt against the KI#13 ELF (`9088913f`) so the wallet is wire-compatible with the post-KI#13 mesh (prior `0a93f34e` builds were not). Also rolled up integrated SDK work: KI#14 durable redeemed-cheque marker + `redeem()` pre-flight gate, cl1/cl5 execute-attest consolidation, shared `axiom-rate-limit` crate. Wallet-format break: `redeemed_cheque_ids` ships without `serde(default)`. arm64-only, dev/test — mainnet hold not lifted. |

## v3.1.0-beta7 builds

| Date (UTC+9) | Master / Branch | Core ELF | DMG SHA-256 | Notes |
|---|---|---|---|---|
| 2026-06-07 | `e0a2e60b` (master) | `0a93f34e541d13e15a9a5b46feac31bd76942411a816787a4e151d1a47f239d0` | `6b48234b7925e92681959f7cac0752899434bac3b9daba2e1d6e2dfc4d458a14` | Release: [wallet-3.1.0-beta7-20260607-0a93f34e](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/wallet-3.1.0-beta7-20260607-0a93f34e) · Stable: [`releases/latest/download/AxiomWallet.dmg`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/latest/download/AxiomWallet.dmg). **Wallet UX hardening pass (live-test driven).** Rolls up: background genesis/airdrop claim — no timeout, cancellable; redeem CL5 local fail-fast (no 60s dead-wait on a doomed redeem); witness-round Cancel now responsive on the FINAL validator step (~10s grace instead of stranding to the 180s timeout) across both send and redeem; a 2nd concurrent redeem is blocked (macOS `.sheet` env re-injection so the in-flight gate is observed, + a hard guard — YP §32 fork risk); and a build-tooling fix (build-dev-app.sh now rebuilds the release FFI the app actually links). SDK + Swift only — same Core ELF (`0a93f34e`), wire-compatible with the deployed mesh. arm64-only, dev/test — mainnet hold not lifted. |

## v3.1.0-beta6 builds

| Date (UTC+9) | Master / Branch | Core ELF | DMG SHA-256 | Notes |
|---|---|---|---|---|
| 2026-06-07 | `7c57ed01` (master) | `0a93f34e541d13e15a9a5b46feac31bd76942411a816787a4e151d1a47f239d0` | `5a8c517af5c83b76cdfa19512d9e7404792c06b1ad9c362dfa382b5040c2ce0b` | Release: [wallet-3.1.0-beta6-20260607-0a93f34e](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/wallet-3.1.0-beta6-20260607-0a93f34e) · Stable: [`releases/latest/download/AxiomWallet.dmg`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/latest/download/AxiomWallet.dmg). **Genesis/airdrop claim backgrounded — no timeout, cancellable.** The claim was the only TX flow still running view-scoped in a `Task.detached`, which (a) re-pinned to the main actor and beachballed the whole UI for the multi-second claim, and (b) used a hard `chequeWaitSecs: 60` that failed on slow networks — dangerous since a failed genesis claim can be terminal (YP §17.11.7). Now: app-scoped `ClaimCoordinator` runs the claim on `DispatchQueue.global` (no freeze) and survives sheet dismissal; the cheque-wait is unbounded (SDK `claim_genesis_full` drops `cheque_wait_secs`, polls the send-cancel flag → `SendCancelled`); 5-stage progress + a tappable gross−fees=net success detail live in the app chrome; Claim / Send / Receive single-flight-gate each other (YP §32). Onboarding claim gets the same beachball + no-timeout fix plus a Cancel affordance. SDK + Swift only — same Core ELF (`0a93f34e`), wire-compatible with the deployed mesh. arm64-only, dev/test — mainnet hold not lifted. |

## v3.1.0-beta5 builds

| Date (UTC+9) | Master / Branch | Core ELF | DMG SHA-256 | Notes |
|---|---|---|---|---|
| 2026-06-07 | `51220abe` (master) | `0a93f34e541d13e15a9a5b46feac31bd76942411a816787a4e151d1a47f239d0` | `1870002964272e9e415ddfe90d9e86f8fb67e23dcdb2c4f77b7cc3194d50a416` | Release: [wallet-3.1.0-beta5-20260607-0a93f34e](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/wallet-3.1.0-beta5-20260607-0a93f34e) · Stable: [`releases/latest/download/AxiomWallet.dmg`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/latest/download/AxiomWallet.dmg). **New UX:** the in-flight send progress bar now shows a "Preparing to send — validating transaction…" phase with an animated sweep while the SDK builds + locally CL1-validates the TX, instead of sitting at a stuck-looking "0 of 3 validators witnessed". `wallet.sendProgress()` is nil until the SDK reaches the witness round (`begin_send_progress`, `sdk/client/src/send.rs:632`); `SendProgressBar` renders that nil window as a distinct Preparing phase, then transitions seamlessly into the n-of-k witness fill. Cancel stays live through Preparing (no witness dispatched yet). Same Core ELF as beta4 (`0a93f34e`); UI-only addition. arm64-only, dev/test — mainnet hold not lifted. |

## v3.1.0-beta4 builds

| Date (UTC+9) | Master / Branch | Core ELF | DMG SHA-256 | Notes |
|---|---|---|---|---|
| 2026-06-07 | `d969311e` (master) | `0a93f34e541d13e15a9a5b46feac31bd76942411a816787a4e151d1a47f239d0` | `a3a58160104c99a0cd8c8b899f7ee7312652b06c73b0e1b89e172151b7dbd098` | Release: [wallet-3.1.0-beta4-20260606-0a93f34e](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/wallet-3.1.0-beta4-20260606-0a93f34e) · Stable: [`releases/latest/download/AxiomWallet.dmg`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/latest/download/AxiomWallet.dmg). Bundles the CL5 fresh-wallet first-cheque-receive fix (`75446dfa`) — a brand-new wallet can now redeem a received cheque as its first TX. **New UX:** redeeming a cheque now warns when the wallet can still claim the free genesis airdrop (YP §17.11). Redeeming consumes first-TX status and forfeits the airdrop, so `BundleDetailView` interrupts with "Claim airdrop first / Redeem anyway / Cancel" (`canStillClaimAirdrop`, mirrors `OverviewView.canClaimGenesis`). Same Core ELF as the beta3 build (`0a93f34e`); UI-only addition. arm64-only, dev/test — mainnet hold not lifted. |

## v3.1.0-beta1 builds

| Date (UTC+9) | Master / Branch | Core ELF | DMG SHA-256 | Notes |
|---|---|---|---|---|
| 2026-06-06 | `8021c979` (master, denomination consolidation `45d1886f` is one ahead Linux-side, no Mac surface) | `efdc7edd261fce380cb7aef97d126e51ead7c391270455719cdc2020d00b9abb` | `7c7bb3d0c8edfb12a76f3d70bca95f766f9e4d10cc297ff032951015758b25e8` | Release: [wallet-3.1.0-beta1-20260605-efdc7edd](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/tag/wallet-3.1.0-beta1-20260605-efdc7edd) · Stable: [`releases/latest/download/AxiomWallet.dmg`](https://github.com/AXIOM-Origin-Validator/axiom-dist/releases/latest/download/AxiomWallet.dmg). Replaces the earlier same-tag publish (deleted to make room; stable URL HTTP 200 verified by `publish-mac-wallet.sh`). **Five UI fixes on top of the previously-published `e9ffcdc7…` build:** **(D)** `RedeemCoordinator` is app-scoped and runs on `DispatchQueue.global`, so a redeem survives the sheet closing mid-flight (mirrors the Send beachball fix at the redeem path). **(E)** Cheque preserved on Nabla `REDEEMED` when no local `Receipt` exists — closes the "cheque disappeared after timeout" failure mode where the wallet correctly observed final state on Nabla but couldn't reconstruct its own receipt. **(G)** Redeem cancel parity with Send — shared `AtomicBool` so the cancel button gates uniformly across Send / Receive / Redeem panels. **(H)** Receive-side FFI `recv()` switched from `inner.lock()` to `try_lock + cache` (same pattern as the KI#15 family — `history()`, `list_pending_cheque_bundles()`, etc) — kills the 3-second timer beachball that fired while a redeem held the wallet lock. Also: redeem progress bar now renders k=3 witness segments, and the cancel warning explicitly names heal/burn recovery paths so users understand the consequence before tapping cancel. **(I)** Activity rows: send rows expose a `Witnesses (N)` disclosure showing the k-set chosen for the TX; redeem rows highlight S-ABR-overlapped validators with a green-bordered "witness" pill so reconciliation across the send/redeem pair is visually obvious. Plus: redeem progress bar's Nabla pre-flight is segment 0 so the bar lights up at the start of `verify_cheque` instead of staying dark through the §4.6 round-trip (commit `c1192c2a`). **Deferred — Bug F**: orphan validator-response scavenge on redeem retry. Needs either wallet-side `request_id` history or full crypto re-verification of scavenged sigs; auto-accepting without either is a stale-state-orphan risk that breaks the receipt build. Proposal forthcoming. arm64-only, dev/test — mainnet hold not lifted. |

## v3.0.0-beta4 builds

| Date (UTC+9) | Master / Branch | Core ELF | DMG SHA-256 | Notes |
|---|---|---|---|---|
| 2026-05-26 | `mac-beta4-batch` | `04be8a9c377d7296e9b55a5587ea53be9a17b816e60738496a423944badc2836` | `e5a9d3cdcd6be4bedce7891d2ecc4bf0f0bde3fefc14ba4313e67d6f6f54fafe` | v3.0.0-beta4 — UX + SDK polish on top of beta3 (no protocol surface touched; same Core ELF). **Headline:** the full beachball-during-send class is gone — Send / Redeem / Address / Activity / Contacts / Overview all stay responsive while a witness round is in flight. **SDK FFI (KI#15 v2):** extends the `try_lock + Vec cache` pattern to `list_pending_cheque_bundles()` and `all_addresses()` (last two methods that took `inner.lock().unwrap()` on a UI-callable path). Closes KI#15 fully — Mac gate-on-isSending in `activityPreview` is removed; UI just reads cached values during a send. **Mac UI:** Send + Redeem buttons disabled during `sendCoordinator.isSending` (SDK is single-flight; parallel TXs trigger Nabla fork detection per YP §32, can ban the wallet — tooltip explains both). Address stays clickable (read-only, cached). Discard-cheque alert rewritten — old copy contradicted YP §17.9.5 (cashier's cheque model has no clawback); new copy is honest about the destructive nature, suggests contacting the sender out-of-band. KI#16 filed for the proper protocol-side fix (cross-evidence exchange). Recent-activity rows render heal as em-dash (—) instead of misleading "0.00 L\$" — heals are wallet-internal recovery self-sends, no value transfer to display. Contacts footnote clarifies app-bound (shared across every wallet on this Mac, not stored inside any wallet, not in backup files). arm64-only, dev/test — mainnet hold not lifted. |

## v3.0.0-beta3 builds

| Date (UTC+9) | Master / Branch | Core ELF | DMG SHA-256 | Notes |
|---|---|---|---|---|
| 2026-05-25 | `mac-send-beachball-fix` (`01bb9127`, integrated as `027a377b`) | `04be8a9c377d7296e9b55a5587ea53be9a17b816e60738496a423944badc2836` | `ad31f58998c1141e2273df30367ae6fbdba7bf2a62cd6fac06b6e2109de1d7cc` | **VALIDATED 2026-05-26** by AXIOM Origin on master `d57b7cfe` — end-to-end send completes with no beachball, cursor stays responsive throughout the witness round, activity card swaps from placeholder back to history rows the moment the coordinator clears. Fixes the "Sign and broadcast → beachball" reported on the earlier two builds. Root cause: `OverviewView.activityPreview` calls `wallet.history()` which uses blocking `inner.lock().unwrap()` and the in-flight `wallet.send()` holds `inner` for the entire 5-30s witness round. Mac-side gate: `activityPreview` shows a "Refreshes once the send completes…" placeholder while `sendCoordinator.isSending`. Also tightened `broadcast()` to use `DispatchQueue.global` instead of `Task.detached` (Swift isolation-inheritance can re-pin a detached closure to MainActor inside a SwiftUI view body). Linux SDK follow-up tracked as KnownIssue #15 (`docs/AXIOM_REPORT_KnownIssues.md`): make `wallet.history()` + `list_scarred_links()` + `last_receipt_witness_ids()` use `try_lock + atomic cache` (same pattern as `balance`/`fact_link_count`/etc), then the Mac-side gate can be removed. Bundles same Core ELF as prior beta3 builds. arm64-only, dev/test — mainnet hold not lifted. |
| 2026-05-25 | `mac-kiddo-stop-orphaned-workers` (`5c0fda35`) | `04be8a9c377d7296e9b55a5587ea53be9a17b816e60738496a423944badc2836` | `4614255e151196da2dbcf4c952f6c06c47f0910fc5cb56e20d7bdadbbaa5ad89` | SUPERSEDED by `ad31f589…` — same UI restructure release, but the Sign-and-broadcast beachball reproduces on this build (and on the `3904b8ca…` followup rebuild). Persistent Overview chrome (balance + status + 6-button action row) over a routed content panel that swaps Send / Redeem / Activity / Contacts inline (the old top nav bar is gone); folder icon opens Wallets in a sheet with a Close button so there is always a return path. Display fixes per YP: L$ is suffix (`50.00 L$`), Ark prefix `⟠` (U+27E0) on every unit (L$ + AXC) shown under an Ark wallet. SendView lost the redundant SEND-FROM card. Bundles same Core ELF (`04be8a9c…`) as `v3.0.0-beta2`; protocol unchanged. arm64-only, dev/test. |

## v2.16.0-rc1 builds

| Date (UTC+9) | Master / Branch | Core ELF | DMG SHA-256 | Notes |
|---|---|---|---|---|
| 2026-05-19 | `beb79ff3` | `a4e4fee861a324e874544bf31c1084d94a160c8184ab7239887de1bc1d5903c1` | `0730fee1fe5ed3fb0cde881ef32616b86b1b12f252a2e6a4e4289864de64cde5` | v2.16.0-rc1 rebuild on `beb79ff3` (master after "restore core/artifacts/ to the RC1 ELF"). Bundles the **same Core ELF** (`a4e4fee8…`) as the `955a58c3` build below — the restore resolved `core/artifacts/` back to `a4e4fee8`, so the shipped Core is unchanged; only the build is fresh. Structural verify pass; the bundled ELF is byte-identical to the one the `955a58c3` build was tamper-smoke-verified against. arm64-only, dev/test — mainnet hold not lifted. |
| 2026-05-19 | `955a58c3` | `a4e4fee861a324e874544bf31c1084d94a160c8184ab7239887de1bc1d5903c1` | `58e67b160705f6f1766e1c14e02b85110e358f28a1a0a3be4506797bd276879e` | v2.16.0-rc1 — arm64-only, dev/test. Bundles the v2.16 Core ELF (`a4e4fee8…`, differs from v2.15's `9a6bb78d`). Self-named from VERSION.toml; structural verify + tamper-smoke both pass — CoreID gate confirmed end-to-end. Mainnet hold not lifted. |

## v2.15.0-beta1 builds

| Date (UTC+9) | Master / Branch | Core ELF | DMG SHA-256 | Notes |
|---|---|---|---|---|
| 2026-05-17 | `a2ffa83f` | `9a6bb78daf18c5de2ba8e9a556d5cd07168b42a71ce55bfc65334bbfc4b1bb58` | `24a3674929b325e1bbe6bc4b873562ceda871350f722d1b7b93354f1aae34b98` | v2.15.0-beta1 — first DMG on the per-component VERSION.toml register; `release-dmg.sh` single-sources the version and bundles the published `core/artifacts/` ELF. arm64-only. Dev/test only — mainnet hold not lifted. |

## 2.14.0 builds

| Date (UTC+9) | Master / Branch | Core ELF | DMG SHA-256 | Notes |
|---|---|---|---|---|
| 2026-05-15 | `f73d763c` | `0bfb34882732f9369ee34eee314821f278df46c698f554f9754d620892c2ec11` | `d7c71ca402683b69c7c74cf2045513b76eb6b9925136166bc9efaefec8463695` | V2 fact-confirm payload + CL5 same-tick redeem block (matched ELF/SDK pair for bc65343a) |
| 2026-05-15 | `fadd3693` (`mac-wallet-settings-window`) | `7e8320c95e2a1b53aaad048060ef3628e7c4ee2093460b9723226594b3fb1f89` | `3ababcb25e3fe74c2d90aaccac2d101d81a0543e5968d7032cf0f9c5049b7d96` | SUPERSEDED by `d7c71ca4` — wire-incompatible after V2 cutover (pre-bc65343a SDK + ELF pair, FACT links signed with V1 payload would fail verify_fact_link against post-bc65343a validators) |
| 2026-05-15 | `eb79a624` (`mac-wallet-settings-window`) | `7e8320c95e2a1b53aaad048060ef3628e7c4ee2093460b9723226594b3fb1f89` | `0114c8b449f1b0fbe65cfcda2db4572e273b2db6d9b7930c49d3a22d703f2e9e` | SUPERSEDED by `3ababcb2` — same CoreID, earlier welcome-note copy |
| 2026-05-15 | `93cc5fef` | `7e8320c95e2a1b53aaad048060ef3628e7c4ee2093460b9723226594b3fb1f89` | `cc62d816bd3b64af2da01dc073b2a65bef5875ea8359d0d3cfa194b87d0a0435` | SUPERSEDED by `0114c8b4` — same CoreID, missing the UX polish + KI #5 visibility |
| 2026-05-14 | `b9fa3baf` | `1cb237aacf715dd882b7dfeefbb1413f1c11c3978abbdbb2e7a8bfdf229fb6bd` | `2f7dcf42e909b7dad22822e2c9b1e4af215fb6f76f048378f6fc0339aa4caa23` | SUPERSEDED — CoreID rejected by post-NBC validators |
| 2026-05-14 | `27b60844` | `8cf4eac299f63c1b611339fe4b40d8bbe58c0f2aafd925b4487020ef4271e4d8` | `6ba376655add701febca7699cb884d9d3dafd8bcf5d9c69e62289cb3ffd652e5` | SUPERSEDED — pre-CBOR-on-disk Lambda |

Each "SUPERSEDED" build is left in the log so people who downloaded
the artifact can match the SHA to confirm what they ran — they're not
deleted, just labelled.

## How to verify a downloaded DMG

```
shasum -a 256 Axiom-2.14.0.dmg
```

Compare the result against the SHA-256 column for the date you
downloaded it. If it doesn't match any row, do not install — the
binary was modified between the publisher and you.

## How to verify the bundled Core ELF (post-install)

Open Settings → Advanced → System Status. The "Loaded CoreID" row
shows the BLAKE3 of `AxiomWallet.app/Contents/Resources/
axiom-core.elf` as the wallet's `axiom_sdk::setup()` loaded it.
Compare against the "Core ELF" column above for the DMG you
installed; they must match exactly. A mismatch means either the .app
was modified after install, or `AXIOM_CORE_ELF` is pointing at a
different build — in either case the wallet's `setup()` will refuse
to start with a clear error pointing at the discrepancy (this is the
`AXIOM_CANONICAL_CORE_ID` gate baked at build time).
