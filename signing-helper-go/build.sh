#!/bin/bash
# Build a universal macOS binary for light3-sign and install it into the plugin.
# Usage: bash build.sh [--install]

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/../light3.lrplugin"
MODULES_DIR="$HOME/Library/Application Support/Adobe/Lightroom/Modules/light3.lrplugin"
DIST="$SCRIPT_DIR/dist"

mkdir -p "$DIST"

cd "$SCRIPT_DIR"

echo "Building arm64..."
GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o "$DIST/light3-sign-arm64" .

echo "Building x64..."
GOOS=darwin GOARCH=amd64 go build -ldflags="-s -w" -o "$DIST/light3-sign-x64" .

echo "Creating universal binary..."
lipo -create -output "$DIST/light3-sign" "$DIST/light3-sign-arm64" "$DIST/light3-sign-x64"
chmod +x "$DIST/light3-sign"

SIZE=$(du -sh "$DIST/light3-sign" | cut -f1)
echo "Built $DIST/light3-sign ($SIZE)"

if [[ "$1" == "--install" ]]; then
  cp "$DIST/light3-sign" "$PLUGIN_DIR/light3-sign"
  echo "Installed → $PLUGIN_DIR/light3-sign"
  cp "$DIST/light3-sign" "$MODULES_DIR/light3-sign"
  echo "Installed → $MODULES_DIR/light3-sign"
fi
