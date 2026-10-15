import AppKit
import SwiftUI

struct ClipRow: View {
    let clip: Clip
    @ObservedObject var model: ClipboardModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { model.paste(clip) } label: {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Color.teal.opacity(0.10)).frame(width: 48, height: 48)
                        if clip.kind == .image, let image = NSImage(data: clip.data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                        } else { Image(systemName: "text.alignleft").font(.title3).foregroundStyle(.teal) }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(clip.preview).font(.system(size: 13)).lineLimit(4).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            Text(clip.created.formatted(date: .omitted, time: .shortened))
                            Text("·")
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clip.data.count), countStyle: .file))
                            Text("·")
                            Text("\(max(1, Int(ceil(clip.expires.timeIntervalSinceNow / 3600)))) 小时内到期")
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("直接粘贴到之前选中的应用窗口")
                .contextMenu { Button("仅复制，不粘贴") { model.copy(clip) }; Button("保存到下载") { model.export(clip) } }
            VStack(spacing: 9) {
                Button { model.export(clip) } label: { Image(systemName: "square.and.arrow.down").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).foregroundStyle(.teal).help("一键保存到下载文件夹")
                Button { model.remove(clip) } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 18) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("删除这条历史")
            }
        }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsView: View {
    @ObservedObject var model: ClipboardModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("全局快捷键", systemImage: "keyboard").font(.headline)
                    Text("当前：\(model.activeShortcutName)").font(.title2).monospaced()
                    HStack {
                        Button(model.recording ? "请按组合键…（Esc 取消）" : "录制新快捷键") { model.recording.toggle() }
                            .buttonStyle(.borderedProminent).tint(.teal)
                        Button("恢复默认 ⌃⌥V") { model.recording = false; model.applyShortcut(.standard) }
                        Button("重新检测") { model.recording = false; model.applyShortcut(model.shortcut) }
                    }
                    if !model.shortcutMessage.isEmpty {
                        Label(model.shortcutMessage, systemImage: model.shortcutOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(model.shortcutOK ? Color.teal : Color.orange).font(.callout)
                    }
                    Text("自动检查已启用的 macOS 系统快捷键，并尝试独占注册来检测全局占用。有冲突时保留原快捷键。其他软件的应用内快捷键、按键监听和未来新增的占用无法完整检测。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("选中历史，直接粘贴", systemImage: "doc.on.clipboard").font(.headline)
                    Text("先点选其他程序的输入位置，再用快捷键或菜单栏打开轻贴。点击一条历史，会返回原窗口并执行粘贴，不会发送回车。")
                        .font(.callout)
                    Label(model.pasteAuthorized ? "辅助功能已授权，可以直接粘贴" : "需要辅助功能权限", systemImage: model.pasteAuthorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.pasteAuthorized ? Color.teal : Color.orange)
                    Button(model.pasteAuthorized ? "查看辅助功能设置" : "开启直接粘贴…") { AutoPaster.openPermissions() }
                    Text("在系统设置 → 隐私与安全性 → 辅助功能中开启“轻贴”。未授权时只会复制并提示，不会假装粘贴成功。右键历史可选择“仅复制”。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("后台运行", systemImage: "menubar.rectangle").font(.headline)
                    Toggle("登录 Mac 时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) })).toggleStyle(.switch)
                    if !model.loginMessage.isEmpty { Text(model.loginMessage).font(.caption).foregroundStyle(.orange) }
                    Text("关闭窗口后仍在菜单栏记录。退出应用期间不记录；再次打开时，先删除已过期历史。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("24 小时滚动保留", systemImage: "clock.arrow.circlepath").font(.headline)
                    Text("每条内容从复制时独立计时，约每 10 秒清理到期记录。重复复制同一内容会更新其时间，点击历史重新复制不会延长保留时间。")
                    Text("保存按钮把文字写成 TXT、图片写成 PNG，直接放进“下载”。保存后的文件不会跟随历史到期删除。")
                    Text("只记录文字和图片，不记录文件复制。单条最多 20 MB，总计最多 200 MB / 2,000 条；超限时淘汰最早记录。")
                }.font(.callout)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("本机保存", systemImage: "lock.shield").font(.headline)
                    Text("不联网、不上传。跳过来源应用标记为私密或临时的内容；未标记的密码仍可能被记录，需要时可先暂停。历史清理不会清除系统当前剪贴板。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(model.paused ? "继续记录" : "暂停记录") { model.togglePause() }
                        Button("清空历史…") { model.clear() }.disabled(model.clips.isEmpty)
                        Spacer()
                        Button("退出轻贴") { NSApp.terminate(nil) }
                    }
                }
            }.padding(4)
        }.onDisappear { model.recording = false }
    }
}

struct ContentView: View {
    @ObservedObject var model: ClipboardModel
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "doc.on.clipboard.fill").font(.system(size: 29)).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text("轻贴").font(.system(size: 25, weight: .bold))
                    Text("复制过的，都在这一天里。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.togglePause() } label: { Image(systemName: model.paused ? "play.circle" : "pause.circle").font(.title3) }.buttonStyle(.borderless).help(model.paused ? "继续记录" : "暂停记录")
                Button { model.settings.toggle(); model.recording = false } label: { Image(systemName: model.settings ? "list.bullet.rectangle" : "gearshape").font(.title3) }.buttonStyle(.borderless).help(model.settings ? "返回历史" : "设置")
            }
            if model.settings { SettingsView(model: model) }
            else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索复制过的文字…", text: $model.query).textFieldStyle(.plain).focused($searchFocused)
                    if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    Text(model.activeShortcutName).font(.caption).foregroundStyle(.secondary)
                }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Label(model.paused ? "已暂停" : "正在记录", systemImage: model.paused ? "pause.fill" : "circle.fill").font(.caption).foregroundStyle(model.paused ? Color.orange : Color.teal)
                    Spacer()
                    Text("\(model.filtered.count) 条 · 每条保留 24 小时").font(.caption).foregroundStyle(.secondary)
                }
                if !model.shortcutOK { Button { model.settings = true } label: { Label("快捷键需要调整，点击查看", systemImage: "exclamationmark.triangle") }.buttonStyle(.plain).font(.caption).foregroundStyle(.orange) }
                if let issue = model.captureIssue { Label(issue, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                if !model.pasteAuthorized {
                    HStack {
                        Label("开启辅助功能后，点历史即可直接粘贴", systemImage: "hand.point.up.left").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("开启…") { AutoPaster.openPermissions() }.controlSize(.small)
                    }
                } else {
                    Text(model.pasteTargetName.isEmpty ? "先点选目标输入框，再打开轻贴" : "点击记录 → 粘贴到 \(model.pasteTargetName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.filtered.isEmpty {
                    VStack(spacing: 15) {
                        Image(systemName: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass").font(.system(size: 48)).foregroundStyle(.teal.opacity(0.5))
                        Text(model.query.isEmpty ? "从下一次复制开始" : "没有匹配的内容").font(.title3).fontWeight(.semibold)
                        Text(model.query.isEmpty ? "复制文字或图片，回来就能找到。\n点记录直接粘贴，点右侧保存到下载。" : "试试其他关键词。")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout).lineSpacing(5)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView { LazyVStack(spacing: 9) { ForEach(model.filtered) { ClipRow(clip: $0, model: model) } }.padding(.vertical, 2) }
                }
            }
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    if let url = model.savedURL {
                        Button("在下载中显示最近保存的文件") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.font(.caption).buttonStyle(.link)
                    }
                }
                Spacer()
            }.frame(minHeight: 35)
        }.padding(22).frame(minWidth: 570, minHeight: 620)
        .onReceive(NotificationCenter.default.publisher(for: .clipDayShown)) { _ in model.refresh(); if !model.settings { searchFocused = true } }
    }
}

extension Notification.Name { static let clipDayShown = Notification.Name("clipDayShown") }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: ClipboardModel!
    var window: NSWindow!
    var status: NSStatusItem!
    var pasteTarget: PasteTarget?
    var activationObserver: NSObjectProtocol?
    var diagnosticObserver: NSObjectProtocol?
    let paster = AutoPaster()
    func applicationDidFinishLaunching(_ notification: Notification) {
        installStandardMenus()
        model = ClipboardModel()
        diagnosticObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("io.jlmac.ClipDay.requestStatus"), object: nil, queue: .main) { [weak self] _ in self?.writeDiagnosticState() }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "轻贴"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 600, height: 680)
        window.contentView = NSHostingView(rootView: ContentView(model: model)); window.center()
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "轻贴剪贴板历史")
        status.button?.target = self; status.button?.action = #selector(statusClick)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        status.button?.toolTip = "轻贴 · 剪贴板历史"
        model.onShow = { [weak self] in self?.toggleWindow() }
        model.onPaste = { [weak self] in self?.pasteSelected() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self.captureTarget(app)
        }
        showWindow()
    }
    func writeDiagnosticState() {
        var state = model.diagnosticState
        state["frontmostPID"] = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        state["targetPID"] = pasteTarget?.app.processIdentifier ?? 0
        state["windowVisible"] = window.isVisible
        state["windowIsKey"] = window.isKeyWindow
        state["timestamp"] = Date().timeIntervalSince1970
        // On-demand metadata only: never clipboard content, types or hashes.
        let directory = model.store.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            let file = directory.appendingPathComponent("runtime-status.json")
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
    func installStandardMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出轻贴", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = main
    }
    func captureTarget(_ app: NSRunningApplication) {
        pasteTarget = PasteTarget(app: app)
        model.pasteTargetName = app.localizedName ?? "目标应用"
    }
    func pasteSelected() {
        model.refresh()
        guard model.pasteAuthorized else {
            model.message = "内容已复制，但尚未粘贴。请点击上方“开启…”并允许轻贴的辅助功能权限。"
            return
        }
        guard let target = pasteTarget else {
            model.message = "没有目标窗口。请先点选目标输入框，再按快捷键打开轻贴。"
            return
        }
        window.orderOut(nil)
        paster.paste(to: target, pasteboard: model.pasteboard) { [weak self] error in
            guard let self else { return }
            if let error {
                self.model.message = error
                // Reopen only if no unrelated application has taken focus.
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if front == target.app.processIdentifier || front == ProcessInfo.processInfo.processIdentifier {
                    self.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                }
            } else { self.model.message = "已向 \(target.app.localizedName ?? "目标应用") 执行粘贴。" }
        }
    }
    @objc func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开轻贴", action: #selector(showWindow), keyEquivalent: "").target = self
            menu.addItem(withTitle: model.paused ? "继续记录" : "暂停记录", action: #selector(pause), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出轻贴", action: #selector(quit), keyEquivalent: "").target = self
            status.menu = menu; status.button?.performClick(nil); status.menu = nil
        } else { toggleWindow() }
    }
    @objc func pause() { model.togglePause() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func showWindow() {
        paster.cancel()
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { captureTarget(app) }
        model.refresh(); model.refreshLogin()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .clipDayShown, object: nil)
    }
    func toggleWindow() {
        if window.isKeyWindow && window.isVisible { window.orderOut(nil) } else { showWindow() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main enum ClipDayApp {
    static func main() {
        if CommandLine.arguments.contains("--request-status") {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.jlmac.ClipDay.requestStatus"), object: nil, userInfo: nil, deliverImmediately: true)
            return
        }
        if CommandLine.arguments.contains("--paste-status") {
            print("directPasteAuthorized=\(AutoPaster.authorized)")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
