#!/usr/bin/env bash
# make-icons.sh — Generate AppIcon.icns for AxiomWallet + AxiomKiddo from the
# official AXIOM seal artwork.
#
# Design: white seal centered on a coloured square. Two backgrounds so the
# two apps are visually distinct at a glance in /Applications + Dock:
#
#   AxiomWallet — deep navy   (#0F1B2D), reads as "vault/wallet"
#   AxiomKiddo  — amber/burnt (#C77D2A), reads as "transit/mail"
#
# Source: assets/AXIOM_Official_Logo_Package_v2/02_PNG/AXIOM-Seal-Approved-White-2048.png
# Output: apps/macos/<App>/Sources/<App>/Resources/AppIcon.icns
#         (so SwiftPM's `.process("Resources")` rule ships it inside the .app)
#
# Re-run anytime the source artwork or background colours change.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEAL="$WORKSPACE/assets/AXIOM_Official_Logo_Package_v2/02_PNG/AXIOM-Seal-Approved-White-2048.png"

if [ ! -f "$SEAL" ]; then
    echo "ERROR: source seal not found at $SEAL" >&2
    exit 1
fi

# Inner-seal sizing: leave ~12% padding around the seal at every size so the
# resulting icon doesn't crowd the canvas. The seal is portrait (2:3), so we
# size by max-dim and pad both axes to a square.
INNER_MAX=1648    # ≈ 80% of 2048
CANVAS=2048

# ── Per-app generator ─────────────────────────────────────────────────────
make_iconset() {
    local app_name="$1"        # AxiomWallet | AxiomKiddo
    local bg_color="$2"        # 6-digit hex, no #
    local out_dir
    out_dir="$SCRIPT_DIR/$app_name/Sources/$app_name/Resources"
    local iconset_dir
    iconset_dir="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$iconset_dir" "$out_dir"

    echo "==> $app_name : building master ${CANVAS}×${CANVAS} (bg #$bg_color)"

    # Step 1: resize seal to fit + pad to square with the background colour.
    # sips's -Z is "max dimension, preserve aspect"; --padToHeightWidth then
    # adds the coloured border to make it square. Two passes because sips
    # can't do both in one go reliably.
    local master="$iconset_dir/master.png"
    local resized="$iconset_dir/resized.png"
    sips -Z $INNER_MAX "$SEAL" --out "$resized" >/dev/null
    sips -p $CANVAS $CANVAS --padColor "$bg_color" "$resized" --out "$master" >/dev/null
    rm -f "$resized"

    # Step 2: macOS icon set — 10 entries, 5 logical sizes × @1x + @2x.
    # Naming + sizes match what `iconutil --convert icns` expects exactly.
    echo "==> $app_name : generating iconset sizes"
    local sizes=(
        "16:icon_16x16.png"
        "32:icon_16x16@2x.png"
        "32:icon_32x32.png"
        "64:icon_32x32@2x.png"
        "128:icon_128x128.png"
        "256:icon_128x128@2x.png"
        "256:icon_256x256.png"
        "512:icon_256x256@2x.png"
        "512:icon_512x512.png"
        "1024:icon_512x512@2x.png"
    )
    for entry in "${sizes[@]}"; do
        local size="${entry%%:*}"
        local name="${entry##*:}"
        sips -z $size $size "$master" --out "$iconset_dir/$name" >/dev/null
    done
    rm -f "$master"

    # Step 3: pack iconset → .icns. iconutil is part of Xcode CLT.
    iconutil --convert icns "$iconset_dir" --output "$out_dir/AppIcon.icns"
    echo "    wrote $out_dir/AppIcon.icns ($(du -h "$out_dir/AppIcon.icns" | awk '{print $1}'))"
}

make_iconset AxiomWallet 0F1B2D    # deep navy — wallet/vault
make_iconset AxiomKiddo  C77D2A    # amber — mail/transit
make_iconset UNCLESam    5C1A1A    # deep burgundy — institutional/banking

echo
echo "Done. All three AppIcon.icns generated. Rebuild the apps to ship the new icons:"
echo "    bash $SCRIPT_DIR/release-dmg.sh        # AxiomWallet + AxiomKiddo DMG"
echo "    bash $SCRIPT_DIR/UNCLESam/build-dev-app.sh  # UNCLE SAM .app"
