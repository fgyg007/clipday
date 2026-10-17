#!/bin/zsh
set -eu
cd "${0:A:h:h}"
source scripts/swift-env.sh
FIXTURE="$PWD/build/PasteFixture.app"
mkdir -p "$FIXTURE/Contents/MacOS"
xcrun swiftc "${SWIFT_FLAGS[@]}" -parse-as-library Tests/PasteFixture.swift -o "$FIXTURE/Contents/MacOS/PasteFixture" -framework AppKit
cat > "$FIXTURE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PasteFixture</string>
<key>CFBundleIdentifier</key><string>io.jlmac.ClipDay.PasteFixture</string>
<key>CFBundleName</key><string>轻贴临时测试窗口</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$FIXTURE"
xcrun swiftc "${SWIFT_FLAGS[@]}" -parse-as-library Tests/EndToEnd.swift -o build/e2e-test -framework AppKit -framework ApplicationServices
echo 'Prepared build/e2e-test; running it requires explicit authorization for native UI testing.'
