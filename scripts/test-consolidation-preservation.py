#!/usr/bin/env python3
"""Verify archived original assets remain exact and integration cannot silently package a release."""
from pathlib import Path
import hashlib,json,unittest
ROOT=Path(__file__).resolve().parents[1]
class Preservation(unittest.TestCase):
    def test_original_assets(self):
        manifest=json.loads((ROOT/'Legacy/local-v1.2.0/preserved-files.json').read_text())
        self.assertEqual(manifest['sourceCommit'],'8f9ac029804bce3cd31e6cc3a5c57d3ce71409ca')
        for name,expected in manifest['sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT/name).read_bytes()).hexdigest(),expected,name)
    def test_release_and_migration_not_claimed_complete(self):
        self.assertIn('exit 1',(ROOT/'scripts/package.sh').read_text())
        self.assertIn('尚未实现',(ROOT/'docs/CONSOLIDATION.md').read_text())
        self.assertIn('not-implemented',(ROOT/'Desktop/products.json').read_text())
    def test_android_help_accepts_no_sensitive_settings(self):
        source=(ROOT/'Android/core/src/main/java/io/jlmac/clipday/core/SetupHelp.java').read_text()
        self.assertIn('androidNas(int sdk)',source)
        for unsafe in ['JSONObject','Context','SharedPreferences','getPrimaryClip','HttpClient','getText()']:
            self.assertNotIn(unsafe,source)
if __name__=='__main__': unittest.main()
