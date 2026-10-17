#!/bin/zsh
# Synthetic replicas only. Requires installed Xcode/.NET; does not use accounts or real sync folders.
set -eu
cd "${0:A:h:h}"
source scripts/swift-env.sh
mkdir -p build
xcrun swiftc "${SWIFT_FLAGS[@]}" Sources/Sync.swift Tests/DriveFolderTests.swift -o build/drive-folder-tests
build/drive-folder-tests
"${CLIPDAY_DOTNET:-dotnet}" run --project Windows/ClipDay.Sync.Tests -c Release -- drive
