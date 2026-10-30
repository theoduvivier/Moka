#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/build"
MODULE_CACHE="${MOKA_MODULE_CACHE:-$BUILD_DIR/module-cache}"
mkdir -p "$MODULE_CACHE" "$BUILD_DIR/guard-tests"
xcrun swiftc -swift-version 5 -module-cache-path "$MODULE_CACHE" \
  "$PROJECT_DIR/Sources/Core.swift" "$PROJECT_DIR/Sources/LidGuard.swift" "$PROJECT_DIR/Tests/CoreTests.swift" \
  -o "$BUILD_DIR/core-tests" -framework IOKit
MOKA_GUARD_FIXTURE_DIR="$BUILD_DIR/guard-tests" "$BUILD_DIR/core-tests" --integration
python3 "$PROJECT_DIR/Tests/test_guard.py"
xcrun swiftc -swift-version 5 -module-cache-path "$MODULE_CACHE" \
  "$PROJECT_DIR/Sources/AppModel.swift" "$PROJECT_DIR/Sources/Core.swift" \
  "$PROJECT_DIR/Sources/LidGuard.swift" "$PROJECT_DIR/Tests/SessionTests.swift" \
  -o "$BUILD_DIR/session-tests" -framework AppKit -framework IOKit
"$BUILD_DIR/session-tests"
xcrun swiftc -swift-version 5 -module-cache-path "$MODULE_CACHE" \
  "$PROJECT_DIR/Sources/Core.swift" "$PROJECT_DIR/Sources/LidGuard.swift" \
  "$PROJECT_DIR/Tests/LidStateTests.swift" -o "$BUILD_DIR/lid-state-tests" -framework IOKit
"$BUILD_DIR/lid-state-tests"
xcrun swiftc -swift-version 5 -module-cache-path "$MODULE_CACHE" \
  "$PROJECT_DIR/Sources/Core.swift" "$PROJECT_DIR/Sources/LidGuard.swift" \
  "$PROJECT_DIR/Tests/LidLaunchTests.swift" -o "$BUILD_DIR/lid-launch-tests" -framework IOKit
"$BUILD_DIR/lid-launch-tests"
