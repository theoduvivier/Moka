#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/build"
MODULE_CACHE="${MOKA_MODULE_CACHE:-$BUILD_DIR/module-cache}"
DESTINATION="${1:-$BUILD_DIR/Moka.app}"
STAGING_DIR="$(mktemp -d /private/tmp/moka-build.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/Moka.app"
mkdir -p "$MODULE_CACHE" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Library/HelperTools"
SDK_PATH="$(xcrun --show-sdk-path)"
if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk; fi
for ARCH in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -sdk "$SDK_PATH" -target "$ARCH-apple-macos13.0" -module-cache-path "$MODULE_CACHE" \
    "$PROJECT_DIR"/Helper/*.swift "$PROJECT_DIR"/Shared/*.swift -o "$STAGING_DIR/MokaHelper-$ARCH" \
    -framework Foundation -framework IOKit -framework Security
  xcrun swiftc -O -swift-version 5 -sdk "$SDK_PATH" -target "$ARCH-apple-macos13.0" -module-cache-path "$MODULE_CACHE" \
    "$PROJECT_DIR"/Sources/*.swift "$PROJECT_DIR"/Shared/*.swift -o "$STAGING_DIR/Moka-$ARCH" \
    -framework AppKit -framework SwiftUI -Xlinker -weak_framework -Xlinker Symbols -framework IOKit -framework Security
done
xcrun lipo -create "$STAGING_DIR/MokaHelper-arm64" "$STAGING_DIR/MokaHelper-x86_64" -output "$APP_DIR/Contents/Library/HelperTools/MokaHelper"
xcrun lipo -create "$STAGING_DIR/Moka-arm64" "$STAGING_DIR/Moka-x86_64" -output "$APP_DIR/Contents/MacOS/Moka"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$PROJECT_DIR/Resources/Robot-awake.png" "$PROJECT_DIR/Resources/Robot-rest.png" "$APP_DIR/Contents/Resources/"
/usr/bin/xattr -dr com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$APP_DIR" 2>/dev/null || true
if [ -n "${MOKA_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --options runtime --timestamp --identifier fr.local.moka.helper --sign "$MOKA_SIGN_IDENTITY" "$APP_DIR/Contents/Library/HelperTools/MokaHelper"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$MOKA_SIGN_IDENTITY" "$APP_DIR"
else
  /usr/bin/codesign --force --options runtime --identifier fr.local.moka.helper --sign - "$APP_DIR/Contents/Library/HelperTools/MokaHelper"
  /usr/bin/codesign --force --options runtime --sign - "$APP_DIR"
fi
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
/usr/bin/ditto --norsrc --noextattr "$APP_DIR" "$DESTINATION"
printf 'Application créée : %s\n' "$DESTINATION"
