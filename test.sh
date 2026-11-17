#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
TASK_BUILD_DIR=${JINGZHUO_BUILD_DIR:-"$SCRIPT_DIR/.build"}
mkdir -p "$TASK_BUILD_DIR"
xcrun swiftc "$SCRIPT_DIR/Sources/WindowEngine.swift" "$SCRIPT_DIR/Sources/Shortcut.swift" "$SCRIPT_DIR/Sources/SystemBars.swift" "$SCRIPT_DIR/Sources/EscapeClose.swift" "$SCRIPT_DIR/Tests/main.swift" \
  -o "$TASK_BUILD_DIR/tests" -module-cache-path "$TASK_BUILD_DIR/module-cache" -framework Carbon
"$TASK_BUILD_DIR/tests"
