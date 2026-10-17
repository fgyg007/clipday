import Foundation
let appTitle = "轻贴"
#if CLOUD
let appBundleID = "io.jlmac.ClipDay.Cloud" // Preserve installed NAS identity and upgrade storage.
let appDataDirectory: URL = {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/" + appBundleID)
    switch SyncMode.launch {
    case .nas: return root
    case .drive: return root.appendingPathComponent("drive-history")
    case .local: return root.appendingPathComponent("local-history")
    }
}()
#else
let appBundleID = "io.jlmac.ClipDay"
let appDataDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/" + appBundleID)
#endif
import AppKit
import SwiftUI
import ServiceManagement

final class ClipboardModel: ObservableObject {
    #if CLOUD
    let cloud = CloudController()
    #endif
    @Published var clips: [Clip] = []
    @Published var query = ""
    @Published var paused: Bool {
        didSet {
            guard paused != oldValue else { return }
            lastChange = pasteboard.changeCount
            pendingCapture = nil; captureRetryAt = .distantPast; captureFailures = 0
            captureIssue = nil
            #if CLOUD
            cloud.setPrivacyPaused(paused)
            #endif
        }
    }
    @Published var message = "复制文字或图片后，会自动出现在这里。"
    @Published var savedURL: URL?
    @Published var shortcut: Shortcut = .standard
    @Published var shortcutMessage = ""
    @Published var shortcutOK = false
    @Published var recording = false
    @Published var loginEnabled = false
    @Published var loginMessage = ""
    @Published var settings = false
    @Published var pasteAuthorized = AutoPaster.authorized
    @Published var pasteTargetName = ""
    @Published var captureIssue: String?
    @Published var lastCapturedAt: Date?
    @Published var historyIssue: String?
    let store: ClipStore
    let hotKey = HotKeyManager()
    let pasteboard: NSPasteboard
    private var timer: Timer?
    private var monitor: Any?
    private var wakeObserver: NSObjectProtocol?
    private var lastChange: Int
    #if CLOUD
    private var clipboardWatermark: Int64 = 0 // Shared across text and images.
    #endif
    private var lastPrune = Date.distantPast
    private var lastTickAt: Date?
    private struct PendingCapture {
        let change: Int
        let kind: ClipKind
        let data: Data
        let created: Date
        let id = UUID()
    }
    private var pendingCapture: PendingCapture?
    private var captureRetryAt = Date.distantPast
    private var captureFailures = 0
    var pauseActionTitle: String {
        #if CLOUD
        return paused ? "解除隐私暂停" : "隐私暂停"
        #else
        return paused ? "继续记录" : "暂停记录"
        #endif
    }
    var recordingStatusTitle: String {
        guard paused else { return "正在记录" }
        #if CLOUD
        return "已隐私暂停"
        #else
        return "已暂停"
        #endif
    }
    private func updateHistoryIssue() {
        historyIssue = store.unavailableCount > 0 ? "有 \(store.unavailableCount) 条历史文件缺失或损坏，已隔离；其他历史和新记录不受影响，文件恢复后会重试。" : nil
    }
    var diagnosticState: [String: Any] {
        var result: [String: Any] = ["paused": paused, "recordingShortcut": recording, "storedCount": clips.count,
            "lastProcessedChange": lastChange, "currentChange": pasteboard.changeCount,
            "lastTickAt": lastTickAt?.timeIntervalSince1970 ?? 0, "captureIssue": captureIssue ?? "", "pasteAuthorized": pasteAuthorized,
            "activeShortcut": activeShortcutName]
        if #available(macOS 15.4, *) { result["pasteboardAccessBehavior"] = pasteboard.accessBehavior.rawValue }
        return result
    }
    var onPaste: (() -> Void)?
    var onShow: (() -> Void)?
    var activeShortcutName: String { hotKey.current?.label ?? "未启用快捷键" }
    var filtered: [Clip] {
        query.isEmpty ? clips : clips.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    init(store: ClipStore = ClipStore(directory: appDataDirectory), pasteboard: NSPasteboard = .general, startMonitoring: Bool = true) {
        self.store = store; self.pasteboard = pasteboard
        self.paused = UserDefaults.standard.bool(forKey: "paused")
        self.lastChange = pasteboard.changeCount
        do { try store.load(); clips = store.clips; lastCapturedAt = clips.first?.created; updateHistoryIssue() }
        catch { paused = true; message = "读取历史失败，已暂停记录：\(error.localizedDescription)" }
        if let data = UserDefaults.standard.data(forKey: "shortcut"), let saved = try? JSONDecoder().decode(Shortcut.self, from: data) { shortcut = saved }
        if startMonitoring {
            hotKey.onPress = { [weak self] in self?.onShow?() }
            applyShortcut(shortcut)
            timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.tick() }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.recording else { return event }
                if event.keyCode == 53 { self.recording = false; return nil }
                self.recording = false; self.applyShortcut(Shortcut.from(event)); return nil
            }
        }
        refreshLogin()
        #if CLOUD
        cloud.start(model: self, startMonitoring: startMonitoring)
        #endif
    }
    deinit {
        timer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
    func applyShortcut(_ proposed: Shortcut) {
        do {
            try hotKey.set(proposed)
            shortcut = proposed
            UserDefaults.standard.set(try JSONEncoder().encode(proposed), forKey: "shortcut")
            shortcutMessage = "检测通过，\(proposed.label) 已启用。"; shortcutOK = true
        } catch { shortcutMessage = error.localizedDescription; shortcutOK = false }
    }
    func refreshLogin() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval { loginMessage = "请在系统设置 → 通用 → 登录项中允许启动。" }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage = ""; refreshLogin()
        } catch { loginMessage = error.localizedDescription; refreshLogin() }
    }
    func togglePause() {
        #if CLOUD
        guard !cloud.restartRequired else {
            message = "同步模式已更改，请自行退出并重新打开轻贴后再恢复记录。"
            return
        }
        #endif
        paused.toggle(); UserDefaults.standard.set(paused, forKey: "paused")
        #if CLOUD
        message = paused ? "隐私暂停：停止记录、发送和接收；不会清空历史或待发队列，已有记录仍按 24 小时到期。" : "隐私暂停已解除，下一次复制开始记录；同步遵循原来的开关。"
        #else
        message = paused ? "已暂停记录；已有记录仍按 24 小时到期删除。" : "已恢复记录，下一次复制开始生效。"
        #endif
    }
    func refresh() {
        pasteAuthorized = AutoPaster.authorized
        do { try store.prune(); clips = store.clips; updateHistoryIssue(); lastPrune = Date() }
        catch { message = "清理历史失败：\(error.localizedDescription)" }
    }
    func tick(now: Date = Date()) {
        lastTickAt = now
        if Date().timeIntervalSince(lastPrune) >= 10 || Date() < lastPrune { refresh() }
        let count = pasteboard.changeCount
        #if CLOUD
        guard !cloud.restartRequired else { lastChange = count; return }
        #endif
        guard count != lastChange else { return }
        if pendingCapture?.change != count { pendingCapture = nil; captureFailures = 0; captureRetryAt = .distantPast; captureIssue = nil }
        #if CLOUD
        cloud.localActivity()
        clipboardWatermark = max(clipboardWatermark, SyncWire.ms(now))
        #endif
        guard !paused else { lastChange = count; return }
        guard now >= captureRetryAt else { return }
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .alwaysDeny {
            captureIssue = "macOS 禁止轻贴读取其他应用的剪贴板。请在系统设置中允许轻贴的粘贴访问。"
            return
        }
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let privateTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        if !types.isDisjoint(with: privateTypes) { lastChange = count; captureIssue = nil; message = "已跳过标记为私密或临时的剪贴板内容。"; return }
        #if CLOUD
        // Pairing information is a decryption key, not syncable clipboard history.
        // Also reject manually copied secrets before image/text priority handling.
        if let text = pasteboard.string(forType: .string),
           text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("clipday-drive1:") {
            lastChange = count; pendingCapture = nil; captureIssue = nil
            message = "已跳过云盘秘密配对信息，不记录、不发送。"
            return
        }
        #endif
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { lastChange = count; captureIssue = nil; return }
        do {
            let kind: ClipKind, data: Data
            if let pending = pendingCapture {
                kind = pending.kind; data = pending.data
            } else if let png = pasteboard.data(forType: .png) {
                #if CLOUD
                do { data = try ImageSafety.clipboardPNG(png) }
                catch { lastChange = count; message = "图片过大、为动画或无法读取，未记录。仅支持静态 PNG，最长边 8192 且不超过 1600 万像素。"; return }
                #else
                guard png.count <= ClipStore.maxItemBytes, NSBitmapImageRep(data: png) != nil else { lastChange = count; message = "图片过大或无法读取，未记录。"; return }
                data = png
                #endif
                kind = .image
            } else if let tiff = pasteboard.data(forType: .tiff) {
                #if CLOUD
                do { data = try ImageSafety.fromTIFF(tiff) }
                catch { lastChange = count; message = "图片过大、为动画或无法读取，未记录。"; return }
                kind = .image
                #else
                guard tiff.count <= 80 * 1024 * 1024, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { lastChange = count; message = "图片过大或无法读取，未记录。"; return }
                kind = .image; data = png
                #endif
            } else if let string = pasteboard.string(forType: .string), !string.isEmpty {
                kind = .text; data = Data(string.utf8)
            } else {
                // clearContents/declareTypes can precede delivery of data without
                // another changeCount increment. Retry this version until readable.
                if !types.isEmpty { captureIssue = "新复制内容暂时无法读取，正在重试；如有系统粘贴访问提示，请允许。" }
                return
            }
            guard pasteboard.changeCount == count else { return }
            guard data.count <= ClipStore.maxItemBytes else { lastChange = count; message = "单条内容超过 20 MB，未记录。"; return }
            let pending = pendingCapture ?? PendingCapture(change: count, kind: kind, data: data, created: now)
            guard pending.created.addingTimeInterval(ClipStore.lifetime) > now else {
                pendingCapture = nil; lastChange = count; captureIssue = nil
                message = "未保存内容已超过 24 小时，已停止重试。"; return
            }
            pendingCapture = pending
            #if CLOUD
            // The queue intent is committed atomically with the existing history
            // index. A restart before encrypted enqueue resumes the same ID/TTL.
            let imageSpace = kind == .image ? cloud.imageQueueSpace : nil
            try store.append(kind: kind, data: data, now: now, id: pending.id, created: pending.created, imageSyncSpace: imageSpace)
            #else
            try store.append(kind: kind, data: data, now: now, id: pending.id, created: pending.created)
            #endif
            pendingCapture = nil; captureFailures = 0; captureRetryAt = .distantPast
            lastChange = count; captureIssue = nil; lastCapturedAt = pending.created
            clips = store.clips
            #if CLOUD
            if kind == .text { cloud.send(String(data: data, encoding: .utf8)!, created: pending.created, id: pending.id) }
            else { cloud.sendImage(data, created: pending.created, id: pending.id) }
            #endif
            message = store.lastEvictedCount > 0 ? "已记录；容量达到上限，已淘汰最早的 \(store.lastEvictedCount) 条。" : "已记录\(kind == .text ? "文字" : "图片")，24 小时后自动删除。"
        } catch {
            captureFailures += 1
            let delay = min(30.0, pow(2.0, Double(min(captureFailures - 1, 5))))
            captureRetryAt = now.addingTimeInterval(delay)
            captureIssue = "尚未保存，\(Int(delay)) 秒后重试：\(error.localizedDescription)"
            message = captureIssue ?? "未能记录"
        }
    }
    #if CLOUD
    private var remoteClipboardWindow: Int64 { SyncMode.launch == .drive ? 300_000 : 10_000 }
    func copyAIHelp(_ text: String) {
        // Generated guidance is not user clipboard history and must not sync.
        pendingCapture = nil; captureRetryAt = .distantPast; captureFailures = 0
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        let copied = pasteboard.setString(text, forType: .string)
        lastChange = pasteboard.changeCount
        clipboardWatermark = SyncWire.ms(); cloud.localActivity()
        message = copied ? "已复制脱敏求助说明；请自行检查后粘贴给 AI，尚未向任何服务发送。" : "复制失败，请重试。"
    }
    @discardableResult func receive(_ records: [SyncRecord], automatic: SyncRecord?, expectedChange: Int) -> Bool {
        guard !paused, !cloud.restartRequired else { return false }
        do {
            try store.importTexts(records.map { r in
                (id: UUID(uuidString: r.id)!, text: r.text, created: Date(timeIntervalSince1970: Double(r.created) / 1000), source: r.name)
            })
            clips = store.clips
            if let r = automatic, pasteboard.changeCount == expectedChange, lastChange == expectedChange, !paused, r.created > clipboardWatermark, r.created <= SyncWire.ms(), SyncWire.ms() - r.created <= remoteClipboardWindow {
                pasteboard.clearContents()
                let ok = pasteboard.setString(r.text, forType: .string)
                lastChange = pasteboard.changeCount
                clipboardWatermark = r.created
                message = ok ? "收到来自 \(r.name) 的文字，可直接按 ⌘V 粘贴。" : "已收到文字，请从历史重新复制。"
            }
            return true
        } catch { message = "同步记录保存失败：\(error.localizedDescription)"; return false }
    }
    @discardableResult func receiveImages(_ records: [ReceivedImage], automatic: ReceivedImage?, expectedChange: Int) -> Bool {
        guard !paused, !cloud.restartRequired else { return false }
        do {
            try store.importImages(records)
            clips = store.clips
            if let image = automatic, records.contains(where: { $0.manifest.id == image.manifest.id }),
               pasteboard.changeCount == expectedChange, lastChange == expectedChange, !paused,
               image.manifest.created > clipboardWatermark, image.manifest.created <= SyncWire.ms(), SyncWire.ms() - image.manifest.created <= remoteClipboardWindow,
               image.manifest.expires > SyncWire.ms() {
                try ImageWire.verify(image.png, manifest: image.manifest)
                pasteboard.clearContents()
                let ok = pasteboard.setData(image.png, forType: .png)
                lastChange = pasteboard.changeCount // Prevent cloud → clipboard → cloud loops.
                clipboardWatermark = image.manifest.created
                message = ok ? "收到来自 \(image.manifest.name) 的图片，可直接按 ⌘V 粘贴。" : "已收到图片，请从历史重新复制。"
            }
            return true
        } catch { message = "同步图片保存失败，稍后重试：\(error.localizedDescription)"; return false }
    }
    #endif
    func paste(_ clip: Clip) {
        if copy(clip) { onPaste?() }
    }
    @discardableResult func copy(_ clip: Clip) -> Bool {
        do {
            // Capture a just-copied external item before a history selection
            // temporarily replaces the general pasteboard.
            tick()
            let current = try store.active(clip.id)
            #if CLOUD
            let imageData = current.kind == .image ? try ImageSafety.clipboardPNG(current.data) : current.data
            cloud.localActivity()
            clipboardWatermark = max(clipboardWatermark, SyncWire.ms())
            #endif
            pasteboard.clearContents()
            #if CLOUD
            let ok = current.kind == .text ? pasteboard.setString(current.text, forType: .string) : pasteboard.setData(imageData, forType: .png)
            #else
            let ok = current.kind == .text ? pasteboard.setString(current.text, forType: .string) : pasteboard.setData(current.data, forType: .png)
            #endif
            lastChange = pasteboard.changeCount
            guard ok else { throw ClipError.message("写入系统剪贴板失败，请重试。") }
            message = "已复制，回到目标应用按 ⌘V 粘贴。"
            return true
        } catch { message = error.localizedDescription; refresh(); return false }
    }
    func export(_ clip: Clip) {
        do {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            let url = try store.export(clip.id, to: downloads)
            savedURL = url; message = "已保存到下载：\(url.lastPathComponent)"
        } catch { message = "保存失败：\(error.localizedDescription)"; refresh() }
    }
    func remove(_ clip: Clip) {
        do { try store.remove(clip.id); clips = store.clips } catch { message = error.localizedDescription }
    }
    func clear() {
        let alert = NSAlert(); alert.messageText = "清空全部剪贴板历史？"
        alert.informativeText = "历史记录会立即删除，已保存到下载的文件不受影响。系统当前剪贴板保持不变。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清空历史")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try store.clear(); clips = []; message = "历史已清空。" } catch { message = error.localizedDescription }
    }
}
