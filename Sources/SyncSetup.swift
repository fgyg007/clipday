#if CLOUD
import AppKit
import SwiftUI

enum SyncMode: String, CaseIterable, Identifiable {
    case local, nas, drive
    var id: String { rawValue }
    var title: String {
        switch self { case .local: return "仅本机"; case .nas: return "NAS（含 Android）"; case .drive: return "网盘同步文件夹（仅电脑）" }
    }
    // Immutable for this process. Existing NAS installations retain their mode and data.
    static let launch: SyncMode = {
        if UserDefaults.standard.object(forKey: "selectedSyncMode") != nil {
            guard let saved = UserDefaults.standard.string(forKey: "selectedSyncMode"), let mode = SyncMode(rawValue: saved) else { return .local }
            return mode
        }
        if UserDefaults.standard.string(forKey: "syncSpace") != nil || UserDefaults.standard.string(forKey: "syncFolder") != nil { return .nas }
        let legacyHistory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/io.jlmac.ClipDay.Cloud/history.json")
        if FileManager.default.fileExists(atPath: legacyHistory.path) { return .nas }
        return .local
    }()
}

final class CloudController: ObservableObject {
    let mode = SyncMode.launch
    let nas: NASController?
    let drive: DriveController?
    @Published private(set) var restartRequired = false
    @Published private(set) var requestedMode = SyncMode.launch
    private weak var model: ClipboardModel?
    init() {
        // Exactly one transport object exists; local-only creates neither.
        nas = SyncMode.launch == .nas ? NASController() : nil
        drive = SyncMode.launch == .drive ? DriveController() : nil
    }
    func start(model: ClipboardModel, startMonitoring: Bool = true) {
        self.model = model
        nas?.start(model: model, startMonitoring: startMonitoring)
        drive?.start(model: model, startMonitoring: startMonitoring)
    }
    func setPrivacyPaused(_ paused: Bool) {
        guard !restartRequired else { return }
        nas?.setPrivacyPaused(paused); drive?.setPrivacyPaused(paused)
    }
    func localActivity() { guard !restartRequired else { return }; nas?.localActivity(); drive?.localActivity() }
    var imageQueueSpace: String? { restartRequired ? nil : (nas?.imageQueueSpace ?? drive?.imageQueueSpace) }
    func send(_ text: String, created: Date = Date(), id: UUID = UUID()) {
        guard !restartRequired else { return }
        nas?.send(text, created: created, id: id); drive?.send(text, created: created, id: id)
    }
    func sendImage(_ png: Data, created: Date = Date(), id: UUID = UUID()) {
        guard !restartRequired else { return }
        nas?.sendImage(png, created: created, id: id); drive?.sendImage(png, created: created, id: id)
    }
    func selectMode(_ next: SyncMode) {
        guard !restartRequired, next != mode else { return }
        let alert = NSAlert(); alert.messageText = "切换到“\(next.title)”并在重启后生效？"
        alert.informativeText = "现在会停止本软件记录和同步，并保留原模式的历史、密钥与待发队列。请自行退出后重新打开轻贴；不会同时运行两种同步，也不会搬运旧历史到新模式。已开始的单次文件写入可能完成，网盘客户端不受控制。"
        alert.addButton(withTitle: "保存选择并暂停"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Shut down gates/timers before persisting the next process's mode.
        nas?.shutdown(); drive?.shutdown()
        restartRequired = true; requestedMode = next
        model?.paused = true
        UserDefaults.standard.set(next.rawValue, forKey: "selectedSyncMode")
    }
    var helpPrompt: String {
        let provider: String
        if let choice = drive?.provider, DriveController.providers.contains(choice) { provider = choice } else { provider = "未选择或不适用" }
        let state = restartRequired ? "等待用户重启" : ((nas?.privacyPaused == true || drive?.privacyPaused == true) ? "隐私暂停" : ((nas?.ready == true || drive?.ready == true) ? "本机配置已加载，远端收到未知" : "尚未完成连接检查"))
        return """
        请帮我排查轻贴配置。系统：macOS。模式：\(mode.title)。网盘来源：\(provider)。通用状态：\(state)。
        请先做只读检查，逐步说明。确认目录存在、权限、双向同步与完整本地保留，不要把本地写入当作云端或另一设备已收到。需要安装软件、修改网络或安全设置前必须先问我，不要关闭系统安全保护。不要索取密码、同步密钥、配对信息、令牌或剪贴板内容；路径、服务器和账户信息请让我自行脱敏。这里只提供排查说明，不代表已完成真机验证。
        """
    }
}

struct SyncSetupSettings: View {
    @ObservedObject var cloud: CloudController
    @ObservedObject var model: ClipboardModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("轻贴 · 同步设置与新手引导", systemImage: "arrow.triangle.2.circlepath").font(.headline)
            Text("当前模式：" + cloud.mode.title)
            Text("先按使用场景选择：需要 Android 手机参与，选择 NAS；仅电脑且已有真正双向同步的网盘文件夹，选择网盘；只要剪贴板历史，选择仅本机。")
            HStack {
                ForEach(SyncMode.allCases) { mode in
                    Button(mode.title) { cloud.selectMode(mode) }.disabled(cloud.restartRequired || mode == cloud.mode)
                }
            }
            if cloud.restartRequired {
                Text("已暂停记录和同步。请自行退出并重新打开轻贴，进入“" + cloud.requestedMode.title + "”。旧模式数据仍保留；重启会建立新的剪贴板读取基线，不搬运当前剪贴板。")
                    .foregroundStyle(.orange)
            } else if let nas = cloud.nas {
                Text("NAS 引导：先在访达连接共享，确认读写权限，再检查目录。第一台创建空间，另一台或 Android 加入同一空间。路径检查只证明本机可访问，不证明另一端已经收到。")
                NASSettings(cloud: nas)
            } else if let drive = cloud.drive {
                DriveSettings(cloud: drive)
            } else {
                Text("仅保存本机历史，不创建同步连接或发送队列。需要时可选择其他模式并重启。")
                Text("独立轻贴 v1.2.0 的功能与历史迁移仍待审查；这里不会读取、搬运或删除原独立版本数据。昵称相同不代表迁移已完成。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("配置遇到问题？仅复制系统、模式、网盘来源及通用状态，不包含路径、服务器、用户名、IP、密钥、令牌或剪贴板内容。你检查后自行粘贴给 AI；轻贴不会发送。")
                .font(.caption).foregroundStyle(.secondary)
            Button("复制脱敏 AI 求助说明") { model.copyAIHelp(cloud.helpPrompt) }
            Text("验证建议：先复制无隐私测试文字，再复制测试图片，在另一端核对内容。检查通过与本地写入均不等于云端交付成功。原生构建及真实设备互通尚待验收。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
