#!/usr/bin/env bash
# sync-seed-defaults.sh — copy the canonical seed lists into the macApp bundle.
#
# src/seeds/{validators.list,nabla-nodes.list} is the single hand-edited
# seed source (scripts/sync-seeds-to-dist.sh also publishes it to
# axiom-dist). The macApp bundles them as its offline emergency fallback
# at Resources/*.list.default — those are GENERATED build artifacts
# (gitignored), not a separate hand-maintained copy that can drift.
#
# Run as a pre-build step by build.sh and release-dmg.sh, before
# `swift build` processes the Resources directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEEDS_DIR="$WORKSPACE/seeds"

# Both SDK-linked macApps bundle the seed lists as their offline fallback:
# the retail Wallet and the institutional UNCLE SAM. Kiddo has no Nabla
# discovery, so it needs no seeds.
for res in \
    "AxiomWallet/Sources/AxiomWallet/Resources" \
    "UNCLESam/Sources/UNCLESam/Resources" ; do
    RES_DIR="$SCRIPT_DIR/$res"
    app="${res%%/*}"
    if [ ! -d "$RES_DIR" ]; then
        echo "sync-seed-defaults: missing resources dir $RES_DIR" >&2
        exit 1
    fi
    for name in validators.list nabla-nodes.list; do
        src="$SEEDS_DIR/$name"
        dst="$RES_DIR/$name.default"
        if [ ! -f "$src" ]; then
            echo "sync-seed-defaults: missing seed source $src" >&2
            exit 1
        fi
        cp "$src" "$dst"
        echo "  $app: $name.default  <-  seeds/$name"
    done
done
