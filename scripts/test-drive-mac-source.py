#!/usr/bin/env python3
"""Source contract checks only. Does not build Swift or exercise native clipboard/cloud clients."""
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
def source(name): return (ROOT / name).read_text()

class DriveMacSourceContracts(unittest.TestCase):
    def test_unified_build_and_isolated_modes(self):
        build = source('scripts/build-cloud.sh')
        plist = build.split("<<'PLIST'\n", 1)[1].split('\nPLIST', 1)[0]
        ET.fromstring(plist)
        self.assertIn('-D CLOUD', build)
        self.assertNotIn('-D DRIVE', build)
        for name in ['Sources/Cloud.swift', 'Sources/DriveCloud.swift', 'Sources/SyncSetup.swift']:
            self.assertIn(name, build)
        self.assertIn('io.jlmac.ClipDay.Cloud</string>', plist)
        self.assertIn('exec zsh scripts/build-cloud.sh', source('scripts/build-drive.sh'))
        model = source('Sources/Model.swift')
        self.assertIn('let appTitle = "轻贴"', model)
        self.assertIn('case .nas: return root', model)
        self.assertIn('root.appendingPathComponent("drive-history")', model)
        self.assertIn('root.appendingPathComponent("local-history")', model)
        controller = source('Sources/DriveCloud.swift')
        self.assertIn('io.jlmac.ClipDay.Drive.sync', controller)
        self.assertIn('Application Support/io.jlmac.ClipDay.Drive/sync/', controller)
        self.assertIn('UserDefaults(suiteName: "io.jlmac.ClipDay.Cloud.drive-settings")', controller)
        self.assertNotIn('UserDefaults.standard', controller)

    def test_actual_text_and_image_wiring(self):
        model, controller = source('Sources/Model.swift'), source('Sources/DriveCloud.swift')
        for hook in ['cloud.send(', 'cloud.sendImage(', 'cloud.localActivity()', 'cloud.setPrivacyPaused(']:
            self.assertIn(hook, model)
        for hook in ['engine.enqueue(', 'engine.poll(', 'receiveImages(', 'markImageQueued(', 'acknowledgeQueuedIntent(', 'clip.imageSyncSpace == activeSpace']:
            self.assertIn(hook, controller)
        self.assertGreaterEqual(controller.count('cloudDrive: true'), 5)
        self.assertIn('folder: URL(fileURLWithPath: self.folder)', controller)
        self.assertNotIn('engine.root.deletingLastPathComponent()', controller)

    def test_pairing_wait_and_secret_hygiene(self):
        controller = source('Sources/DriveCloud.swift')
        self.assertIn('SyncPair.parseDrive(input.stringValue)', controller)
        self.assertIn('pairCode = pair.driveCode', controller)
        self.assertIn('NSSecureTextField', controller)
        self.assertIn('textSelection(.disabled)', controller)
        self.assertNotIn('NSPasteboard', controller)
        self.assertNotIn('PairingProcess', controller)
        self.assertIn('if create == false, self.pendingJoin != nil', controller)
        self.assertNotIn('case SyncFailure.offline = error', controller)
        self.assertIn('min(60.0, 5.0 * pow(2.0, Double(self.joinAttempts - 1)))', controller)
        self.assertGreaterEqual(controller.count('guard Date() >= joinRetryAt'), 2)
        self.assertIn('取消等待加入', controller)
        self.assertIn('func cancelJoin()', controller)
        self.assertIn('create: false)', controller)
        self.assertIn('self.pendingJoin = nil', controller)
        self.assertIn('pairCode = ""; pairMessage = ""', controller)

    def test_truthful_provider_and_delivery_guidance(self):
        controller = source('Sources/DriveCloud.swift')
        for text in ['百度网盘', 'OneDrive', 'iCloud', '其他同步文件夹', '未经真机验证', '仅备份', '虚拟挂载', '非占位符', '云端上传及接收端是否收到未知', '不会暂停网盘客户端', 'folderPrerequisitesConfirmed']:
            self.assertIn(text, controller)
        self.assertIn('guard folderPrerequisitesConfirmed', controller)
        self.assertNotIn('已上传 NAS', controller)
        self.assertNotIn('https://', controller)

    def test_pairing_secret_capture_is_skipped(self):
        model = source('Sources/Model.swift')
        secret_guard = model.index('text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("clipday-drive1:")')
        self.assertLess(secret_guard, model.index('} else if let png = pasteboard.data(forType: .png)'))
        self.assertIn('lastChange = count; pendingCapture = nil; captureIssue = nil', model[secret_guard:secret_guard + 400])
        self.assertIn('不记录、不发送', model[secret_guard:secret_guard + 400])

    def test_causal_guards_and_nas_window_preserved(self):
        model = source('Sources/Model.swift')
        self.assertIn('SyncMode.launch == .drive ? 300_000 : 10_000', model)
        self.assertIn('r.created > clipboardWatermark', model)
        self.assertIn('image.manifest.created > clipboardWatermark', model)
        self.assertGreaterEqual(model.count('pasteboard.changeCount == expectedChange'), 2)
        self.assertIn('token == self.generation && Date() >= self.holdUntil', source('Sources/DriveCloud.swift'))

    def test_restart_switch_freezes_old_transport_and_capture(self):
        setup = source('Sources/SyncSetup.swift')
        self.assertIn('nas = SyncMode.launch == .nas ? NASController() : nil', setup)
        self.assertIn('drive = SyncMode.launch == .drive ? DriveController() : nil', setup)
        self.assertLess(setup.index('nas?.shutdown(); drive?.shutdown()'), setup.index('UserDefaults.standard.set(next.rawValue'))
        self.assertIn('restartRequired = true', setup)
        self.assertIn('guard !cloud.restartRequired else { lastChange = count; return }', source('Sources/Model.swift'))
        for file in ['Sources/Cloud.swift', 'Sources/DriveCloud.swift']:
            controller = source(file)
            self.assertIn('autoConnectionAllowed = false; timer?.invalidate(); timer = nil', controller)
            self.assertIn('operationGate.update(active: false)', controller)

    def test_invalid_mode_fails_closed_and_pause_stays_frozen(self):
        setup = source('Sources/SyncSetup.swift')
        self.assertIn('if UserDefaults.standard.object(forKey: "selectedSyncMode") != nil', setup)
        self.assertIn('let mode = SyncMode(rawValue: saved) else { return .local }', setup)
        self.assertLess(setup.index('else { return .local }'), setup.index('forKey: "syncSpace"'))
        toggle = source('Sources/Model.swift').split('func togglePause() {', 1)[1].split('func refresh()', 1)[0]
        self.assertLess(toggle.index('guard !cloud.restartRequired'), toggle.index('paused.toggle()'))
        self.assertIn('重新打开轻贴', toggle)

    def test_ai_help_is_whitelisted_and_copy_only(self):
        setup = source('Sources/SyncSetup.swift')
        prompt = setup.split('    var helpPrompt: String {', 1)[1].split('struct SyncSetupSettings:', 1)[0]
        for forbidden in ['.folder', 'folderInput', 'pairCode', 'pathDiagnostics', 'error.localizedDescription', 'Host.current', 'userName', 'pasteboard']:
            self.assertNotIn(forbidden, prompt)
        self.assertIn('DriveController.providers.contains(choice)', prompt)
        self.assertIn('只读检查', prompt)
        self.assertIn('不要关闭系统安全保护', prompt)
        model = source('Sources/Model.swift')
        copier = model.split('func copyAIHelp(', 1)[1].split('@discardableResult func receive', 1)[0]
        self.assertIn('org.nspasteboard.ConcealedType', copier)
        self.assertIn('lastChange = pasteboard.changeCount', copier)
        self.assertNotIn('store.', copier)
        self.assertNotIn('cloud.send', copier)

if __name__ == '__main__': unittest.main()
