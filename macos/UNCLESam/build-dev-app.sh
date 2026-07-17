#!/usr/bin/env bash
# UNCLE SAM dev .app builder — full pipeline with AXIOM-SDK FFI link.
#
# Steps:
#   1. cargo build -p axiom-sdk-ffi (release) — produces the static
#      lib UNCLE SAM links against (same lib AxiomWallet uses).
#   2. Regenerate UniFFI Swift bindings into Generated/.
#   3. Stage resources in Sources/UNCLESam/Resources/:
#        - Core ELF (axiom-core.elf) — needed at runtime for
#          CL1 execution proofs.
#        - validators.list.default, nabla-nodes.list.default —
#          bundled seed lists pointing at the dev env.
#        - axiom.conf.default — bundled default config.
#   4. swift build (debug) — produces the executable + resource bundle.
#   5. Assemble UNCLESam.app, flatten the resource sub-bundle into
#      Contents/Resources/, ad-hoc codesign, install to /Applications,
#      launch.
#
# Run from anywhere — paths resolve via SCRIPT_DIR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist-dev"
STAGE_DIR="$DIST_DIR/.stage"

APP_NAME="UNCLESam"
APP_DIR="$SCRIPT_DIR"
APP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"

CORE_ELF="$WORKSPACE/core/artifacts/axiom-core.elf"
RUST_LIB="$WORKSPACE/target/release/libaxiom_sdk_ffi.a"
RUST_DYLIB="$WORKSPACE/target/release/libaxiom_sdk_ffi.dylib"

RES_DIR="$APP_DIR/Sources/UNCLESam/Resources"

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*" >&2; }

mkdir -p "$DIST_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# ── pre-flight ─────────────────────────────────────────────
if [ ! -f "$CORE_ELF" ]; then
    red "Missing published Core ELF: $CORE_ELF"
    red "Pull latest master — core/artifacts/ is the release artifact."
    exit 1
fi

# ── (1) cargo build the SDK FFI release lib ────────────────
bold "==> cargo build -p axiom-sdk-ffi (release)"
cd "$WORKSPACE"
cargo build -p axiom-sdk-ffi --release

if [ ! -f "$RUST_LIB" ]; then
    red "cargo did not produce $RUST_LIB"
    exit 1
fi

# ── (2) Regenerate UniFFI bindings ─────────────────────────
bold "==> regenerate UniFFI Swift bindings"
RAW="$APP_DIR/Generated/.raw"
SDK="$APP_DIR/Generated/AxiomSdk"
FFI="$APP_DIR/Generated/AxiomSdkFFI"
rm -rf "$APP_DIR/Generated"
mkdir -p "$RAW" "$SDK" "$FFI"
cargo run -p axiom-sdk-ffi --release --bin uniffi-bindgen -- \
    generate --library "$RUST_DYLIB" \
    --language swift --out-dir "$RAW"
cp "$RAW/axiom_sdk_ffi.swift" "$SDK/"
cp "$RAW/axiom_sdk_ffiFFI.h"  "$FFI/"
cp "$RAW/axiom_sdk_ffiFFI.modulemap" "$FFI/module.modulemap"

# ── (3) Stage Resources/ (ELF + seeds) ─────────────────────
bold "==> stage Resources/"
mkdir -p "$RES_DIR"
cp "$CORE_ELF" "$RES_DIR/axiom-core.elf"
cp "$WORKSPACE/seeds/validators.list"  "$RES_DIR/validators.list.default"
cp "$WORKSPACE/seeds/nabla-nodes.list" "$RES_DIR/nabla-nodes.list.default"
# axiom.conf.default — UNCLE SAM borrows AxiomWallet's bundled
# default until it grows its own (the SDK only cares about the
# maildir line + smtp/pop hosts).
cp "$WORKSPACE/apps/macos/AxiomWallet/Sources/AxiomWallet/Resources/axiom.conf.default" \
   "$RES_DIR/axiom.conf.default"
green "    Resources/ contents:"
ls -1 "$RES_DIR" | sed 's/^/      /'

# ── (4) swift build ────────────────────────────────────────
bold "==> swift build $APP_NAME (debug)"
cd "$APP_DIR"
swift build --product "$APP_NAME"

BUILT_BINARY="$(swift build --product "$APP_NAME" --show-bin-path)/$APP_NAME"
if [ ! -f "$BUILT_BINARY" ]; then
    red "swift build did not produce $BUILT_BINARY"
    exit 1
fi

# ── (5) assemble .app ──────────────────────────────────────
bold "==> assemble $APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/_CodeSignature"
cp "$APP_DIR/Info.plist" "$CONTENTS/Info.plist"
cp "$BUILT_BINARY" "$CONTENTS/MacOS/$APP_NAME"
chmod +x "$CONTENTS/MacOS/$APP_NAME"

# Flatten the SwiftPM resource sub-bundle into Contents/Resources/
# (same pattern AxiomWallet uses). Bundle.main.url(forResource:…)
# finds resources directly under Contents/Resources/, not under
# the SwiftPM sub-bundle path.
RESOURCE_BUNDLE="$(dirname "$BUILT_BINARY")/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE/" "$CONTENTS/Resources/"
fi

ICNS_SRC="$APP_DIR/Sources/$APP_NAME/Resources/AppIcon.icns"
if [ -f "$ICNS_SRC" ]; then
    cp "$ICNS_SRC" "$CONTENTS/Resources/AppIcon.icns"
fi

# Stable code-signing identity — same cert as AxiomWallet ("AXIØM TrustMesh
# Project"). A stable cert lets the Keychain "Always Allow" grant persist across
# rebuilds; ad-hoc signing changes the CDHash every build → re-prompt. This is a
# prerequisite for the at-rest Keychain vault (see WalletVault) — without a
# stable identity that vault re-prompts on every launch. Sign by SHA-1 HASH:
# codesign's by-NAME match breaks on the Ø in the identity name.
SIGN_ID="${AXIOM_CODESIGN_IDENTITY:-AXIØM TrustMesh Project}"
SIGN_HASH="$(security find-identity -p codesigning 2>/dev/null | grep -F "$SIGN_ID" | head -1 | awk '{print $2}')"
if [ -n "$SIGN_HASH" ]; then
    bold "==> codesign $APP_NAME.app  ($SIGN_ID — stable identity, Keychain grant persists)"
    codesign --force --deep --sign "$SIGN_HASH" "$APP_BUNDLE"
else
    bold "==> ad-hoc codesign $APP_NAME.app (no stable identity — Keychain re-prompts; run ../make-dev-signing-cert.sh once)"
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null
fi
green "    built: $APP_BUNDLE"

bold "==> killing running $APP_NAME (if any)"
killall "$APP_NAME" 2>/dev/null || true
sleep 1
killall -9 "$APP_NAME" 2>/dev/null || true

bold "==> installing to /Applications"
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" /Applications/
xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true

bold "==> launching"
open "/Applications/$APP_NAME.app"

green ""
green "Done."
green "  /Applications/$APP_NAME.app"
green ""
green "Iterate: edit Swift source, re-run \`bash UNCLESam/build-dev-app.sh\`."
