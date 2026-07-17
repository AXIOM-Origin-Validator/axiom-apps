#!/bin/bash
# Build the AXIOM web wallet — produces EVERY distributable in one run:
#
#   pkg/                      web-target wasm (ES modules) — the HTTP build
#   pkg-nomod/                no-modules wasm — feeds the single-file bundle
#   dist/axiom-wallet.html    ONE self-contained file — double-click, no server
#   dist/http/                web/ + pkg/ trimmed, ready to drop on any static host
#
# This is the APP. The wasm it ships is the SDK's binding crate, axiom-sdk-wasm,
# which lives at ../../sdk/wasm — we compile it here but never vendor it. Hand a
# guest `dist/axiom-wallet.html` (double-click) or, if they host their own,
# `dist/http/` (serve it, open web/index.html). No compiling on their end.
#
# Override the build profile with PROFILE=--dev (default --release).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# The SDK binding crate we compile to wasm. The app dir holds only the frontend
# + packaging; the crate is pure SDK and stays under sdk/.
CRATE_DIR="$SCRIPT_DIR/../../sdk/wasm"

PROFILE="${PROFILE:---release}"

ELF_SRC="${AXIOM_CORE_ELF:-$SCRIPT_DIR/../../core/artifacts/axiom-core.elf}"
if [ ! -f "$ELF_SRC" ]; then
    echo "ERROR: canonical Core ELF not found at $ELF_SRC" >&2
    echo "       Pull master to get core/artifacts/, or set AXIOM_CORE_ELF=<path>." >&2
    exit 1
fi
ELF_BYTES="$(wc -c < "$ELF_SRC" | tr -d ' ')"

# ── [0/4] CoreID assert — FAIL CLOSED on an ELF mismatch ─────────────────────
# The webclient is a PINNED client: it bundles + runs the Core ELF, so it MUST
# carry the SAME ELF the validators run (the committed canonical CoreID). A stale
# core/avm-guest/target or a wrong AXIOM_CORE_ELF would otherwise ship a webclient
# NAMED with the right CoreID but BUNDLING the wrong ELF → a WrongCore site where
# users can't transact (this exact regression was caught on the 3.2.2 publish:
# a leftover 07c48766 worldline ELF). Refuse to build on mismatch.
CANON_ID_FILE="$SCRIPT_DIR/../../core/artifacts/CORE_ID.txt"
if [ -f "$CANON_ID_FILE" ]; then
    CANON_ID="$(tr -d '[:space:]' < "$CANON_ID_FILE")"
    SRC_ID="$(cd "$SCRIPT_DIR/../.." && cargo run -q -p axiom-core-logic \
              --example compute_core_id -- "$ELF_SRC" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$SRC_ID" ] || [ "$SRC_ID" != "$CANON_ID" ]; then
        echo "FATAL: webclient ELF CoreID mismatch — would ship the WRONG Core." >&2
        echo "       ELF_SRC    = $ELF_SRC" >&2
        echo "       its CoreID = ${SRC_ID:-<compute_core_id failed>}" >&2
        echo "       canonical  = $CANON_ID  (core/artifacts/CORE_ID.txt)" >&2
        echo "       Fix: unset AXIOM_CORE_ELF (or point it at core/artifacts/axiom-core.elf)." >&2
        exit 1
    fi
    echo "=== [0/4] CoreID assert OK — ELF_SRC == canonical ${CANON_ID:0:16}… ==="
else
    echo "WARN: $CANON_ID_FILE missing — skipping CoreID assert (cannot verify ELF)." >&2
fi

# ── [1/4] Web-target wasm (ES modules) — backs the HTTP build (web/ + pkg/) ──
# Build the sdk/wasm crate, but drop its output (pkg/) into THIS app dir so the
# frontend + pack.py find it as a sibling. --out-dir is absolute, so it lands
# here regardless of where the crate lives.
echo "=== [1/4] wasm-pack (web target) → pkg/ ==="
wasm-pack build "$PROFILE" --target web --out-dir "$SCRIPT_DIR/pkg" --out-name axiom_sdk_wasm "$CRATE_DIR"
cp "$ELF_SRC" pkg/axiom-core.elf

# ── [2/4] no-modules wasm — backs the single-file bundle (global wasm_bindgen) ─
echo "=== [2/4] wasm-pack (no-modules) → pkg-nomod/ ==="
wasm-pack build "$PROFILE" --target no-modules --out-dir "$SCRIPT_DIR/pkg-nomod" --out-name axiom_sdk_wasm "$CRATE_DIR"
cp "$ELF_SRC" pkg-nomod/axiom-core.elf

# ── [3/4] Single self-contained file (double-click, runs from file://) ──
echo "=== [3/4] pack.py → dist/axiom-wallet.html ==="
python3 pack.py

# ── [4/4] HTTP folder — the minimal hostable set, web/ + trimmed pkg/ ──
echo "=== [4/4] assembling dist/http/ ==="
rm -rf dist/http
mkdir -p dist/http/web dist/http/pkg
cp web/index.html web/genesis.js web/transport.js web/kiddo.js web/cl-worker.js web/vault.js web/nacl.min.js dist/http/web/
cp pkg/axiom_sdk_wasm.js pkg/axiom_sdk_wasm_bg.wasm pkg/axiom-core.elf dist/http/pkg/

# ── [5/5] Canonical publish identity — webclient-<coreid>-<version> ──
# The web client is a PINNED client (it bundles + runs the Core ELF), so its
# published identity carries the CoreID — see the VERSION.toml header for the
# rule. CoreID is computed from the actual bundled ELF (same way release-dmg.sh
# does for the wallet); version is the workspace crate version it inherits.
echo "=== [5/5] canonical publish name → dist/webclient-<coreid>-<version>.* ==="
ROOT="$SCRIPT_DIR/../.."
COREID8="$(cd "$ROOT" && cargo run -q -p axiom-core-logic --example compute_core_id -- "$ELF_SRC" 2>/dev/null | cut -c1-8)"
WCVER="$(sed -n '/^\[workspace\]/,/^\[/p' "$ROOT/VERSION.toml" \
         | grep -E '^crate[[:space:]]*=' | head -1 | sed -E 's/.*"([^"]*)".*/\1/')"
if [ -n "$COREID8" ] && [ -n "$WCVER" ]; then
    WC_NAME="webclient-$COREID8-$WCVER"
    cp dist/axiom-wallet.html "dist/$WC_NAME.html"
    ( cd dist && rm -f "$WC_NAME.zip" && zip -qr "$WC_NAME.zip" http )
    echo "    $WC_NAME.html  +  $WC_NAME.zip"
else
    echo "    WARN: could not derive name (CORE_ID compute or VERSION.toml [workspace] crate failed)" >&2
fi

# ── Final bundle-verify — the ACTUAL shipped ELF must match canonical ────────
# Belt-and-suspenders beyond the [0/4] ELF_SRC assert: re-check the ELF that
# actually landed in dist/http/pkg (what the .zip ships) so a stray cp / pack
# step can't slip a wrong ELF past us.
if [ -f "$CANON_ID_FILE" ] && [ -f dist/http/pkg/axiom-core.elf ]; then
    BUNDLE_ID="$(cd "$ROOT" && cargo run -q -p axiom-core-logic --example compute_core_id \
                 -- "$SCRIPT_DIR/dist/http/pkg/axiom-core.elf" 2>/dev/null | tr -d '[:space:]')"
    if [ "$BUNDLE_ID" != "$(tr -d '[:space:]' < "$CANON_ID_FILE")" ]; then
        echo "FATAL: bundled dist/http/pkg/axiom-core.elf CoreID = ${BUNDLE_ID:-<failed>}" >&2
        echo "       != canonical $(tr -d '[:space:]' < "$CANON_ID_FILE") — refusing to ship." >&2
        exit 1
    fi
    echo "    bundle-verify OK — dist/http/pkg ELF == canonical"
fi

echo ""
echo "=== Build complete (Core ELF: $ELF_BYTES bytes) ==="
echo "  • Single file (double-click):  dist/axiom-wallet.html"
echo "  • HTTP folder (host & share):  dist/http/   → serve it, open web/index.html"
echo "  • Publish artifacts:           dist/${WC_NAME:-webclient-...}.html + .zip"
ls -la dist/axiom-wallet.html dist/http/web dist/http/pkg 2>/dev/null || true
