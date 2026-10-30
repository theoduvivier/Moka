#!/bin/zsh
# Build/verify first; this script never publishes or changes Gatekeeper.
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
DESTINATION="${1:-$PROJECT_DIR/build/release}"
mkdir -p "$DESTINATION"
STAGING_DIR="$(mktemp -d /private/tmp/moka-release.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT
if [[ -n "${MOKA_SIGN_IDENTITY:-}" ]]; then
  "$PROJECT_DIR/distribute.sh" "$DESTINATION"
else
  "$PROJECT_DIR/build.sh" "$STAGING_DIR/Moka.app"
  /usr/bin/codesign --verify --deep --strict "$STAGING_DIR/Moka.app"
  /usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$STAGING_DIR/Moka.app" "$DESTINATION/Moka-macOS.zip"
fi
/usr/bin/ditto -x -k "$DESTINATION/Moka-macOS.zip" "$STAGING_DIR/verify"
/usr/bin/codesign --verify --deep --strict "$STAGING_DIR/verify/Moka.app"
(cd "$DESTINATION" && /usr/bin/shasum -a 256 Moka-macOS.zip > Moka-macOS.zip.sha256)
python3 "$PROJECT_DIR/Tools/make-appcast.py" "$DESTINATION/Moka-macOS.zip" "$DESTINATION/appcast.xml"
print 'Verified release ready:' "$DESTINATION"
