#!/usr/bin/env bash
# build-dev-app.sh — fast-iteration debug build wrapped in proper
# .app bundles, installed into /Applications/ and launched.
#
# This is the dev-loop sibling of `release-dmg.sh`. Both produce
# launchable `AxiomWallet.app` + `AxiomKiddo.app` bundles; the
# difference is build profile and what happens after:
#
#   release-dmg.sh   — `cargo build --release` + `swift build -c release`
#                      + assemble + ad-hoc sign + .dmg + verify.
#                      Output: dist/Axiom-<version>.dmg
#                      (5-10 min on a clean tree).
#
#   build-dev-app.sh — `cargo build -p axiom-sdk-ffi --release` (the lib
#                      the app links — see below) + `swift build` (debug)
#                      + assemble + ad-hoc sign + install to
#                      /Applications + launch. No .dmg.
#                      Output: dist-dev/.stage/{AxiomWallet,AxiomKiddo}.app
#                      (10-60 sec on an incremental tree).
#
# WHY THIS SCRIPT EXISTS:
#
# macOS 15+ Sequoia and macOS 26 Tahoe enforce Local Network privacy
# on `Network.framework` connections to RFC1918 / link-local IPs.
# The OS keys the permission grant off the *bundle ID*. A raw
# `.build/debug/AxiomKiddo` binary has no bundle ID — the OS treats
# it as an unknown caller, silently denies the connection, and
# never shows a permission prompt. Result: POP3 / SMTP / Nabla TCP
# all silently time out, with no actionable error path.
#
# Wrapping the same debug binary in a proper `.app/Contents/`
# layout (with `Info.plist`, `MacOS/`, `Resources/`) lets macOS
# recognise it as a real app, attach a grant to the bundle ID, and
# show the Local Network prompt on first launch. Dev iteration
# speed is preserved (still a debug build); the OS-permission
# behaviour matches what release users see.
#
# Run from anywhere — paths resolve via SCRIPT_DIR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist-dev"
STAGE_DIR="$DIST_DIR/.stage"

# Core ELF — the committed, published release artifact (same one
# release-dmg.sh bundles). The dev .app loads it via
# `Bundle.main.url(forResource:"axiom-core", withExtension:"elf")`.
CORE_ELF="$WORKSPACE/core/artifacts/axiom-core.elf"
# RELEASE, not debug: AxiomWallet/Package.swift links
# target/release/libaxiom_sdk_ffi.a. Building debug here would compile
# fine but never reach the app — it would silently keep linking a STALE
# release .a, so SDK changes wouldn't take effect (this footgun cost
# real time, 2026-06-07). Swift-only edits stay fast: cargo no-ops when
# the SDK is unchanged, so only actual SDK changes pay the release compile.
RUST_LIB="$WORKSPACE/target/release/libaxiom_sdk_ffi.a"

# Path hygiene (matches release-dmg.sh): build under a username-free CARGO_TARGET_DIR so the
# vendored-openssl OUT_DIR baked as OPENSSLDIR carries no operator name; copy the clean lib
# back to target/release/ (Package.swift links from there).
export CARGO_TARGET_DIR="${AXIOM_FFI_TARGET_DIR:-/tmp/axiom-build}"
SWIFT_SCRATCH_BASE="${AXIOM_SWIFT_SCRATCH:-/tmp/axiom-swift-build}"  # username-free swift .build (baked as a resource-bundle fallback)

bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }

# ── pre-flight ─────────────────────────────────────────────
if [ ! -f "$CORE_ELF" ]; then
    red "Missing published Core ELF: $CORE_ELF"
    red "Pull latest master — core/artifacts/ is the release artifact."
    exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# ── (1) Rust SDK FFI static lib (RELEASE — the linked lib) ─────────
# NO AXIOM_CANONICAL_CORE_ID — the dev build deliberately skips the
# baked-in CoreID gate so the loaded ELF doesn't need to match a
# pre-computed hex constant. axiom_sdk::setup() treats empty
# canonical as "skip the check" — same as a legacy TX from before
# the gate existed.
# DEV build → `chaos` feature ON (fault-injection hooks). The release DMG
# (release-dmg.sh) omits it so the shipped binary can't honor AXIOM_CHAOS_*.
# The uniffi-bindgen run below carries the same feature or cargo flips the
# artifact. Swift fault UI is #if DEBUG (this build is debug → shown).
bold "==> cargo build -p axiom-sdk-ffi --release --features chaos (dev lib)"
cd "$WORKSPACE"
cargo build -p axiom-sdk-ffi --release --features chaos
mkdir -p "$WORKSPACE/target/release"
cp -f "$CARGO_TARGET_DIR/release/libaxiom_sdk_ffi.a" \
      "$CARGO_TARGET_DIR/release/libaxiom_sdk_ffi.dylib" "$WORKSPACE/target/release/"

if [ ! -f "$RUST_LIB" ]; then
    red "cargo did not produce $RUST_LIB"
    exit 1
fi

# ── (2,3) Per-app build + .app assembly ───────────────────
build_app() {
    local app_name="$1"           # AxiomWallet | AxiomKiddo
    local app_dir="$SCRIPT_DIR/$app_name"
    local app_bundle="$STAGE_DIR/$app_name.app"
    local contents="$app_bundle/Contents"

    bold "==> swift build $app_name (debug)"
    cd "$app_dir"

    # Regenerate uniffi bindings for the Wallet (Kiddo has no FFI dep).
    # Use the release-build dylib (matches the linked .a) — uniffi-bindgen
    # reads the library's symbol table to discover exported functions;
    # debug vs release doesn't matter for the bindings themselves, but
    # using the release dylib keeps everything on one build profile.
    if [ "$app_name" = "AxiomWallet" ]; then
        local raw="$app_dir/Generated/.raw"
        local sdk="$app_dir/Generated/AxiomSdk"
        local ffi="$app_dir/Generated/AxiomSdkFFI"
        mkdir -p "$raw" "$sdk" "$ffi"
        cd "$WORKSPACE"
        cargo run -p axiom-sdk-ffi --features chaos --bin uniffi-bindgen -- \
            generate --library "$WORKSPACE/target/release/libaxiom_sdk_ffi.dylib" \
            --language swift --out-dir "$raw"
        cp "$raw/axiom_sdk_ffi.swift" "$sdk/"
        cp "$raw/axiom_sdk_ffiFFI.h"  "$ffi/"
        cp "$raw/axiom_sdk_ffiFFI.modulemap" "$ffi/module.modulemap"
        cd "$app_dir"
    fi

    swift build --scratch-path "$SWIFT_SCRATCH_BASE/$app_name" --product "$app_name"

    local built_binary
    built_binary="$(swift build --scratch-path "$SWIFT_SCRATCH_BASE/$app_name" --product "$app_name" --show-bin-path)/$app_name"
    if [ ! -f "$built_binary" ]; then
        red "swift build did not produce $built_binary"
        exit 1
    fi

    bold "==> assembling $app_name.app"
    rm -rf "$app_bundle"
    mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/_CodeSignature"

    cp "$app_dir/Info.plist" "$contents/Info.plist"
    cp "$built_binary" "$contents/MacOS/$app_name"
    chmod +x "$contents/MacOS/$app_name"

    # Flatten the SwiftPM resource sub-bundle into Contents/Resources/
    # — same trick release-dmg.sh uses. Without this, Bundle.main.url
    # returns nil for the seed-defaults / Localizable.strings and the
    # wallet falls back to the empty validators.list.
    local resource_bundle
    resource_bundle="$(dirname "$built_binary")/${app_name}_${app_name}.bundle"
    if [ -d "$resource_bundle" ]; then
        cp -R "$resource_bundle/" "$contents/Resources/"
    fi

    # Wallet needs the Core ELF inside the bundle so axiom_sdk::setup()
    # can find it without env vars. Kiddo doesn't touch the SDK.
    if [ "$app_name" = "AxiomWallet" ]; then
        cp "$CORE_ELF" "$contents/Resources/axiom-core.elf"
    fi

    # App icon — Info.plist's CFBundleIconFile=AppIcon resolves to
    # Contents/Resources/AppIcon.icns. Optional in dev (the rendered
    # icon falls back to the generic app icon if absent).
    local icns_src="$app_dir/Sources/$app_name/Resources/AppIcon.icns"
    if [ -f "$icns_src" ]; then
        cp "$icns_src" "$contents/Resources/AppIcon.icns"
    fi

    # Ad-hoc sign so macOS Gatekeeper recognises the bundle. Even
    # debug builds need this — an unsigned .app refuses to launch
    # on macOS 15+ until the user right-clicks → Open the first time.
    # Ad-hoc satisfies the "signed at all" requirement; the user
    # still gets a "from an unidentified developer" warning unless
    # they `xattr -d com.apple.quarantine` first (we do that below
    # when installing into /Applications).
    # Prefer a STABLE self-signed identity over ad-hoc. Ad-hoc changes the
    # code signature on every rebuild, so the Keychain (which gates the wallet
    # at-rest key on the app's identity) re-prompts "allow access" each launch
    # and "Always Allow" never sticks. A stable identity makes the grant
    # persist. Run `make-dev-signing-cert.sh` once to create it; until then we
    # fall back to ad-hoc.
    # Resolve to the identity's SHA-1 HASH and sign by hash — codesign's by-NAME
    # match mis-handles a non-ASCII CN (the Ø in "AXIØM"); the hash is encoding-proof.
    local sign_id="${AXIOM_CODESIGN_IDENTITY:-AXIØM TrustMesh Project}"
    local sign_hash
    sign_hash="$(security find-identity -p codesigning 2>/dev/null | grep -F "$sign_id" | head -1 | awk '{print $2}')"
    if [ -n "$sign_hash" ]; then
        bold "==> codesign $app_name.app  ($sign_id — stable identity, Keychain grant persists)"
        codesign --force --deep --sign "$sign_hash" "$app_bundle"
    else
        bold "==> ad-hoc codesign $app_name.app"
        yellow "    (ad-hoc → the Keychain re-prompts every launch; run make-dev-signing-cert.sh once to stop that)"
        codesign --force --deep --sign - "$app_bundle" 2>/dev/null
    fi
    green "    built: $app_bundle"
}

# ── Seed defaults ─────────────────────────────────────────
bold "==> bundling seed defaults from src/seeds/"
bash "$SCRIPT_DIR/sync-seed-defaults.sh"

build_app AxiomWallet
build_app AxiomKiddo

# ── Install to /Applications ──────────────────────────────
#
# Kill anything still running, blow away the prior /Applications
# copy, install the fresh debug .app, strip Gatekeeper quarantine.
bold "==> killing running AxiomKiddo / AxiomWallet (if any)"
killall AxiomKiddo  2>/dev/null || true
killall AxiomWallet 2>/dev/null || true
# Give them a moment to release file handles before we overwrite.
sleep 1
killall -9 AxiomKiddo  2>/dev/null || true
killall -9 AxiomWallet 2>/dev/null || true

bold "==> installing to /Applications"
rm -rf /Applications/AxiomWallet.app /Applications/AxiomKiddo.app
cp -R "$STAGE_DIR/AxiomWallet.app" /Applications/
cp -R "$STAGE_DIR/AxiomKiddo.app"  /Applications/

# Strip Gatekeeper quarantine — the .app was just built locally,
# not downloaded, but copying through staging can attach the
# attribute on some macOS versions.
xattr -dr com.apple.quarantine /Applications/AxiomWallet.app 2>/dev/null || true
xattr -dr com.apple.quarantine /Applications/AxiomKiddo.app  2>/dev/null || true

# ── Launch ────────────────────────────────────────────────
bold "==> launching"
open /Applications/AxiomWallet.app
# Small gap so the wallet's Bonjour-trigger / Local Network prompt
# fires first — clearer UX than two prompts overlapping.
sleep 2
open /Applications/AxiomKiddo.app

# ── Final report ─────────────────────────────────────────
green ""
green "Done."
green "  /Applications/AxiomWallet.app"
green "  /Applications/AxiomKiddo.app"
green ""
green "On first launch after this build, macOS should prompt for"
green "Local Network access (both apps, separately). Click Allow."
green "If no prompt appears, grant by hand at:"
green "  System Settings → Privacy & Security → Local Network"
green ""
green "Iterate: edit Swift source, re-run \`bash build-dev-app.sh\`."
