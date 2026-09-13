#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="JMacTool"
VERSION="$(tr -d '\n' < "$ROOT_DIR/VERSION")"
DIST_DIR="$ROOT_DIR/dist"
SWIFT_BUILD_HOME="$ROOT_DIR/.build/home"
SWIFT_SCRATCH_DIR="$ROOT_DIR/.build/swiftpm"
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
EXECUTABLE_PATH="$MACOS_DIR/$APP_NAME"
INFO_TEMPLATE_PATH="$ROOT_DIR/App/Info.plist.template"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$SWIFT_BUILD_HOME" "$SWIFT_SCRATCH_DIR" "$CLANG_MODULE_CACHE_PATH"

env \
  HOME="$SWIFT_BUILD_HOME" \
  CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" \
  swift build \
  --disable-sandbox \
  --scratch-path "$SWIFT_SCRATCH_DIR" \
  -c release \
  --arch arm64 --arch x86_64 \
  --product "$APP_NAME"

BIN_DIR="$(
  env \
    HOME="$SWIFT_BUILD_HOME" \
    CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" \
    swift build \
    --disable-sandbox \
    --scratch-path "$SWIFT_SCRATCH_DIR" \
    -c release \
    --arch arm64 --arch x86_64 \
    --show-bin-path
)"

cp "$BIN_DIR/$APP_NAME" "$EXECUTABLE_PATH"
sed "s#__VERSION__#$VERSION#g" "$INFO_TEMPLATE_PATH" > "$CONTENTS_DIR/Info.plist"
chmod +x "$EXECUTABLE_PATH"

RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$DIST_DIR/$APP_NAME.iconset"
mkdir -p "$RESOURCES_DIR"
swift "$ROOT_DIR/Scripts/build-app-icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"

lipo -info "$EXECUTABLE_PATH"

codesign --force --sign - --deep "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Built $APP_DIR ($VERSION)"
