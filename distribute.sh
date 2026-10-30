#!/bin/zsh
# This script never removes quarantine or disables Gatekeeper.
set -euo pipefail
PROJECT_DIR="${0:A:h}"
: "${MOKA_SIGN_IDENTITY:?Set MOKA_SIGN_IDENTITY to your Developer ID Application certificate}"
: "${MOKA_NOTARY_PROFILE:?Set MOKA_NOTARY_PROFILE to a notarytool keychain profile}"
[[ "$MOKA_SIGN_IDENTITY" == 'Developer ID Application:'* ]] || { print -u2 'A Developer ID Application identity is required.'; exit 1; }
DESTINATION="${1:-$PROJECT_DIR/build/distribution}"
mkdir -p "$DESTINATION"
STAGING_DIR="$(mktemp -d /private/tmp/moka-distribution.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT
"$PROJECT_DIR/build.sh" "$STAGING_DIR/Moka.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIR/Moka.app" "$STAGING_DIR/submission.zip"
xcrun notarytool submit "$STAGING_DIR/submission.zip" --keychain-profile "$MOKA_NOTARY_PROFILE" --wait --output-format json > "$DESTINATION/notarization.json"
STATUS="$(/usr/bin/plutil -extract status raw "$DESTINATION/notarization.json")"
[[ "$STATUS" == Accepted ]] || { print -u2 'Apple did not accept this build. Inspect notarization.json and the notarytool log.'; exit 1; }
xcrun stapler staple "$STAGING_DIR/Moka.app"
xcrun stapler validate "$STAGING_DIR/Moka.app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$STAGING_DIR/Moka.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIR/Moka.app" "$DESTINATION/Moka-macOS.zip"
(cd "$DESTINATION" && /usr/bin/shasum -a 256 Moka-macOS.zip > Moka-macOS.zip.sha256)
print 'Signed and notarized archive:' "$DESTINATION/Moka-macOS.zip"
