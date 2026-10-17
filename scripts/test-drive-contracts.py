#!/usr/bin/env python3
"""Source/metadata contracts only: NOT compiled native or cloud-provider tests."""
import json, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def read(p): return (ROOT/p).read_text()
class DriveContracts(unittest.TestCase):
    def test_product_separation(self):
        data=json.loads(read('Desktop/products.json'))
        self.assertEqual(data['namespaces']['nas'],'ClipDaySync'); self.assertEqual(data['namespaces']['cloud-folder'],'ClipDayDrive/v1')
        self.assertEqual(data['desktopModes'],['local-only','nas','cloud-folder']); self.assertEqual(data['androidModes'],['nas'])
        self.assertTrue(data['preserveExistingNasIdentity']); self.assertFalse(data['providerOAuthImplemented'])
        self.assertTrue(all(p['compatibility']=='not-device-tested' for p in data['providers']))
    def test_explicit_cloud_mode_default_off(self):
        swift=read('Sources/Sync.swift'); cs=read('Windows/ClipDay.Sync/Sync.cs')
        self.assertIn('cloudDrive: Bool = false',swift);self.assertIn('bool cloudDrive = false',cs)
        self.assertIn('ClipDayDrive',swift);self.assertIn('ClipDayDrive',cs)
        self.assertIn('clipday-drive1:',swift);self.assertIn('clipday-drive1:',cs)
        self.assertIn('clipday1:',swift);self.assertIn('clipday1:',cs)
    def test_native_regressions_present(self):
        cs=read('Windows/ClipDay.Sync.Tests/DriveFolderTests.cs');swift=read('Tests/DriveFolderTests.swift')
        for text in ['manifest before chunk','chunk arriving later','join never creates','replicated duplicates']:
            self.assertIn(text,cs)
        self.assertIn('partial file not acknowledged',swift)
        self.assertIn('cloudDrive: true',swift)
    def test_delivery_limits_documented(self):
        doc=read('Desktop/README.md')
        for value in ['不代表已上传','版本历史','未通过原生编译','不是即时通道','双向同步','Mac / Windows']:
            self.assertIn(value,doc)
if __name__=='__main__': unittest.main()
