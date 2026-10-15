import AppKit
import SwiftUI
import ServiceManagement

final class ClipboardModel: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var query = ""
    @Published var paused: Bool
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
    let store: ClipStore
    let hotKey = HotKeyManager()
    let pasteboard: NSPasteboard
    private var timer: Timer?
    private var monitor: Any?
    private var wakeObserver: NSObjectProtocol?
    private var lastChange: Int
    private var lastPrune = Date.distantPast
    private var lastTickAt: Date?
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

    init(store: ClipStore = ClipStore(), pasteboard: NSPasteboard = .general, startMonitoring: Bool = true) {
        self.store = store; self.pasteboard = pasteboard
        self.paused = UserDefaults.standard.bool(forKey: "paused")
        self.lastChange = pasteboard.changeCount
        do { try store.load(); clips = store.clips; lastCapturedAt = clips.first?.created }
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
        paused.toggle(); UserDefaults.standard.set(paused, forKey: "paused")
        lastChange = pasteboard.changeCount
        message = paused ? "已暂停记录；已有记录仍按 24 小时到期删除。" : "已恢复记录，下一次复制开始生效。"
    }
    func refresh() {
        pasteAuthorized = AutoPaster.authorized
        do { try store.prune(); clips = store.clips; lastPrune = Date() }
        catch { message = "清理历史失败：\(error.localizedDescription)" }
    }
    func tick() {
        lastTickAt = Date()
        if Date().timeIntervalSince(lastPrune) >= 10 || Date() < lastPrune { refresh() }
        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        guard !paused else { lastChange = count; return }
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .alwaysDeny {
            captureIssue = "macOS 禁止轻贴读取其他应用的剪贴板。请在系统设置中允许轻贴的粘贴访问。"
            return
        }
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let privateTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        if !types.isDisjoint(with: privateTypes) { lastChange = count; captureIssue = nil; message = "已跳过标记为私密或临时的剪贴板内容。"; return }
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { lastChange = count; captureIssue = nil; return }
        do {
            let kind: ClipKind, data: Data
            if let png = pasteboard.data(forType: .png) {
                guard png.count <= ClipStore.maxItemBytes, NSBitmapImageRep(data: png) != nil else { lastChange = count; message = "图片过大或无法读取，未记录。"; return }
                kind = .image; data = png
            } else if let tiff = pasteboard.data(forType: .tiff) {
                guard tiff.count <= 80 * 1024 * 1024, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { lastChange = count; message = "图片过大或无法读取，未记录。"; return }
                kind = .image; data = png
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
            try store.append(kind: kind, data: data)
            lastChange = count; captureIssue = nil; lastCapturedAt = Date()
            clips = store.clips
            message = store.lastEvictedCount > 0 ? "已记录；容量达到上限，已淘汰最早的 \(store.lastEvictedCount) 条。" : "已记录\(kind == .text ? "文字" : "图片")，24 小时后自动删除。"
        } catch { captureIssue = "未能记录，将重试：\(error.localizedDescription)"; message = captureIssue ?? "未能记录" }
    }
    func paste(_ clip: Clip) {
        if copy(clip) { onPaste?() }
    }
    @discardableResult func copy(_ clip: Clip) -> Bool {
        do {
            // Capture a just-copied external item before a history selection
            // temporarily replaces the general pasteboard.
            tick()
            let current = try store.active(clip.id)
            pasteboard.clearContents()
            let ok = current.kind == .text ? pasteboard.setString(current.text, forType: .string) : pasteboard.setData(current.data, forType: .png)
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
