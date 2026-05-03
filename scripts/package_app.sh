#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="FTP Server 纪"
APP_DIR="$DIST_DIR/$APP_NAME.app"
EXECUTABLE="$ROOT_DIR/.build/release/LocalFTP"

cd "$ROOT_DIR"
swift scripts/generate_app_icon.swift
swift build -c release

rm -rf "$APP_DIR" "$DIST_DIR/LocalFTP.app" "$DIST_DIR/LocalFTP.app.zip" "$DIST_DIR/$APP_NAME.app.zip"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/LocalFTP"
cp "$ROOT_DIR/Sources/LocalFTPApp/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LocalFTP</string>
    <key>CFBundleIdentifier</key>
    <string>dev.local.localftpserver</string>
    <key>CFBundleName</key>
    <string>FTP Server 纪</string>
    <key>CFBundleDisplayName</key>
    <string>FTP Server 纪</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.4</string>
    <key>CFBundleVersion</key>
    <string>5</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null
ditto -c -k --keepParent "$APP_DIR" "$DIST_DIR/$APP_NAME.app.zip"

echo "App: $APP_DIR"
echo "Zip: $DIST_DIR/$APP_NAME.app.zip"
