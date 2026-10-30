#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/build"
MODULE_CACHE="${MOKA_MODULE_CACHE:-$BUILD_DIR/module-cache}"
mkdir -p "$MODULE_CACHE" "$BUILD_DIR"
COMMON=("$PROJECT_DIR"/Shared/*.swift "$PROJECT_DIR/Sources/Core.swift" "$PROJECT_DIR/Sources/HelperInstaller.swift" "$PROJECT_DIR/Sources/HelperClient.swift" "$PROJECT_DIR/Sources/LidGuard.swift")
xcrun swiftc -swift-version 5 -module-cache-path "$MODULE_CACHE" "$PROJECT_DIR/Sources/Core.swift" "$PROJECT_DIR/Tests/CoreTests.swift" -o "$BUILD_DIR/core-tests" -framework IOKit
"$BUILD_DIR/core-tests" --integration
xcrun swiftc -swift-version 5 -module-cache-path "$MODULE_CACHE" "$PROJECT_DIR/Shared/HelperProtocol.swift" "$PROJECT_DIR/Helper/SessionEngine.swift" "$PROJECT_DIR/Tests/HelperTests.swift" -o "$BUILD_DIR/helper-tests"
"$BUILD_DIR/helper-tests"
xcrun swiftc -swift-version 5 -module-cache-path "$MODULE_CACHE" "${COMMON[@]}" "$PROJECT_DIR/Sources/AppModel.swift" "$PROJECT_DIR/Tests/SessionTests.swift" -o "$BUILD_DIR/session-tests" -framework AppKit -framework IOKit -framework Security
"$BUILD_DIR/session-tests"
xcrun swiftc -swift-version 5 -module-cache-path "$MODULE_CACHE" "${COMMON[@]}" "$PROJECT_DIR/Tests/LidStateTests.swift" -o "$BUILD_DIR/lid-state-tests" -framework IOKit -framework Security
"$BUILD_DIR/lid-state-tests"
xcrun swiftc -swift-version 5 -module-cache-path "$MODULE_CACHE" "$PROJECT_DIR/Shared/HelperProtocol.swift" "$PROJECT_DIR/Shared/CodeIdentity.swift" "$PROJECT_DIR/Tests/XPCTests.swift" -o "$BUILD_DIR/xpc-tests" -framework Security
/usr/bin/codesign --force --options runtime --identifier fr.local.moka.xpc-tests --sign - "$BUILD_DIR/xpc-tests"
"$BUILD_DIR/xpc-tests"
xcrun swiftc -swift-version 5 -module-cache-path "$MODULE_CACHE" "$PROJECT_DIR"/Shared/*.swift "$PROJECT_DIR/Sources/Core.swift" "$PROJECT_DIR/Sources/HelperInstaller.swift" "$PROJECT_DIR/Tests/InstallerTests.swift" -o "$BUILD_DIR/installer-tests" -framework IOKit -framework Security
"$BUILD_DIR/installer-tests"
