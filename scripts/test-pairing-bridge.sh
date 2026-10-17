#!/bin/zsh
set -eu
cd "${0:A:h:h}"
source scripts/swift-env.sh
FIXTURE="$PWD/build/PairingBridgeTests.app"
mkdir -p "$FIXTURE/Contents/MacOS"
cp build/pairing-mac/ClipDayPair "$FIXTURE/Contents/MacOS/ClipDayPair"
cat > "$FIXTURE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>io.jlmac.ClipDay.PairingBridgeTests</string><key>CFBundleExecutable</key><string>tests</string></dict></plist>
PLIST
xcrun swiftc "${SWIFT_FLAGS[@]}" -D CLOUD Sources/Core.swift Sources/Sync.swift Sources/Pairing.swift Tests/PairingBridgeTests.swift -o "$FIXTURE/Contents/MacOS/tests"
"$FIXTURE/Contents/MacOS/tests"
