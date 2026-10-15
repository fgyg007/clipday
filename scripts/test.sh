#!/bin/zsh
set -eu
cd "${0:A:h:h}"
source scripts/swift-env.sh
xcrun swiftc "${SWIFT_FLAGS[@]}" Sources/Core.swift Sources/HotKey.swift Sources/Paste.swift Sources/Model.swift Sources/Tests.swift -o build/tests -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement -framework ApplicationServices
build/tests
