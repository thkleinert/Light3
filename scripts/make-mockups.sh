#!/bin/bash
# Composite the raw screenshots into MacBook-style frames for the README.
# Re-runnable: overwrites assets/mockups/*.png from assets/screenshots/.
set -e
cd "$(dirname "$0")/.."

W=1440; H=900; B=20; CHIN=42; R=30          # screen, bezel, chin, corner radius
LIDW=$((W + 2*B)); LIDH=$((H + B + CHIN))
BASEW=$((LIDW + 150)); BASEH=26

frame() {
  local src="$1" out="$2" tmp; tmp=$(mktemp -d)

  # Fill the 16:10 screen, anchored top so window chrome is never cropped away.
  magick "$src" -resize "${W}x${H}^" -gravity north -extent "${W}x${H}" "$tmp/screen.png"

  # Lid: rounded slab, screen inset, camera dot centred in the top bezel.
  magick -size "${LIDW}x${LIDH}" xc:none \
    -fill '#1c1c1e' -draw "roundrectangle 0,0 $((LIDW-1)),$((LIDH-1)) $R,$R" \
    "$tmp/screen.png" -geometry "+${B}+${B}" -composite \
    -fill '#3f3f43' -draw "circle $((LIDW/2)),$((B/2)) $((LIDW/2+3)),$((B/2))" \
    "$tmp/lid.png"

  # Base: aluminium bar with the thumb notch.
  magick -size "${BASEW}x${BASEH}" xc:none \
    -fill '#c9ced6' -draw "roundrectangle 0,0 $((BASEW-1)),$((BASEH-1)) 9,9" \
    -fill '#aab0ba' -draw "roundrectangle $((BASEW/2-70)),0 $((BASEW/2+70)),7 4,4" \
    "$tmp/base.png"

  magick -size "${BASEW}x$((LIDH + BASEH))" xc:none \
    "$tmp/lid.png"  -gravity north -composite \
    "$tmp/base.png" -gravity south -composite \
    -bordercolor none -border 30 \
    \( +clone -background black -shadow 34x18+0+10 \) +swap -background none -layers merge +repage \
    "$out"
  rm -rf "$tmp"
}

frame assets/screenshots/publish.png             assets/mockups/publish.png
frame assets/screenshots/setup_plugin.png        assets/mockups/setup.png
frame assets/screenshots/find_plugin_manager.png assets/mockups/plugin-manager.png
for f in assets/mockups/*.png; do echo "  $f  $(magick identify -format '%wx%h' "$f")  $(stat -f%z "$f") bytes"; done
