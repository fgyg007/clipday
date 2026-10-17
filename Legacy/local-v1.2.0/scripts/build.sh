#!/bin/zsh
set -eu
cd "${0:A:h:h}"
source scripts/swift-env.sh
APP="$PWD/build/轻贴.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc "${SWIFT_FLAGS[@]}" -O -target arm64-apple-macosx14.0 Sources/Core.swift Sources/HotKey.swift Sources/Paste.swift Sources/Model.swift Sources/App.swift -o "$APP/Contents/MacOS/ClipDay" -framework SwiftUI -framework AppKit -framework Carbon -framework ServiceManagement -framework ApplicationServices
xcrun swiftc "${SWIFT_FLAGS[@]}" scripts/Icon.swift -o build/make-icon -framework AppKit
build/make-icon "$PWD/build/AppIcon.iconset"
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ClipDay</string>
<key>CFBundleIdentifier</key><string>io.jlmac.ClipDay</string>
<key>CFBundleName</key><string>轻贴</string>
<key>CFBundleDisplayName</key><string>轻贴</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "$APP"
