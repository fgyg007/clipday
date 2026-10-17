#!/bin/zsh
set -eu
cd "${0:A:h:h}"
source scripts/swift-env.sh
APP="$PWD/build/轻贴.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
DOTNET="${CLIPDAY_DOTNET:-dotnet}"
DOTNET_CLI_TELEMETRY_OPTOUT=1 "$DOTNET" publish Windows/ClipDay.Pairing -c Release -r osx-arm64 -o build/pairing-mac --nologo
cp build/pairing-mac/ClipDayPair "$APP/Contents/MacOS/ClipDayPair"
codesign --force --sign - "$APP/Contents/MacOS/ClipDayPair"
xcrun swiftc "${SWIFT_FLAGS[@]}" -D CLOUD -O -target arm64-apple-macosx14.0 Sources/Core.swift Sources/Sync.swift Sources/ImageSync.swift Sources/Cloud.swift Sources/DriveCloud.swift Sources/SyncSetup.swift Sources/Pairing.swift Sources/HotKey.swift Sources/Paste.swift Sources/Model.swift Sources/App.swift -o "$APP/Contents/MacOS/ClipDay" -framework SwiftUI -framework AppKit -framework Carbon -framework ServiceManagement -framework ApplicationServices -framework Security -framework ImageIO -framework CoreGraphics
xcrun swiftc "${SWIFT_FLAGS[@]}" scripts/Icon.swift -o build/make-icon -framework AppKit
build/make-icon "$PWD/build/CloudIcon.iconset"
iconutil -c icns build/CloudIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ClipDay</string>
<key>CFBundleIdentifier</key><string>io.jlmac.ClipDay.Cloud</string>
<key>CFBundleName</key><string>轻贴</string>
<key>CFBundleDisplayName</key><string>轻贴</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>ClipDayDevelopmentVersion</key><string>0.2.0-dev</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
cp licenses/BouncyCastle.md "$APP/Contents/Resources/BouncyCastle-LICENSE.md"
codesign --force --sign - "$APP"
echo "$APP"
