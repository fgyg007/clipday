#!/bin/zsh
set -eu
cd "${0:A:h:h}"
android_tools="${CLIPDAY_ANDROID_TOOLS:-$HOME/.local/share/clipday-android}"
export JAVA_HOME="${JAVA_HOME:-$android_tools/jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$android_tools/sdk}"
signing_dir="$HOME/.local/share/clipday-android-signing"
mkdir -p "$signing_dir"
chmod 700 "$signing_dir"
if [[ ! -f "$signing_dir/password" ]]; then
    python3 - "$signing_dir/password" <<'PY'
import os,secrets,sys
with os.fdopen(os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'w') as f:
    f.write(secrets.token_urlsafe(32))
PY
fi
export CLIPDAY_ANDROID_KEYSTORE="$signing_dir/clipday.jks"
export CLIPDAY_ANDROID_STORE_PASSWORD="$(cat "$signing_dir/password")"
if [[ ! -f "$CLIPDAY_ANDROID_KEYSTORE" ]]; then
    "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$CLIPDAY_ANDROID_KEYSTORE" -alias clipday -keyalg RSA -keysize 3072 -validity 10000 \
        -storepass:env CLIPDAY_ANDROID_STORE_PASSWORD -keypass:env CLIPDAY_ANDROID_STORE_PASSWORD -dname 'CN=ClipDay Local Distribution'
    chmod 600 "$CLIPDAY_ANDROID_KEYSTORE"
fi
cd Android
gradle_bin="${CLIPDAY_GRADLE:-$android_tools/gradle-8.11.1/bin/gradle}"
"$gradle_bin" --console=plain :core:test :app:lintRelease :app:assembleRelease
cd ..
mkdir -p dist
cp Android/app/build/outputs/apk/release/app-release.apk dist/ClipDay-Cloud-0.1.0-android.apk
"$ANDROID_HOME/build-tools/35.0.0/apksigner" verify dist/ClipDay-Cloud-0.1.0-android.apk
(cd dist && shasum -a 256 ClipDay-Cloud-0.1.0-android.apk > ClipDay-Cloud-0.1.0-android-SHA256SUMS.txt)
print 'APK ready: dist/ClipDay-Cloud-0.1.0-android.apk'
