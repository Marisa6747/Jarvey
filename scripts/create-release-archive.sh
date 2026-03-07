#!/bin/zsh

set -euo pipefail

ROOT_DIR="${1:-$(pwd)}"
APP_DIR="$ROOT_DIR/dist-native/Jarvey.app"
APP_VERSION="${APP_VERSION:-$(node -p "JSON.parse(require('node:fs').readFileSync(process.argv[1], 'utf8')).version" "$ROOT_DIR/package.json")}"
APP_ARCHITECTURE="${APP_ARCHITECTURE:-$(uname -m)}"
ARCHIVE_NAME="Jarvey-${APP_VERSION}-macos-${APP_ARCHITECTURE}.zip"
ARCHIVE_PATH="$ROOT_DIR/dist-native/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing app bundle at $APP_DIR. Run npm run build:native first." >&2
  exit 1
fi

rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"
openssl dgst -sha256 -r "$ARCHIVE_PATH" > "$CHECKSUM_PATH"

echo "$ARCHIVE_PATH"
