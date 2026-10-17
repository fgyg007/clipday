#!/usr/bin/env python3
"""Unified Windows runtime source contracts, not a native build or execution."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET
ROOT = Path(__file__).resolve().parents[1]

class UnifiedWindowsSource(unittest.TestCase):
    def setUp(self):
        self.program = (ROOT/'Windows/ClipDay.Cloud/Program.cs').read_text()
        self.product = (ROOT/'Windows/ClipDay.Cloud/Product.cs').read_text()
    def test_original_identity_runtime_storage(self):
        project = ET.parse(ROOT/'Windows/ClipDay.Cloud/ClipDay.Cloud.csproj')
        self.assertEqual(project.findtext('.//AssemblyName'), 'ClipDay.Cloud')
        self.assertIn('Title = "轻贴"', self.product)
        self.assertIn('StorageName = "ClipDay.Cloud"', self.product)
        self.assertIn('Mode { get; } = ModePreferences.Read()', self.product)
        self.assertIn('Path.Combine(ModePreferences.BaseRoot, "cloud-folder")', self.program)
        self.assertIn('Path.Combine(ModePreferences.BaseRoot, "local-only")', self.program)
        self.assertNotIn('#if PRODUCT_DRIVE', self.program)
        mode = (ROOT/'Windows/ClipDay.Cloud/ModePreferences.cs').read_text()
        self.assertIn('if (!File.Exists(ModePath))', mode)
        self.assertIn('return legacyNas ? SyncMode.Nas : SyncMode.LocalOnly;', mode)
        for marker in ('config.json', 'history.protected', 'images', 'sync'):
            self.assertIn(f'Path.Combine(BaseRoot, "{marker}")', mode)
        self.assertIn('catch { return SyncMode.LocalOnly; }', mode)
    def test_pairing_privacy_and_namespace(self):
        for token in ('Pair.ParseDrive(entered)', 'pair.DriveCode', 'ShortPairing.JoinAsync', 'ShortPairing.HostAsync', 'cloudDrive: Product.IsDrive', 'AwaitingSpace: true', 'Math.Min(60, joinBackoffSeconds * 2)'):
            self.assertIn(token, self.program)
        self.assertIn('text.Trim().StartsWith("clipday-drive1:", StringComparison.Ordinal)', self.program)
        self.assertLess(self.program.index('IsDrivePairSecret(secret)'), self.program.index('capture.Begin(sequence, text'))
        self.assertIn('!IsDrivePairSecret(remote.Text)', self.program)
        self.assertIn('created >= clipboardActivityCreated', self.program)
        self.assertIn('Wire.Now - created <= sync.AutomaticWindow', self.program)
        self.assertIn('enabled && transferCancel.IsCancellationRequested', self.program)
    def test_mode_switch_and_local_only(self):
        switch = self.program.split('async Task SwitchMode(',1)[1].split('void CopyAiHelp()',1)[0]
        for token in ('timer.Stop()', 'privacyCancel.Cancel()', 'transferCancel.Cancel()', 'await CancelPairing()', 'while (captureBusy || polling)', 'await gate.WaitAsync()', 'ModePreferences.Save(selected)', 'capture.Ignore(GetClipboardSequenceNumber())', 'closing = true; Close()'):
            self.assertIn(token, switch)
        self.assertLess(switch.index('await gate.WaitAsync()'), switch.index('ModePreferences.Save(selected)'))
        self.assertNotIn('Process.Start', switch)
        self.assertIn('!Product.IsLocal && result.cfg', self.program)
        self.assertIn('Product.IsLocal || busy || privacyTransition', self.program)
    def test_sanitized_user_copy_only(self):
        help_code = self.program.split('void CopyAiHelp()',1)[1].split('async Task LoadState()',1)[0]
        for forbidden in ('folderInput.Text', 'Environment.UserName', 'Environment.MachineName', 'pair.Code', 'ProtectedPair', 'Clipboard.Get', 'File.Read', 'HttpClient'):
            self.assertNotIn(forbidden, help_code)
        self.assertIn('Clipboard.SetText(prompt', help_code)
        self.assertIn('capture.Ignore(GetClipboardSequenceNumber())', help_code)
        self.assertIn('先进行只读诊断', help_code)
        self.assertIn('安装软件、修改网络或安全设置前必须先询问', help_code)
        self.assertIn('绝不关闭防火墙', help_code)
        self.assertIn('未经真机验证', help_code)
    def test_csharp_source_parse_when_available(self):
        try:
            from tree_sitter import Language, Parser
            import tree_sitter_c_sharp
        except ImportError: self.skipTest('Existing source parser unavailable; nothing installed')
        parser = Parser(Language(tree_sitter_c_sharp.language()))
        for file in (ROOT/'Windows/ClipDay.Cloud').glob('*.cs'):
            self.assertFalse(parser.parse(file.read_bytes()).root_node.has_error, file.name)

if __name__ == '__main__': unittest.main()
