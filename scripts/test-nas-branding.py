#!/usr/bin/env python3
"""Static NAS branding/compatibility guard; no native build, network or device I/O."""
from pathlib import Path
import plistlib
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
NAME = "轻贴"
ANDROID = "Android/app/src/main/"
JAVA = ANDROID + "java/io/jlmac/clipday/android/"


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


class NasBrandingTests(unittest.TestCase):
    def test_mac_display_and_identity(self):
        model = source("Sources/Model.swift")
        self.assertIn('let appTitle = "轻贴"', model)
        self.assertIn('let appBundleID = "io.jlmac.ClipDay.Cloud"', model)
        self.assertIn('let appBundleID = "io.jlmac.ClipDay"', model)
        self.assertIn('"Library/Application Support/" + appBundleID', model)
        build = source("scripts/build-cloud.sh")
        self.assertIn(f'APP="$PWD/build/{NAME}.app"', build)
        xml = re.search(r"<\?xml.*?</plist>", build, re.S).group(0)
        info = plistlib.loads(xml.encode())
        for key, expected in {
            "CFBundleName": NAME, "CFBundleDisplayName": NAME,
            "CFBundleIdentifier": "io.jlmac.ClipDay.Cloud", "CFBundleExecutable": "ClipDay",
            "CFBundleShortVersionString": "0.1.1", "CFBundleVersion": "2",
        }.items():
            self.assertEqual(info[key], expected, key)
        self.assertIn('static let service = "io.jlmac.ClipDay.Cloud.sync"', source("Sources/Cloud.swift"))
        self.assertIn('Library/Application Support/io.jlmac.ClipDay.Cloud/sync/', source("Sources/Cloud.swift"))

    def test_windows_display_and_identity(self):
        program = source("Windows/ClipDay.Cloud/Program.cs")
        self.assertNotIn("轻贴云版", program)
        product = source("Windows/ClipDay.Cloud/Product.cs")
        self.assertIn('public const string Title = "轻贴";', product)
        self.assertIn('public const string StorageName = "ClipDay.Cloud";', product)
        self.assertIn('Text = Product.Title', program)
        self.assertIn('namespace ClipDay.Cloud;', program)
        self.assertIn('SpecialFolder.LocalApplicationData), "ClipDay.Cloud")', source("Windows/ClipDay.Cloud/ModePreferences.cs"))
        self.assertIn('Product.StorageName + "." + Environment.UserName', program)
        project = ET.fromstring(source("Windows/ClipDay.Cloud/ClipDay.Cloud.csproj"))
        self.assertEqual(project.findtext(".//AssemblyName"), "ClipDay.Cloud")
        self.assertEqual(project.findtext(".//Version"), "0.1.3")

    def test_android_display_and_identity(self):
        ns = "{http://schemas.android.com/apk/res/android}"
        manifest = ET.fromstring(source(ANDROID + "AndroidManifest.xml"))
        app = manifest.find("application")
        self.assertEqual(app.get(ns + "label"), NAME)
        self.assertEqual(app.find("provider").get(ns + "authorities"), "io.jlmac.clipday.android.images")
        labels = [node.get(ns + "label") for node in app.iter("intent-filter") if node.get(ns + "label")]
        self.assertIn("发送到" + NAME, labels)
        activity = source(JAVA + "MainActivity.java")
        self.assertIn(f'text("{NAME}", 32', activity)
        self.assertIn("分享 → " + NAME, activity)
        self.assertIn(NAME + " · NAS 模式 · 未发布源码", activity)
        gradle = source("Android/app/build.gradle")
        for field in ["namespace 'io.jlmac.clipday.android'", "applicationId 'io.jlmac.clipday.android'", "versionCode 1", "versionName '0.1.0'", "keyAlias 'clipday'"]:
            self.assertIn(field, gradle)
        self.assertIn('ALIAS = "clipday-local-v1"', source(JAVA + "Vault.java"))
        self.assertIn('this(context, "vault.enc")', source(JAVA + "Vault.java"))
        self.assertIn('context.getNoBackupFilesDir()', source(JAVA + "Vault.java"))
        self.assertIn('AUTHORITY="io.jlmac.clipday.android.images"', source(JAVA + "ImageProvider.java"))

    def test_nas_protocol_and_published_downloads(self):
        # These constants must not be renamed with the UI brand.
        sync = source("Sources/Sync.swift")
        for marker in ['"ClipDaySync"', '"clipday1:"', '"clipday-sync-v1:', '"clipday-space-v1"']:
            self.assertIn(marker, sync)
        for path in ["Windows/ClipDay.Sync/Sync.cs", "Android/core/src/main/java/io/jlmac/clipday/core/Wire.java"]:
            for marker in ["ClipDaySync", "clipday-sync-v1:"]:
                self.assertIn(marker, source(path))
        for readme in ["README.md", "README.en.md"]:
            content = source(readme)
            for asset in ["ClipDay-Cloud-0.1.1-macos-arm64.zip", "ClipDay-Cloud-0.1.3-windows-x64.zip", "ClipDay-Cloud-0.1.0-android.apk", "SHA256SUMS.txt"]:
                self.assertIn("https://github.com/fgyg007/clipday-cloud/releases/download/v0.1.0-preview.1/" + asset, content)
            self.assertIn("轻贴云版.app", content)
            self.assertIn(NAME + ".app", content)


if __name__ == "__main__":
    unittest.main(verbosity=2)
