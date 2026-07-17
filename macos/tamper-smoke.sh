#!/usr/bin/env bash
# tamper-smoke.sh — verify the canonical-CoreID gate end-to-end.
#
# Steps:
#   (1) build a release DMG (or use an existing one)
#   (2) compute its canonical CoreID from the bundled ELF
#   (3) rebuild libaxiom_sdk_ffi.a with that canonical baked in
#   (4) run SmokeTest against the pristine bundled ELF — must NOT exit 2
#   (5) overwrite the bundled ELF with random bytes
#   (6) run SmokeTest again — MUST exit 2 with "Core ELF mismatch"
#
# Sole input: the SDK refuses to start when the loaded ELF's BLAKE3
# doesn't match the constant baked into the binary. The test asserts
# that property is wired through the full release pipeline (build
# script → option_env! → setup() → wallet refuses).
#
# Run from anywhere — paths resolve via SCRIPT_DIR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"
# Target the wallet DMG by its self-identity (no umbrella `release` key),
# mirroring release-dmg.sh: axiomwallet-<coreid8>-<[app].wallet>.dmg.
VERSION="$(sed -n '/^\[app\]/,/^\[/p' "$WORKSPACE/VERSION.toml" \
           | grep -E '^wallet[[:space:]]*=' | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
[ -n "$VERSION" ] || { printf 'FAIL: no [app].wallet in %s\n' \
    "$WORKSPACE/VERSION.toml" >&2; exit 1; }
COREID8="$(tr -d '[:space:]' < "$WORKSPACE/core/artifacts/CORE_ID.txt" 2>/dev/null | cut -c1-8)"
[ -n "$COREID8" ] || { printf 'FAIL: core/artifacts/CORE_ID.txt missing\n' >&2; exit 1; }
DMG="$DIST_DIR/axiomwallet-$COREID8-$VERSION.dmg"
MOUNT="/tmp/axiom-tamper-mount"
APP_TMP="/tmp/axiom-tamper-app"
WALLET_PKG="$SCRIPT_DIR/AxiomWallet"

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*" >&2; }

cleanup() {
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
    rm -rf "$APP_TMP"
}
trap cleanup EXIT

# ── (1) DMG ────────────────────────────────────────────────
if [ ! -f "$DMG" ]; then
    bold "==> $DMG not found — running release-dmg.sh"
    bash "$SCRIPT_DIR/release-dmg.sh"
fi

# Mount fresh.
hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -nobrowse -mountpoint "$MOUNT" >/dev/null

# Copy .app to a writable scratch dir (DMG is read-only).
rm -rf "$APP_TMP"
mkdir -p "$APP_TMP"
cp -R "$MOUNT/AxiomWallet.app" "$APP_TMP/"
BUNDLED_ELF="$APP_TMP/AxiomWallet.app/Contents/Resources/axiom-core.elf"

# ── (2) Canonical from the pristine ELF ────────────────────
bold "==> computing canonical CoreID"
CANONICAL="$(cd "$WORKSPACE" && cargo run -q -p axiom-core-logic \
    --example compute_core_id -- "$BUNDLED_ELF" 2>/dev/null)"
if [ -z "$CANONICAL" ]; then
    red "could not compute canonical"
    exit 1
fi
echo "    $CANONICAL"

# ── (3) Rebuild SDK FFI with canonical baked in ────────────
# build.rs's rerun-if-env-changed=AXIOM_CANONICAL_CORE_ID makes this
# a no-op when nothing changed; it's here so the test is self-contained.
bold "==> rebuilding sdk-ffi with canonical baked"
( cd "$WORKSPACE" && \
  AXIOM_CANONICAL_CORE_ID="$CANONICAL" \
  cargo build -q -p axiom-sdk-ffi --release )

# ── (4) Pristine smoke ────────────────────────────────────
bold "==> (4) smoke against pristine ELF — expect setup OK"
PRISTINE_RC=0
cd "$WALLET_PKG"
AXIOM_CORE_ELF="$BUNDLED_ELF" \
    swift run -c release SmokeTest 2>&1 | sed 's/^/      /' || PRISTINE_RC=$?

if [ "$PRISTINE_RC" -eq 2 ]; then
    red "FAIL: setup rejected the pristine ELF (exit 2)"
    exit 1
fi
# exit 1 is OK — means setup passed but a later wallet step missed
# (wallet directory probably absent). That's not what we're testing.
green "    setup OK on pristine ELF (rc=$PRISTINE_RC)"

# ── (5) Tamper ────────────────────────────────────────────
bold "==> (5) tampering bundled ELF"
dd if=/dev/urandom of="$BUNDLED_ELF" bs=1024 count=128 conv=notrunc 2>/dev/null
echo "    ELF now hashes to:"
TAMPERED_HASH="$(cd "$WORKSPACE" && cargo run -q -p axiom-core-logic \
    --example compute_core_id -- "$BUNDLED_ELF" 2>/dev/null)"
echo "      $TAMPERED_HASH (vs canonical $CANONICAL)"

# ── (6) Tampered smoke — must exit 2 ──────────────────────
bold "==> (6) smoke against tampered ELF — expect setup FAIL exit 2"
TAMPERED_RC=0
cd "$WALLET_PKG"
AXIOM_CORE_ELF="$BUNDLED_ELF" \
    swift run -c release SmokeTest 2>&1 | sed 's/^/      /' || TAMPERED_RC=$?

if [ "$TAMPERED_RC" -ne 2 ]; then
    red "FAIL: tampered ELF did NOT trigger the canonical gate (got rc=$TAMPERED_RC, wanted 2)"
    exit 1
fi
green "    canonical gate caught tampered ELF (exit 2)"

bold ""
green "==> tamper smoke PASSED"
green "    canonical CoreID gate works end-to-end through the release pipeline"
