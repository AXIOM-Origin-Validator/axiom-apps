# axiom-apps

AXIOM reference applications — the Mac wallet (+ AxiomKiddo, its mail-gateway helper, in the same DMG), the UNCLE SAM bank client, and the web client. App shells over the AXIOM SDK.

Part of the AXIOM protocol family — specifications live in
[axiom-docs](https://github.com/AXIOM-Origin-Validator/axiom-docs), research in
[axiom-papers](https://github.com/AXIOM-Origin-Validator/axiom-papers), binaries in
[axiom-dist](https://github.com/AXIOM-Origin-Validator/axiom-dist).

## Contents

The reference applications — each an app shell over the
[axiom-sdk](https://github.com/AXIOM-Origin-Validator/axiom-sdk) (the Mac apps
link `AxiomSdkFFI`, built with `cargo build -p axiom-sdk-ffi`; the web client
embeds the SDK's WASM build).

### `macos/AxiomWallet/` — the wallet

The macOS reference wallet. Ships as a DMG **together with AxiomKiddo** (below),
packed into the same image.

### `macos/AxiomKiddo/` — KIDDO (Key-holder's Individual Delivery Dispatch for Outbox)

A menu-bar **mail-shaped gateway** for AXIOM wallets: the little helper that
carries envelopes to and from the wallet — it's allowed to look at envelopes
because relaying them is its whole job. Runs alongside the wallet and packs
into the same DMG.

### `macos/UNCLESam/` — UNCLE SAM (Apache-2.0)

The desktop client banks run against the
[axiom-uncle](https://github.com/AXIOM-Origin-Validator/axiom-uncle) stack.
SAM carries two names at once — **SWIFT-Aligned Messaging** and **Settlement
Anchor Mediator** — because the client plays exactly those two roles: it
speaks the bank's SWIFT-shaped messaging on one side and anchors AXIOM
settlement on the other. Licensed Apache-2.0 (see `macos/UNCLESam/LICENSE`),
matching the axiom-uncle stack, so bank forks lift client + daemon + wire
contract together.

### `webclient/`

The browser wallet: static web app embedding the SDK's WASM engine with the
CoreID-verified Core ELF. Built copies ship via
[axiom-dist](https://github.com/AXIOM-Origin-Validator/axiom-dist).

### Building

The Mac apps build on macOS (Swift Package Manager; `macos/build-dev-app.sh`,
DMG packaging via `macos/release-dmg.sh`). The web client builds anywhere
(`webclient/build.sh`). Licensing: GPL-3.0 except `macos/UNCLESam/`
(Apache-2.0).

## Releases

This repository receives one snapshot commit per AXIOM release, exported from
the project's working tree (3.3.0 at export). Its git log is the release
history. License: GPL-3.0.

> AXIOM is pre-mainnet software. Do not use it to custody real value.
