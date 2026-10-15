# Sourced by build and test scripts, from the project root.
mkdir -p build
SWIFT_FLAGS=(-swift-version 5)
# Some upgraded Command Line Tools retain the old SwiftBridging module map.
# Hide only that duplicate through a compiler-local virtual filesystem overlay.
SWIFT_INCLUDE="$(xcrun --find swiftc)"
SWIFT_INCLUDE="${SWIFT_INCLUDE:h:h}/include/swift"
if [[ -f "$SWIFT_INCLUDE/module.modulemap" && -f "$SWIFT_INCLUDE/bridging.modulemap" ]] && rg -q 'module SwiftBridging' "$SWIFT_INCLUDE/module.modulemap"; then
    python3 - "$SWIFT_INCLUDE/module.modulemap" "$PWD/build" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[2])
(p/'empty.modulemap').write_text('// Duplicate legacy module map hidden only for this compilation.\n')
(p/'sdk-overlay.json').write_text(json.dumps({'version':0,'roots':[{'type':'file','name':sys.argv[1],'external-contents':str(p/'empty.modulemap')}]}))
PY
    SWIFT_FLAGS+=(-vfsoverlay "$PWD/build/sdk-overlay.json")
fi
