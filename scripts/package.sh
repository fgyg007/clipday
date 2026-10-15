#!/bin/zsh
set -eu
cd "${0:A:h:h}"
# Package only source tracked by the release commit. Never include user data.
if [[ -n "$(git status --porcelain)" ]]; then
    print -u2 'Commit or stash source changes before packaging a release.'
    exit 1
fi
SOURCE_COMMIT="$(git rev-parse HEAD)"
zsh scripts/build.sh
APP="$PWD/build/轻贴.app"
PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
[[ "$(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")" == arm64 ]]
codesign --verify --deep --strict "$APP"
mkdir -p dist
DMG_NAME="ClipDay-${VERSION}-arm64.dmg"
[[ ! -e "dist/$DMG_NAME" ]] || { print -u2 "Already exists: dist/$DMG_NAME"; exit 1; }
STAGING="$(mktemp -d "$PWD/build/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
# ditto preserves the code signature; strip unrelated filesystem metadata.
ditto --norsrc --noextattr --noqtn "$APP" "$STAGING/轻贴.app"
ln -s /Applications "$STAGING/Applications"
cp LICENSE "$STAGING/LICENSE.txt"
cp docs/INSTALL.md "$STAGING/安装说明-Installation.txt"
cp README.md "$STAGING/项目介绍-中文.txt"
cp README.en.md "$STAGING/Overview-English.txt"
cat > "$STAGING/BUILD-INFO.txt" <<INFO
ClipDay / 轻贴
Version: $VERSION
Architecture: arm64 (Apple Silicon)
Minimum macOS: 14.0
Source: https://github.com/fgyg007/clipday
Commit: $SOURCE_COMMIT
Signing: ad-hoc; not Developer ID signed or notarized
Built at (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)
Compiler: $(xcrun swiftc --version | head -1)
INFO
codesign --verify --deep --strict "$STAGING/轻贴.app"
hdiutil create -volname "ClipDay $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO "dist/$DMG_NAME"
hdiutil verify "dist/$DMG_NAME"
(cd dist && shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt)
print "Ready: dist/$DMG_NAME and dist/SHA256SUMS.txt"
