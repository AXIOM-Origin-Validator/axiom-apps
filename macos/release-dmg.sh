#!/usr/bin/env bash
# release-dmg.sh — Build AxiomWallet.app + AxiomKiddo.app into one DMG.
#
# Output: apps/macos/dist/Axiom-<version>.dmg
#
# What this script does:
#   1. cargo build -p axiom-sdk-ffi --release    (the Rust static lib both apps link)
#   2. swift build -c release                    (each .swift target)
#   3. Assemble each .app bundle:
#        Contents/Info.plist
#        Contents/MacOS/<binary>
#        Contents/Resources/{Localizable.strings, hint defaults, axiom-core.elf}
#        Contents/_CodeSignature/     (ad-hoc only)
#   4. Stage both .app's + a /Applications symlink + LICENSE + DISCLAIMER.txt
#   5. hdiutil create -format UDZO  (UDZO = compressed, smallest output)
#   6. Print the SHA256 of the resulting .dmg
#
# Signing posture: ad-hoc (`codesign -s -`) only. This satisfies macOS 15+'s
# "must be signed at all" requirement; users still see Gatekeeper's "unknown
# developer" prompt on first launch and right-click → Open to bypass.
# No identity, no Apple Developer Program involvement, no notarization.
#
# Run from repo root or anywhere — paths resolve via SCRIPT_DIR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
STAGE_DIR="$DIST_DIR/.stage"
# Per-artifact version — read from VERSION.toml [app]. There is NO umbrella
# version; each artifact self-identifies (see the VERSION.toml header). The
# DMG name itself is set AFTER the CoreID is computed (step 0 below), because
# these are PINNED clients whose identity is  name-<coreid>-<version>.
app_version() {  # $1 = key under [app]
    sed -n '/^\[app\]/,/^\[/p' "$WORKSPACE/VERSION.toml" \
        | grep -E "^$1[[:space:]]*=" | head -1 | sed -E 's/.*"([^"]*)".*/\1/'
}

# Build mode — selects which client DMG to produce:
#   (default) retail → AxiomWallet + AxiomKiddo  → axiomwallet-<coreid>-<wallet ver>.dmg
#   uncle            → UNCLESam (institutional)  → unclesam-<coreid>-<uncle ver>.dmg
# UNCLE SAM serves a different audience (banks), runs its own UNCLE TCP
# carrier (not Kiddo's mail gateway), so it ships as its own image.
MODE="${1:-retail}"
case "$MODE" in
    retail) APP_VER="$(app_version wallet)" ;;
    uncle)  APP_VER="$(app_version uncle)" ;;
    *) printf 'FAIL: unknown mode "%s" (use: retail | uncle)\n' "$MODE" >&2; exit 1 ;;
esac
[ -n "$APP_VER" ] || { printf 'FAIL: VERSION.toml [app] version for mode "%s" missing\n' "$MODE" >&2; exit 1; }

# Core ELF — the committed, published release artifact, NOT a local
# build output. Linux publishes it under core/artifacts/ per release.
CORE_ELF="$WORKSPACE/core/artifacts/axiom-core.elf"
RUST_LIB="$WORKSPACE/target/release/libaxiom_sdk_ffi.a"

# Reproducible-build path hygiene: the FFI statically links VENDORED openssl (macOS has no
# system openssl; crypto stays crypto-openssl per pgp-envelope). openssl-sys bakes its OUT_DIR
# (= CARGO_TARGET_DIR) as OPENSSLDIR into the lib, which --remap-path-prefix cannot reach.
# Build under a username-free CARGO_TARGET_DIR so no operator name is embedded in the shipped
# binary; the clean lib is copied back to target/release/ that Package.swift + uniffi link from.
export CARGO_TARGET_DIR="${AXIOM_FFI_TARGET_DIR:-/tmp/axiom-build}"
# Same hygiene for the Swift side: SwiftPM bakes its .build path into the app binary as a
# resource-bundle fallback (never used once the bundle is inside the .app). Relocate it to a
# username-free scratch dir so that fallback carries no operator name either.
SWIFT_SCRATCH_BASE="${AXIOM_SWIFT_SCRATCH:-/tmp/axiom-swift-build}"

bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*" >&2; }

# Reproducible-build guard: refuse to package an .app that embeds the
# builder's identity ANYWHERE — binary, resources, or plists. The
# --remap-path-prefix + CARGO_TARGET_DIR + swift --scratch-path hygiene
# above scrubs the known leaks (openssl OUT_DIR, SwiftPM .build, a doc
# string — three found by hand 2026-07-10); this scans every file in the
# finished bundle for the builder username (which catches `/Users/<user>`,
# `/home/<user>`, `<user>@…`, and a bare mention) so a NEW leak FAILS the
# build instead of silently shipping an operator name. Runs on every app,
# every build.
assert_no_identity() {
    local bundle="$1" who n f m
    who="$(whoami)"
    n=0
    while IFS= read -r f; do
        # `|| true` — under `set -euo pipefail` a no-match grep exits 1 and
        # pipefail+errexit would abort the build on the first CLEAN file.
        m="$(LC_ALL=C strings -a "$f" 2>/dev/null | grep -Fi "$who" | sort -u | head -3 || true)"
        if [ -n "$m" ]; then
            red "IDENTITY-LEAK GUARD: $(basename "$bundle") embeds '$who' in $f"
            printf '%s\n' "$m" | sed 's/^/       /' >&2
            n=$((n + 1))
        fi
    done < <(find "$bundle" -type f)
    if [ "$n" -ne 0 ]; then
        red "Refusing to package — extend the CARGO_TARGET_DIR / swift"
        red "--scratch-path / --remap-path-prefix hygiene to cover it."
        exit 1
    fi
    green "    identity-clean: $(basename "$bundle") carries no '$who'"
}

# ── pre-flight ─────────────────────────────────────────────
if [ ! -f "$CORE_ELF" ]; then
    red "Missing published Core ELF: $CORE_ELF"
    red "It is the committed release artifact — pull latest master to get it."
    exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# ── (0) Canonical CoreID ───────────────────────────────────
# Hash the bundled ELF NOW and bake the hex into the wallet binary
# via `AXIOM_CANONICAL_CORE_ID`. At runtime, `axiom_sdk::setup()`
# refuses to start if the loaded ELF's BLAKE3 doesn't match — closes
# the "someone swapped the bundled ELF post-ship" attack and
# surfaces a single, clear error instead of a downstream
# `CoreIdMismatch` validator reject.
#
# `core/logic/build.rs` registers `cargo:rerun-if-env-changed=
# AXIOM_CANONICAL_CORE_ID`, so changing this value invalidates the
# `axiom-core-logic` build cache and the `option_env!` constant
# refreshes — no manual `cargo clean` needed.
bold "==> computing canonical CoreID for $CORE_ELF"
CANONICAL_CORE_ID="$(cd "$WORKSPACE" && cargo run -q -p axiom-core-logic \
    --example compute_core_id -- "$CORE_ELF" 2>/dev/null)"
if [ -z "$CANONICAL_CORE_ID" ]; then
    red "Could not compute canonical CoreID from $CORE_ELF"
    red "Try: cargo run -p axiom-core-logic --example compute_core_id -- $CORE_ELF"
    exit 1
fi
export AXIOM_CANONICAL_CORE_ID="$CANONICAL_CORE_ID"
green "    canonical CoreID: $CANONICAL_CORE_ID"

# ── Pinned-client DMG name — name-<coreid>-<version> (see VERSION.toml) ──
# Wallet + UNCLE SAM are PINNED clients: their identity carries the bundled
# CoreID. The 8-hex CoreID prefix in the name makes a Core mismatch obvious
# before install (e.g. axiomwallet-8e5da769-... only talks to an 8e5da769 env).
COREID8="${CANONICAL_CORE_ID:0:8}"
case "$MODE" in
    retail) DMG_NAME="axiomwallet-$COREID8-$APP_VER.dmg"; VOL_NAME="AxiomWallet $APP_VER ($COREID8)" ;;
    uncle)  DMG_NAME="unclesam-$COREID8-$APP_VER.dmg";    VOL_NAME="UNCLE SAM $APP_VER ($COREID8)" ;;
esac
green "    artifact: ${DMG_NAME%.dmg}"

# ── (1) Rust SDK FFI static lib ────────────────────────────
# RELEASE build → the `chaos` fault-injection feature is DELIBERATELY OMITTED
# so the shipped wallet binary physically cannot honor AXIOM_CHAOS_* /
# AXIOM_OODS_INJECT env vars (the hooks are #[cfg(feature = "chaos")] and are
# compiled out — verified: 0 chaos strings in the default binary). DO NOT add
# `--features chaos` here. The Swift fault-injection UI is separately gated by
# #if DEBUG, and this script builds `swift build -c release` (no DEBUG), so the
# UI is absent too. Dev builds (build.sh / build-dev-app.sh) enable both.
bold "==> cargo build -p axiom-sdk-ffi --release  (CARGO_TARGET_DIR=$CARGO_TARGET_DIR)"
cd "$WORKSPACE"
cargo build -p axiom-sdk-ffi --release
# Copy the username-free lib into the workspace target/ that Package.swift + uniffi link from.
# (All cargo output went to CARGO_TARGET_DIR, so nothing else writes target/release — the copy
# is authoritative.)
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
    local product_name="$app_name"
    local app_bundle="$STAGE_DIR/$product_name.app"
    local contents="$app_bundle/Contents"

    bold "==> swift build $app_name (release)"
    cd "$app_dir"

    # Regenerate uniffi bindings for the SDK-linked apps (Wallet +
    # UNCLE SAM). Kiddo has no FFI dep. The bindings land in each app's
    # own Generated/ dir ($app_dir-relative), so the same block works
    # for both.
    if [ "$app_name" = "AxiomWallet" ] || [ "$app_name" = "UNCLESam" ]; then
        local raw="$app_dir/Generated/.raw"
        local sdk="$app_dir/Generated/AxiomSdk"
        local ffi="$app_dir/Generated/AxiomSdkFFI"
        mkdir -p "$raw" "$sdk" "$ffi"
        cd "$WORKSPACE"
        cargo run -p axiom-sdk-ffi --release --bin uniffi-bindgen -- \
            generate --library "$RUST_LIB" \
            --language swift --out-dir "$raw"
        cp "$raw/axiom_sdk_ffi.swift" "$sdk/"
        cp "$raw/axiom_sdk_ffiFFI.h"  "$ffi/"
        cp "$raw/axiom_sdk_ffiFFI.modulemap" "$ffi/module.modulemap"
        cd "$app_dir"
    fi

    swift build -c release --scratch-path "$SWIFT_SCRATCH_BASE/$app_name" --product "$app_name"

    local built_binary
    built_binary="$(swift build -c release --scratch-path "$SWIFT_SCRATCH_BASE/$app_name" --product "$app_name" --show-bin-path)/$app_name"
    if [ ! -f "$built_binary" ]; then
        red "swift build did not produce $built_binary"
        exit 1
    fi

    bold "==> assembling $product_name.app"
    rm -rf "$app_bundle"
    mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/_CodeSignature"

    cp "$app_dir/Info.plist" "$contents/Info.plist"
    # Weld CFBundleShortVersionString from VERSION.toml — the single source of
    # truth — so it can NEVER drift from the DMG name / releases.json version.
    # The in-app update checker (ReleaseUpdate.swift) reads this exact key and
    # compares it to the manifest's `version`; a stale Info.plist value makes a
    # current build report an old version and prompt "update available" forever
    # (bug: published 2.16.6 shipped Info.plist 2.16.5). Per-app, NOT the top
    # APP_VER, so Kiddo keeps its own version inside the retail DMG.
    local plist_ver
    case "$app_name" in
        AxiomWallet) plist_ver="$(app_version wallet)" ;;
        AxiomKiddo)  plist_ver="$(app_version kiddo)" ;;
        UNCLESam)    plist_ver="$(app_version uncle)" ;;
        *)           plist_ver="$APP_VER" ;;
    esac
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $plist_ver" "$contents/Info.plist"
    green "    Info.plist CFBundleShortVersionString = $plist_ver"
    cp "$built_binary" "$contents/MacOS/$app_name"
    chmod +x "$contents/MacOS/$app_name"

    # Resources go directly into `Contents/Resources/` (Apple
    # convention). The Swift code reads them via `Bundle.main.url(
    # forResource:withExtension:)`, NOT `Bundle.module` — the latter
    # expects a `<App>.app/<name>.bundle/` wrapper at the .app root,
    # which violates codesign's "everything under Contents/" rule.
    # `.lproj` localization dirs are picked up automatically by
    # Foundation when they live in `Contents/Resources/`.
    local resource_bundle
    resource_bundle="$(dirname "$built_binary")/${app_name}_${app_name}.bundle"
    if [ -d "$resource_bundle" ]; then
        # Copy the bundle's CONTENTS (one level in) into Contents/Resources,
        # flattening the `.bundle` wrapper. en.lproj / ja.lproj /
        # validators.list.default / etc. end up directly under Resources/.
        cp -R "$resource_bundle/" "$contents/Resources/"
    fi

    # Bundle the Core ELF directly under Contents/Resources/ as
    # axiom-core.elf so AxiomWalletApp.exportBundledElfPath() —
    # `Bundle.main.url(forResource:"axiom-core", withExtension:"elf")` —
    # finds it and sets AXIOM_CORE_ELF. The names MUST match (see the
    # load-bearing comment there). Both SDK-linked apps need it (Wallet +
    # UNCLE SAM via SdkBootstrap.swift); Kiddo doesn't touch the SDK.
    if [ "$app_name" = "AxiomWallet" ] || [ "$app_name" = "UNCLESam" ]; then
        cp "$CORE_ELF" "$contents/Resources/axiom-core.elf"
    fi

    # App icon — Info.plist's CFBundleIconFile=AppIcon resolves to
    # Contents/Resources/AppIcon.icns (the bundle root, NOT inside
    # the SwiftPM resource sub-bundle). Sourced from
    # Sources/<App>/Resources/AppIcon.icns where make-icons.sh wrote it.
    local icns_src="$app_dir/Sources/$app_name/Resources/AppIcon.icns"
    if [ -f "$icns_src" ]; then
        cp "$icns_src" "$contents/Resources/AppIcon.icns"
    else
        echo "  (note: no $icns_src — run apps/macos/make-icons.sh first)" >&2
    fi

    # Prefer a STABLE signing identity over ad-hoc so the Keychain grant for
    # the wallet at-rest key persists across builds (ad-hoc's per-build
    # signature churn makes the Keychain re-prompt every launch). A real Apple
    # Developer ID is best for a shipped DMG (also notarizable); the local
    # self-signed "AXIØM TrustMesh Project" (make-dev-signing-cert.sh) is the fallback.
    # Ad-hoc only if neither is present.
    # Sign by the identity's SHA-1 HASH (encoding-proof; codesign's by-NAME match
    # mis-handles the non-ASCII Ø in the CN).
    local sign_id="${AXIOM_CODESIGN_IDENTITY:-AXIØM TrustMesh Project}"
    local sign_hash
    sign_hash="$(security find-identity -p codesigning 2>/dev/null | grep -F "$sign_id" | head -1 | awk '{print $2}')"
    if [ -n "$sign_hash" ]; then
        bold "==> codesign $product_name.app  ($sign_id — stable identity)"
        codesign --force --deep --sign "$sign_hash" "$app_bundle"
    else
        bold "==> ad-hoc codesign $product_name.app"
        codesign --force --deep --sign - "$app_bundle"
    fi
    codesign --verify --deep "$app_bundle"
    # Identity-leak gate — the finished, signed bundle must carry no
    # operator name anywhere. Fails the build if it does.
    assert_no_identity "$app_bundle"
    green "    built: $app_bundle"
}

# ── Seed defaults ─────────────────────────────────────────
# Copy src/seeds/ into the wallet's bundled resource slot. The
# *.list.default files are generated build artifacts (gitignored);
# src/seeds/ is the single tracked source.
bold "==> bundling seed defaults from src/seeds/"
bash "$SCRIPT_DIR/sync-seed-defaults.sh"

if [ "$MODE" = "retail" ]; then
    build_app AxiomWallet
    build_app AxiomKiddo
else
    build_app UNCLESam
fi

# ── (4) Stage DMG contents ────────────────────────────────
bold "==> staging DMG contents"
ln -sfn /Applications "$STAGE_DIR/Applications"
cp "$WORKSPACE/LICENSE" "$STAGE_DIR/LICENSE"

if [ "$MODE" = "retail" ]; then
cat > "$STAGE_DIR/README.txt" <<EOF
AxiomWallet (axiomwallet-$COREID8-$APP_VER) + AxiomKiddo
=====================================================

WHAT THIS IS
  AxiomWallet.app  — the wallet UI.
  AxiomKiddo.app   — the mail-shaped gateway (SMTP outbound, POP3 inbound)
                     that connects the wallet to your AXIOM env.

INSTALL
  Drag both apps to the Applications folder.

FIRST LAUNCH (IMPORTANT)
  This release is UNSIGNED. macOS Gatekeeper will refuse to open it on a
  double-click and offer to "move to bin". Don't.

  Right-click each .app  →  Open  →  click "Open" in the dialog.
  You only need to do this once per app. After that, normal launch works.

WHAT THESE APPS WILL CREATE
  ~/Library/Application Support/Axiom/
      axiom.conf             ← SDK config + Kiddo's SMTP/POP3 defaults
      validators.list        ← validator email hints
      nabla-nodes.list       ← Nabla node host:port hints
      wallets/               ← per-pair wallet directories
  ~/Library/Application Support/AxiomKiddo/
      accounts.json          ← Kiddo's mail-account config

  Hint files are seeded with the dev-env defaults on first launch
  (axiom-dev.mooo.com). Edit them to point at your own AXIOM env.

DISCLAIMER (PLEASE READ)
  This software is in alpha. Lost wallet keys = lost funds, with no
  recovery path. Do not use with funds you cannot afford to lose.

  This binary is provided AS IS, with no warranty. The AXIOM Origin
  Validator is a network role in the protocol; it does not endorse,
  audit, or guarantee any binary build, including this one.

  The source is published under the GNU General Public License v3.
  If you want a binary you trust, clone the repo and build it yourself.

VERIFY
  Compare the SHA256 of this DMG against the value published in the
  GitHub release notes:
      shasum -a 256 $DMG_NAME
EOF
else
cat > "$STAGE_DIR/README.txt" <<EOF
UNCLE SAM (unclesam-$COREID8-$APP_VER) — institutional SWIFT-AXIOM gateway
=====================================================

WHAT THIS IS
  UNCLESam.app — the bank / institutional client. Composes SWIFT-aligned
  messages (pacs.008 ISO 20022 / MT103 FIN) bridged to AXIOM settlement,
  parses inbound SWIFT back into AXIOM wires, runs the UNCLE TCP carrier,
  and keeps an audit-grade record. k=5 security tier only.

INSTALL
  Drag UNCLESam.app to the Applications folder.

FIRST LAUNCH (IMPORTANT)
  This release is UNSIGNED. macOS Gatekeeper will refuse a double-click.
  Right-click UNCLESam.app -> Open -> click "Open". Once only; normal
  launch works after.

WHAT IT CREATES
  ~/Library/Application Support/UNCLESam/   (operator accounts, audit DB)
  Hint files seed from the dev-env defaults; edit to point at your env.

DISCLAIMER (PLEASE READ)
  Alpha software, provided AS IS, with no warranty. Lost keys = lost
  funds, no recovery. The AXIOM Origin Validator is a network role; it
  does not endorse, audit, or guarantee any binary build, including this
  one. Source is GPLv3 — build it yourself if you want a binary you trust.

VERIFY
  shasum -a 256 $DMG_NAME
EOF
fi

# ── (5) Build the DMG ────────────────────────────────────
bold "==> hdiutil create $DMG_NAME"
rm -f "$DIST_DIR/$DMG_NAME"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov -format UDZO \
    "$DIST_DIR/$DMG_NAME"

# Ad-hoc sign the DMG too so Gatekeeper can at least check the file is
# untampered between download and open.
codesign --force --sign - "$DIST_DIR/$DMG_NAME" || true

# ── (6) Final report ─────────────────────────────────────
SHA="$(shasum -a 256 "$DIST_DIR/$DMG_NAME" | awk '{print $1}')"
SIZE="$(du -h "$DIST_DIR/$DMG_NAME" | awk '{print $1}')"

# ── (6a) Release-manifest fragment (in-app update checker) ──
# The wallet / UNCLE SAM in-app update checker (ReleaseUpdate.swift)
# reads a merged `releases.json` from axiom-dist and compares its
# core_id against the running build's canonical CoreID: same CoreID =>
# optional update, different CoreID => mandatory (Same-Core invariant —
# the old client is rejected at the CoreID gate). This build already
# knows every field except the final GitHub asset URL (the box sets
# that when it uploads), so emit a per-product fragment the publish
# step merges into releases.json. Zero manual upkeep — a build byproduct.
case "$MODE" in
    retail) PRODUCT="axiomwallet" ;;
    uncle)  PRODUCT="unclesam" ;;
esac
FRAGMENT="$DIST_DIR/$PRODUCT.release.json"
cat > "$FRAGMENT" <<JSON
{
  "version": "$APP_VER",
  "core_id": "$CANONICAL_CORE_ID",
  "dmg": "$DMG_NAME",
  "sha256": "$SHA",
  "url": null,
  "notes_url": null
}
JSON

green ""
green "Done."
green "  $DIST_DIR/$DMG_NAME"
green "  size:    $SIZE"
green "  sha256:  $SHA"
green "  core-id: $CANONICAL_CORE_ID"
green "  manifest: $FRAGMENT (merge into axiom-dist/releases.json on publish; set url)"
green ""
green "Publish the sha256 + core-id in the GitHub release notes so users"
green "can verify both the .dmg AND the Core ELF they end up running."
