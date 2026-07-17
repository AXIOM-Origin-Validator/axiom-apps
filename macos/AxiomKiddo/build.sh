#!/usr/bin/env bash
# AxiomKiddo build script. Pure Swift, no FFI — `swift build` is the
# whole story.

set -euo pipefail
cd "$(dirname "$0")"
swift build "$@"
echo "==> Done. Run with: swift run AxiomKiddo (or open this directory in Xcode)"
