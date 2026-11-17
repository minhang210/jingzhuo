#!/bin/zsh
set -euo pipefail
SCRIPT_DIR=${0:A:h}
DIST_DIR=${1:-"$SCRIPT_DIR/dist"}
TASK_BUILD_DIR=${JINGZHUO_BUILD_DIR:-"$SCRIPT_DIR/.build"}
mkdir -p "$TASK_BUILD_DIR" "$DIST_DIR"
APP_PATH="$DIST_DIR/净桌.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
ARCH_NAME=$(uname -m)
# Set JINGZHUO_UNIVERSAL=1 to include both Apple Silicon and Intel.
xcrun swiftc "$SCRIPT_DIR"/Sources/*.swift -O -o "$APP_PATH/Contents/MacOS/CleanDesk" \
  -module-cache-path "$TASK_BUILD_DIR/module-cache" -target "$ARCH_NAME-apple-macos13.0" -framework Carbon
if [[ ${JINGZHUO_UNIVERSAL:-0} == 1 ]]; then
  OTHER_ARCH=arm64
  [[ "$ARCH_NAME" == arm64 ]] && OTHER_ARCH=x86_64
  xcrun swiftc "$SCRIPT_DIR"/Sources/*.swift -O -o "$TASK_BUILD_DIR/CleanDesk-$OTHER_ARCH" \
    -module-cache-path "$TASK_BUILD_DIR/module-cache" -target "$OTHER_ARCH-apple-macos13.0" -framework Carbon
  xcrun lipo -create "$APP_PATH/Contents/MacOS/CleanDesk" "$TASK_BUILD_DIR/CleanDesk-$OTHER_ARCH" \
    -output "$TASK_BUILD_DIR/CleanDesk-universal"
  cp "$TASK_BUILD_DIR/CleanDesk-universal" "$APP_PATH/Contents/MacOS/CleanDesk"
fi
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
xcrun swiftc "$SCRIPT_DIR/Scripts/MakeIcon.swift" -o "$TASK_BUILD_DIR/make-icon" -module-cache-path "$TASK_BUILD_DIR/module-cache"
"$TASK_BUILD_DIR/make-icon" "$TASK_BUILD_DIR/AppIcon.iconset" "$APP_PATH/Contents/Resources/AppIcon-v3.icns"
cp "$TASK_BUILD_DIR/AppIcon.iconset/icon_256x256.png" "$APP_PATH/Contents/Resources/AppIcon-Preview.png"
iconutil -c iconset "$APP_PATH/Contents/Resources/AppIcon-v3.icns" -o "$TASK_BUILD_DIR/Icon-roundtrip.iconset"
codesign --force --sign - --identifier local.jingzhuo.CleanDesk "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"
print "构建完成：$APP_PATH"
