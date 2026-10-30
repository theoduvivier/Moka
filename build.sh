#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/build"
MODULE_CACHE="${MOKA_MODULE_CACHE:-$BUILD_DIR/module-cache}"
DESTINATION="${1:-$BUILD_DIR/Moka.app}"
STAGING_DIR="$(mktemp -d /private/tmp/moka-build.XXXXXX)"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_DIR="$STAGING_DIR/Moka.app"
SPARKLE_DIR="$(zsh "$PROJECT_DIR/Tools/fetch-sparkle.sh")"
UPDATER_DIR="$APP_DIR/Contents/Helpers/MokaUpdater.app"
mkdir -p "$MODULE_CACHE" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Library/HelperTools"
mkdir -p "$UPDATER_DIR/Contents/MacOS" "$UPDATER_DIR/Contents/Resources" "$UPDATER_DIR/Contents/Frameworks"
/usr/bin/ditto --norsrc --noextattr "$SPARKLE_DIR/Sparkle.framework" "$UPDATER_DIR/Contents/Frameworks/Sparkle.framework"
SDK_PATH="$(xcrun --show-sdk-path)"
if [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk; fi
for ARCH in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library -swift-version 5 -sdk "$SDK_PATH" -target "$ARCH-apple-macos13.0" -module-cache-path "$MODULE_CACHE" \
    "$PROJECT_DIR"/Updater/*.swift -o "$STAGING_DIR/MokaUpdater-$ARCH" \
    -framework AppKit -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks
  xcrun swiftc -O -swift-version 5 -sdk "$SDK_PATH" -target "$ARCH-apple-macos13.0" -module-cache-path "$MODULE_CACHE" \
    "$PROJECT_DIR"/Helper/*.swift "$PROJECT_DIR"/Shared/*.swift -o "$STAGING_DIR/MokaHelper-$ARCH" \
    -framework Foundation -framework IOKit -framework Security
  xcrun swiftc -O -swift-version 5 -sdk "$SDK_PATH" -target "$ARCH-apple-macos13.0" -module-cache-path "$MODULE_CACHE" \
    "$PROJECT_DIR"/Sources/*.swift "$PROJECT_DIR"/Shared/*.swift -o "$STAGING_DIR/Moka-$ARCH" \
    -framework AppKit -framework SwiftUI -Xlinker -weak_framework -Xlinker Symbols -framework IOKit -framework Security
done
xcrun lipo -create "$STAGING_DIR/MokaUpdater-arm64" "$STAGING_DIR/MokaUpdater-x86_64" -output "$UPDATER_DIR/Contents/MacOS/MokaUpdater"
cp "$PROJECT_DIR/Resources/Updater-Info.plist" "$UPDATER_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$UPDATER_DIR/Contents/Resources/"
cp "$SPARKLE_DIR/LICENSE" "$APP_DIR/Contents/Resources/Sparkle-LICENSE.txt"
xcrun lipo -create "$STAGING_DIR/MokaHelper-arm64" "$STAGING_DIR/MokaHelper-x86_64" -output "$APP_DIR/Contents/Library/HelperTools/MokaHelper"
xcrun lipo -create "$STAGING_DIR/Moka-arm64" "$STAGING_DIR/Moka-x86_64" -output "$APP_DIR/Contents/MacOS/Moka"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$PROJECT_DIR/Resources/Robot-awake.png" "$PROJECT_DIR/Resources/Robot-rest.png" "$APP_DIR/Contents/Resources/"
/usr/bin/xattr -dr com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$APP_DIR" 2>/dev/null || true
if [ -n "${MOKA_SIGN_IDENTITY:-}" ]; then
  FRAMEWORK="$UPDATER_DIR/Contents/Frameworks/Sparkle.framework"
  for SERVICE in "$FRAMEWORK"/Versions/B/XPCServices/*.xpc; do
    /usr/bin/codesign --force --options runtime --preserve-metadata=entitlements --timestamp --sign "$MOKA_SIGN_IDENTITY" "$SERVICE"
  done
  /usr/bin/codesign --force --options runtime --timestamp --sign "$MOKA_SIGN_IDENTITY" "$FRAMEWORK/Versions/B/Autoupdate"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$MOKA_SIGN_IDENTITY" "$FRAMEWORK/Versions/B/Updater.app"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$MOKA_SIGN_IDENTITY" "$FRAMEWORK"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$MOKA_SIGN_IDENTITY" "$UPDATER_DIR"
  /usr/bin/codesign --force --options runtime --timestamp --identifier fr.local.moka.helper --sign "$MOKA_SIGN_IDENTITY" "$APP_DIR/Contents/Library/HelperTools/MokaHelper"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$MOKA_SIGN_IDENTITY" "$APP_DIR"
else
  # A separate unprivileged updater can load Sparkle without relaxing Library
  # Validation on Moka, whose identity authenticates access to the root service.
  # Sparkle's embedded tools retain their upstream Developer ID signatures.
  /usr/bin/codesign --force --sign - "$UPDATER_DIR"
  /usr/bin/codesign --force --options runtime --identifier fr.local.moka.helper --sign - "$APP_DIR/Contents/Library/HelperTools/MokaHelper"
  /usr/bin/codesign --force --options runtime --sign - "$APP_DIR"
fi
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
/usr/bin/ditto --norsrc --noextattr "$APP_DIR" "$DESTINATION"
printf 'Application créée : %s\n' "$DESTINATION"
