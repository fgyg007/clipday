#!/bin/zsh
# Build only. Run build/pairing-preview explicitly to display the synthetic UI.
set -eu
cd "${0:A:h:h}"
source scripts/swift-env.sh
xcrun swiftc "${SWIFT_FLAGS[@]}" -D CLOUD -target arm64-apple-macosx14.0 Sources/Core.swift Sources/Sync.swift Sources/ImageSync.swift Sources/Cloud.swift Sources/DriveCloud.swift Sources/SyncSetup.swift Sources/Pairing.swift Sources/HotKey.swift Sources/Paste.swift Sources/Model.swift Tests/PairingPreview.swift -o build/pairing-preview -framework SwiftUI -framework AppKit -framework Carbon -framework ServiceManagement -framework ApplicationServices -framework Security -framework ImageIO -framework CoreGraphics
print "$PWD/build/pairing-preview"
