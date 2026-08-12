#!/bin/zsh
set -euo pipefail

APP_NAME="Жми"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
ICON_SOURCE="Resources/AppIconSource.png"
ICON_TRANSPARENT="$BUILD_DIR/AppIconTransparent.png"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swift scripts/make_transparent_icon.swift "$ICON_SOURCE" "$ICON_TRANSPARENT"
cp "$ICON_TRANSPARENT" "$RESOURCES_DIR/AppLogo.png"

swiftc \
  -parse-as-library \
  -target arm64-apple-macosx15.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework UserNotifications \
  -o "$MACOS_DIR/$APP_NAME" \
  Sources/ZhmiApp.swift

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ru</string>
  <key>CFBundleExecutable</key>
  <string>Жми</string>
  <key>CFBundleIdentifier</key>
  <string>local.zhmi.compressor</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Жми</string>
  <key>CFBundleIconFile</key>
  <string>AppLogo.png</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.5</string>
  <key>CFBundleVersion</key>
  <string>6</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null
echo "$APP_DIR"
