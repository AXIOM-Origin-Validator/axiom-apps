#!/usr/bin/env bash
# AxiomWallet build orchestration.
#
#   1. Build the Rust SDK FFI as a release static library.
#   2. Regenerate Swift bindings into Generated/.
#   3. Reshape Generated/ into the layout SwiftPM's systemLibrary
#      target expects (module.modulemap at the target root, not
#      axiom_sdk_ffiFFI.modulemap as uniffi-bindgen names it).
#   4. Build the SwiftUI app via swift build.
#
# Run from this directory: ./build.sh
# Or open the directory in Xcode (it autodetects the Package.swift).
# Either way, the Rust side must be built first because the Swift
# package links against target/release/libaxiom_sdk_ffi.a.

set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$PACKAGE_ROOT/../../.." && pwd)"
RAW_DIR="$PACKAGE_ROOT/Generated/.raw"
SDK_DIR="$PACKAGE_ROOT/Generated/AxiomSdk"
FFI_DIR="$PACKAGE_ROOT/Generated/AxiomSdkFFI"

cd "$WORKSPACE_ROOT"

# Path hygiene (matches release-dmg.sh): build under a username-free CARGO_TARGET_DIR so the
# vendored-openssl OUT_DIR baked as OPENSSLDIR carries no operator name; copy the clean lib
# back to target/release/ (Package.swift links from there).
export CARGO_TARGET_DIR="${AXIOM_FFI_TARGET_DIR:-/tmp/axiom-build}"

# DEV build → enable the fault-injection hooks (`chaos` feature). The
# release DMG (release-dmg.sh) omits it, so the shipped binary can't honor
# AXIOM_CHAOS_* env vars. The bindgen run below MUST carry the same feature
# or cargo rebuilds the lib WITHOUT chaos and overwrites the artifact the
# app links. (Swift-side fault UI is gated by #if DEBUG, which aligns.)
echo "==> Building Rust SDK FFI (release + chaos hooks for dev)..."
cargo build -p axiom-sdk-ffi --release --features chaos
mkdir -p "$WORKSPACE_ROOT/target/release"
cp -f "$CARGO_TARGET_DIR/release/libaxiom_sdk_ffi.a" \
      "$CARGO_TARGET_DIR/release/libaxiom_sdk_ffi.dylib" "$WORKSPACE_ROOT/target/release/"

echo "==> Regenerating Swift bindings..."
mkdir -p "$RAW_DIR"
cargo run -p axiom-sdk-ffi --release --features chaos --bin uniffi-bindgen -- \
    generate \
    --library "$WORKSPACE_ROOT/target/release/libaxiom_sdk_ffi.dylib" \
    --language swift \
    --out-dir "$RAW_DIR"

echo "==> Reshaping for SwiftPM..."
mkdir -p "$SDK_DIR" "$FFI_DIR"
cp "$RAW_DIR/axiom_sdk_ffi.swift" "$SDK_DIR/"
cp "$RAW_DIR/axiom_sdk_ffiFFI.h"  "$FFI_DIR/"
# SwiftPM systemLibrary expects module.modulemap at the target root.
cp "$RAW_DIR/axiom_sdk_ffiFFI.modulemap" "$FFI_DIR/module.modulemap"

echo "==> Bundling seed defaults from src/seeds/..."
bash "$PACKAGE_ROOT/../sync-seed-defaults.sh"

echo "==> Building SwiftUI app..."
cd "$PACKAGE_ROOT"
swift build

echo "==> Done. Run with: swift run (or open in Xcode)"
