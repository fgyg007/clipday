#!/bin/zsh
set -eu
cd "${0:A:h:h}"
source scripts/swift-env.sh
xcrun swiftc "${SWIFT_FLAGS[@]}" Sources/Sync.swift Tests/SyncTests.swift -o build/sync-tests
xcrun swiftc "${SWIFT_FLAGS[@]}" Sources/Sync.swift Sources/ImageSync.swift Tests/ImageSyncTests.swift -o build/image-sync-tests -framework ImageIO -framework CoreGraphics
build/image-sync-tests
build/sync-tests
xcrun swiftc "${SWIFT_FLAGS[@]}" -D CLOUD Sources/Core.swift Sources/Sync.swift Sources/ImageSync.swift Sources/Cloud.swift Sources/DriveCloud.swift Sources/SyncSetup.swift Sources/Pairing.swift Sources/HotKey.swift Sources/Paste.swift Sources/Model.swift Tests/CloudModelTests.swift -o build/cloud-model-tests -framework SwiftUI -framework AppKit -framework Carbon -framework ServiceManagement -framework ApplicationServices -framework Security -framework ImageIO -framework CoreGraphics
build/cloud-model-tests
DOTNET="${CLIPDAY_DOTNET:-dotnet}"
"$DOTNET" run --project Windows/ClipDay.Sync.Tests -c Release
"$DOTNET" run --project Windows/ClipDay.Sync.Tests -c Release -- pairing
"$DOTNET" run --project Windows/ClipDay.Sync.Tests -c Release -- pairing-regressions
interop="$(mktemp -d "${TMPDIR:-/tmp}/clipday-interop.XXXXXX")"
trap 'rm -rf "$interop"' EXIT
build/sync-tests write "$interop"
"$DOTNET" run --project Windows/ClipDay.Sync.Tests -c Release -- interop "$interop"
build/sync-tests read "$interop"
