#!/bin/bash
# Creates a shell-script wrapper at light3.lrplugin/light3-sign that invokes
# sign.js directly via node. Use this for local development; for distribution
# run `npm run pkg` to build a self-contained binary.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/../light3.lrplugin"
MODULES_DIR="$HOME/Library/Application Support/Adobe/Lightroom/Modules/light3.lrplugin"

NODE_BIN="$(command -v node)"
if [ -z "$NODE_BIN" ]; then
  echo "Error: node not found in PATH" >&2
  exit 1
fi

WRAPPER=$(cat <<WRAPPER
#!/bin/bash
exec "$NODE_BIN" "$SCRIPT_DIR/sign.js" "\$@"
WRAPPER
)

write_wrapper() {
  echo "$WRAPPER" > "$1/light3-sign"
  chmod +x "$1/light3-sign"
  echo "Wrote $1/light3-sign"
}

write_wrapper "$PLUGIN_DIR"
write_wrapper "$MODULES_DIR"
