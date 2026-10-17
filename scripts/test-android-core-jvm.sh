#!/usr/bin/env bash
# Isolated fallback when Gradle/Android SDK are unavailable. Never connects to SMB.
# Requires Java 17+, curl and sha256sum (or shasum). --compile-app also needs Python 3.
# This checks Java sources/fixture tests, not Gradle, resources, APKs, or a device.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
COMPILE_APP=false
case "${1:-}" in
  "") ;;
  --compile-app) COMPILE_APP=true ;;
  *) echo "Usage: $0 [--compile-app]" >&2; exit 2 ;;
esac
WORK=$(mktemp -d "${TMPDIR:-/tmp}/clipday-jvm.XXXXXX")
cleanup() {
  if [[ ${KEEP_TEST_ARTIFACTS:-0} == 1 ]]; then echo "Test artifacts retained: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT
mkdir -p "$WORK/lib" "$WORK/classes"
fetch() {
  local artifact=$1 target=$2 expected=$3 actual
  curl --fail --location --silent --show-error --max-time 180 "https://repo.maven.apache.org/maven2/$artifact" -o "$WORK/lib/$target.jar"
  if command -v sha256sum >/dev/null; then actual=$(sha256sum "$WORK/lib/$target.jar" | awk '{print $1}');
  else actual=$(shasum -a 256 "$WORK/lib/$target.jar" | awk '{print $1}'); fi
  [[ $actual == "$expected" ]] || { echo "Checksum mismatch: $artifact" >&2; exit 1; }
}
fetch org/json/json/20240303/json-20240303.jar json 3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed
fetch junit/junit/4.13.2/junit-4.13.2.jar junit 8e495b634469d64fb8acfa3495a065cbacc8a0fff55ce1e31007be4c16dc57d3
fetch org/hamcrest/hamcrest-core/1.3/hamcrest-core-1.3.jar hamcrest 66fdef91e9739348df7a096aa384a5685f4e875584cce89386a7a47251c4d8e9
fetch org/bouncycastle/bcprov-jdk18on/1.79/bcprov-jdk18on-1.79.jar bcprov 0d81ecc3124536b539bce9aa3fe9621b7f84c9cee371b635a5b31c78b79ab1da
fetch com/hierynomus/smbj/0.14.0/smbj-0.14.0.jar smbj f5cd63af2f343bfa13d41dbf50cfd251d2b99c4118fbe82b0e94ee0f93d1cc14
fetch org/eclipse/jdt/ecj/3.40.0/ecj-3.40.0.jar ecj 05cc22a24e7982970f63a405fc6c820bc80b806f27f3c5a6236fc475f8f7152b
CP="$WORK/lib/json.jar:$WORK/lib/junit.jar:$WORK/lib/hamcrest.jar:$WORK/lib/bcprov.jar:$WORK/lib/smbj.jar"
SOURCES=()
while IFS= read -r -d '' path; do SOURCES+=("$path"); done < <(find "$ROOT/Android/core/src/main/java" "$ROOT/Android/core/src/test/java" -name '*.java' -print0)
# ECJ supports JRE-only environments; source/target 17 does not claim a JDK --release API check.
java -jar "$WORK/lib/ecj.jar" -source 17 -target 17 -cp "$CP" -d "$WORK/classes" "${SOURCES[@]}" 2>&1 | tee "$WORK/core-compile.log"
java -Dclipday.repo.root="$ROOT" -cp "$WORK/classes:$CP" org.junit.runner.JUnitCore io.jlmac.clipday.core.CoreTest io.jlmac.clipday.core.ReliabilityTest io.jlmac.clipday.core.ImageWireTest io.jlmac.clipday.core.ImageEngineTest io.jlmac.clipday.core.ImageClipboardGateTest io.jlmac.clipday.core.SetupHelpTest | tee "$WORK/junit.log"
if $COMPILE_APP; then
  fetch org/robolectric/android-all/15-robolectric-12650502/android-all-15-robolectric-12650502.jar android-all 6c0670454f6fcee9f1b17aa393e81d71bf26e7e6ae7c5777ed3924b062191d5b
  python3 - "$ROOT" "$WORK" <<'PY'
import pathlib, re, sys, zipfile
root, work = map(pathlib.Path, sys.argv[1:])
# Android's framework bundle also contains java.* classes. Remove JDK-package duplicates
# for this compile-only check, retaining Android's own org.json API (checked exceptions).
with zipfile.ZipFile(work / 'lib/android-all.jar') as src, zipfile.ZipFile(work / 'lib/android-api-only.jar', 'w') as dst:
    for info in src.infolist():
        if info.filename.endswith('.class') and not info.filename.startswith(('java/', 'javax/', 'org/w3c/', 'org/xml/sax/', 'META-INF/')):
            dst.writestr(info, src.read(info.filename))
ids = re.findall(r'<item name="([^"]+)" type="id"', (root / 'Android/app/src/main/res/values/ids.xml').read_text())
r = work / 'generated/io/jlmac/clipday/android/R.java'
r.parent.mkdir(parents=True)
r.write_text('package io.jlmac.clipday.android; public final class R { public static final class id { ' + ''.join(f'public static final int {name} = {i+1};' for i, name in enumerate(ids)) + '} }')
PY
  mkdir -p "$WORK/app-classes"
  SOURCES=()
  while IFS= read -r -d '' path; do SOURCES+=("$path"); done < <(find "$ROOT/Android/core/src/main/java" "$ROOT/Android/app/src/main/java" "$WORK/generated" -name '*.java' -print0)
  java -jar "$WORK/lib/ecj.jar" -source 17 -target 17 -cp "$WORK/lib/android-api-only.jar:$WORK/lib/bcprov.jar:$WORK/lib/smbj.jar" -d "$WORK/app-classes" "${SOURCES[@]}" 2>&1 | tee "$WORK/app-compile.log"
  echo "Main Android Java sources compile against the pinned Android 15 framework. No APK/device validation performed."
fi
