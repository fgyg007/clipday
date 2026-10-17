#if CLOUD
import AppKit
import SwiftUI
import Security

private enum PairVault {
    static let service = "io.jlmac.ClipDay.Cloud.sync"
    static func save(_ pair: SyncPair) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: pair.space]
        let data = try JSONEncoder().encode(pair)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw ClipError.message("无法把同步密钥保存到钥匙串。") }
        } else if status != errSecSuccess { throw ClipError.message("无法更新钥匙串中的同步密钥。") }
    }
    static func load(_ space: String) throws -> SyncPair {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: space, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { throw ClipError.message("无法读取同步密钥，请重新输入配对码。") }
        let pair = try JSONDecoder().decode(SyncPair.self, from: data); try pair.validate(); return pair
    }
}

final class NASController: ObservableObject {
    @Published var status = "尚未连接 NAS"
    @Published var folder = UserDefaults.standard.string(forKey: "syncFolder") ?? ""
    @Published var folderInput = UserDefaults.standard.string(forKey: "syncFolder") ?? ""
    @Published var enabled = UserDefaults.standard.bool(forKey: "syncEnabled")
    @Published var ready = false
    @Published var busy = false
    @Published var pairCode = ""
    @Published var pairExpires = Date.distantPast
    @Published var pairMessage = ""
    @Published var pairingActive = false
    @Published private(set) var privacyPaused = false
    @Published var pathDiagnostics = "尚未检查路径"
    @Published var deliveryStatus = "本机保存与上传是不同状态；当前协议不确认另一台设备是否已收到。"
    private let operationGate = SyncOperationGate()
    private var pairingProcess: PairingProcess?
    private var pairingToken = UUID()
    private let worker = DispatchQueue(label: "io.jlmac.ClipDay.Cloud.sync", qos: .utility)
    private var engine: FolderSync? // worker queue only
    private var imageEngine: ImageFolderSync? // same serialized worker, independent causal state
    private var timer: Timer?
    private var generation = 0
    private var activationID = UUID()
    private var holdUntil = Date.distantPast
    private var polling = false
    private weak var model: ClipboardModel?
    private var autoConnectionAllowed = false
    private var diagnosticID = UUID()
    private struct PendingSend {
        let id: String
        let text: String
        let created: Date
        let space: String
        var attempts = 0
        var retryAt = Date.distantPast
    }
    private var pendingSends: [String: PendingSend] = [:]
    private struct PendingImageSend {
        let id: String
        let png: Data
        let created: Date
        let space: String
        var attempts = 0
        var retryAt = Date.distantPast
    }
    private var pendingImages: [String: PendingImageSend] = [:]
    private var sendingImage = false
    private var sending = false
    private var activeSpace: String?
    init() {}
    func start(model: ClipboardModel, startMonitoring: Bool = true) {
        self.model = model; autoConnectionAllowed = startMonitoring
        setPrivacyPaused(model.paused, reconnect: false)
        guard startMonitoring else { return }
        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        restoreConnection()
    }
    private func restoreConnection() {
        guard autoConnectionAllowed, !privacyPaused, !ready, !busy, let space = UserDefaults.standard.string(forKey: "syncSpace"), !folder.isEmpty else { return }
        do { try activate(pair: PairVault.load(space), folder: URL(fileURLWithPath: folder), create: nil) }
        catch { status = error.localizedDescription }
    }
    func setPrivacyPaused(_ paused: Bool, reconnect: Bool = true) {
        privacyPaused = paused; generation += 1; diagnosticID = UUID()
        operationGate.update(active: !paused)
        worker.async { self.engine?.suspend(); self.imageEngine?.suspend() }
        if paused {
            activationID = UUID(); pairingToken = UUID(); pairingProcess?.cancel()
            busy = false; pairingActive = false; pairCode = ""; pairMessage = ""
            status = "隐私暂停：记录、发送、接收均已停止"
        } else {
            holdUntil = Date().addingTimeInterval(10)
            status = enabled ? "正在恢复连接检查…" : "同步已暂停，本地记录继续"
            if reconnect { restoreConnection(); poll() }
        }
    }
    func shutdown() {
        autoConnectionAllowed = false; timer?.invalidate(); timer = nil
        setPrivacyPaused(true, reconnect: false)
        operationGate.update(active: false)
    }
    deinit { timer?.invalidate(); pairingProcess?.cancel() }
    func browseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = false
        panel.prompt = "选择 NAS 文件夹"; panel.message = "两台电脑选择同一份 NAS 共享数据所在的文件夹。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderInput = url.path
    }
    private func inputFolder() -> URL? {
        let path = (folderInput.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !path.isEmpty else { status = "请先填写 NAS 文件夹路径，或点击浏览选择。"; return nil }
        guard path.hasPrefix("/") else {
            status = "请填写 Mac 上已挂载的路径，例如 /Volumes/共享/轻贴；smb:// 地址请先在访达中连接。"; return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
    func checkFolder() { diagnosePath() }
    private func diagnosePath(then: ((URL, NASPathDiagnostics, UUID) -> Void)? = nil) {
        guard !busy, let url = inputFolder() else { return }
        diagnosticID = UUID(); let token = diagnosticID
        busy = true; pathDiagnostics = "正在检查路径、读取与写入权限…"
        worker.async {
            let report = NASPathDiagnostics.inspect(url)
            DispatchQueue.main.async {
                guard token == self.diagnosticID else { return }
                self.busy = false; self.pathDiagnostics = url.path + "\n" + report.summary
                if report.passed { then?(url, report, token) }
                else if !self.privacyPaused { self.status = "路径检查未通过；现有连接与数据未改动。" }
            }
        }
    }
    func choose(create: Bool) {
        guard !busy, !privacyPaused else { return }
        diagnosePath { [weak self] url, report, attempt in
            guard let self, !self.privacyPaused, attempt == self.diagnosticID else { return }
            if create {
                if report.existingSpaces > 0 {
                    let alert = NSAlert(); alert.messageText = "这个目录已有同步空间"
                    alert.informativeText = "如果这是第二台设备，请取消并选择“加入已有空间”。继续创建会生成互不相通的新空间，不会加入现有设备。"
                    alert.addButton(withTitle: "取消，使用加入"); alert.addButton(withTitle: "仍创建独立空间")
                    guard alert.runModal() == .alertSecondButtonReturn, attempt == self.diagnosticID, !self.privacyPaused else { return }
                }
                self.pairingToken = UUID(); self.pairingProcess?.cancel()
                self.pairCode = ""; self.pairMessage = ""; self.pairingActive = false
                do { try self.activate(pair: .create(), folder: url, create: true) }
                catch { self.status = error.localizedDescription }
            } else {
                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 44))
                input.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
                input.alignment = .center; input.placeholderString = "000 000"
                let alert = NSAlert(); alert.messageText = "输入第一台设备的 6 位配对码"
                alert.informativeText = "在已连接的设备上点“配对另一台电脑”，在倒计时结束前输入数字。两台设备必须选择同一个 NAS 共享文件夹。"
                alert.accessoryView = input; alert.addButton(withTitle: "加入"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn, !self.privacyPaused, attempt == self.diagnosticID else { return }
                let code = input.stringValue.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard code.utf8.count == 6, code.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { self.status = "请输入另一台设备显示的 6 位数字。"; return }
                self.busy = true; self.pairMessage = "正在配对…"
                self.runPairing(mode: "join", folder: url, code: code)
            }
        }
    }
    private func activate(pair: SyncPair, folder url: URL, create: Bool?) throws {
        try pair.validate()
        guard !privacyPaused else { throw SyncFailure.suspended }
        operationGate.update(active: true)
        guard let ticket = operationGate.ticket() else { throw SyncFailure.suspended }
        generation += 1; activationID = UUID(); let token = activationID
        busy = true; ready = false; status = "正在连接 NAS…"
        worker.async { [weak self] in
            guard let self else { return }
            do {
                guard self.operationGate.permits(ticket) else { throw SyncFailure.suspended }
                if let create { try FolderSync.setup(folder: url, pair: pair, create: create, allowed: { self.operationGate.permits(ticket) }) }
                guard self.operationGate.permits(ticket) else { throw SyncFailure.suspended }
                try PairVault.save(pair)
                let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/io.jlmac.ClipDay.Cloud/sync/\(pair.space)")
                let engine = try FolderSync(folder: url, local: local, pair: pair, name: Host.current().localizedName ?? "Mac")
                let history = try engine.history()
                guard self.operationGate.permits(ticket) else { throw SyncFailure.suspended }
                self.engine = engine
                // Reuse the stable text device ID, but never its sequence or clock.
                self.imageEngine = try? ImageFolderSync(folder: url, local: local, pair: pair, name: Host.current().localizedName ?? "Mac", device: engine.state.device)
                DispatchQueue.main.async {
                    guard token == self.activationID, self.operationGate.permits(ticket), !self.privacyPaused else { return }
                    self.folder = url.path; self.folderInput = url.path; self.ready = true; self.busy = false; self.activeSpace = pair.space
                    if create != nil { self.enabled = true }
                    UserDefaults.standard.set(url.path, forKey: "syncFolder"); UserDefaults.standard.set(pair.space, forKey: "syncSpace")
                    UserDefaults.standard.set(self.enabled, forKey: "syncEnabled")
                    if self.enabled, self.model?.receive(history, automatic: nil, expectedChange: -1) == true {
                        self.worker.async { if self.operationGate.permits(ticket) { try? engine.acknowledge(history) } }
                    }
                    self.status = self.enabled ? "本机配置已加载，等待 NAS 检查" : "同步已暂停，本地记录继续"
                    if create == true { self.beginPairing(pair: pair, folder: url) }
                    self.poll()
                }
            } catch { DispatchQueue.main.async { if token == self.activationID, self.operationGate.permits(ticket) { self.busy = false; self.status = error.localizedDescription } } }
        }
    }
    func toggle() {
        enabled.toggle(); generation += 1
        operationGate.update(active: !privacyPaused)
        UserDefaults.standard.set(enabled, forKey: "syncEnabled")
        worker.async { self.engine?.suspend(); self.imageEngine?.suspend() }
        status = privacyPaused ? "隐私暂停：记录、发送、接收均已停止" : (enabled ? "正在恢复同步…" : "同步已暂停，本地记录继续")
        if enabled && !privacyPaused { poll() }
    }
    func localActivity() { generation += 1; holdUntil = Date().addingTimeInterval(10) }
    func send(_ text: String, created: Date = Date(), id: UUID = UUID()) {
        guard !privacyPaused, model?.paused != true else { return }
        guard ready, enabled, let space = activeSpace else {
            deliveryStatus = "已保存本机；未加入待发队列（同步暂停或尚未连接）。"; return
        }
        if text.utf8.count > SyncWire.maxText { deliveryStatus = "已保存本机；文字超过 1 MB，不上传。"; return }
        pendingSends = pendingSends.filter { $0.value.created.addingTimeInterval(ClipStore.lifetime) > Date() }
        guard pendingSends.count < 2000, pendingSends.values.reduce(0, { $0 + $1.text.utf8.count }) + text.utf8.count <= 100 * 1024 * 1024 else {
            deliveryStatus = "已保存本机；待重试队列已满，此条不会自动上传。"; return
        }
        let key = id.uuidString.lowercased()
        pendingSends[key] = pendingSends[key] ?? PendingSend(id: key, text: text, created: created, space: space)
        // Retain the shared ten-second hold: text/image clocks are separate.
        deliveryStatus = "已保存本机；正在保存待发队列，尚未上传。"
        retryPendingSends()
    }
    private func retryPendingSends() {
        guard ready, enabled, !privacyPaused, !busy, !sending, let ticket = operationGate.ticket() else { return }
        let now = Date()
        pendingSends = pendingSends.filter { $0.value.created.addingTimeInterval(ClipStore.lifetime) > now }
        guard let pending = pendingSends.values.filter({ $0.space == activeSpace && $0.retryAt <= now }).min(by: { $0.created < $1.created }) else { return }
        sending = true
        worker.async {
            let result: Result<SyncRecord, Error>
            do {
                guard self.operationGate.permits(ticket) else { throw SyncFailure.suspended }
                guard let engine = self.engine, engine.pair.space == pending.space else { throw SyncFailure.suspended }
                result = .success(try engine.enqueue(pending.text, now: SyncWire.ms(pending.created), id: pending.id))
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                self.sending = false
                switch result {
                case .success:
                    // The queue write completed. Retire only this retry, even if a
                    // pause arrived meanwhile; the encrypted outbox remains intact.
                    self.pendingSends.removeValue(forKey: pending.id)
                    if self.operationGate.permits(ticket) { self.deliveryStatus = "已保存本机并加入待发队列；尚未确认上传 NAS。" }
                case .failure(let error):
                    if self.operationGate.permits(ticket), var retry = self.pendingSends[pending.id] {
                        retry.attempts += 1
                        let delay = min(30.0, pow(2.0, Double(min(retry.attempts - 1, 5))))
                        retry.retryAt = Date().addingTimeInterval(delay)
                        self.pendingSends[pending.id] = retry
                        self.deliveryStatus = "已保存本机；队列写入失败，\(Int(delay)) 秒后重试（退出前未入队的内容需重新复制）：\(error.localizedDescription)"
                    }
                }
                self.retryPendingSends()
            }
        }
    }
    var imageQueueSpace: String? { !privacyPaused && ready && enabled ? activeSpace : nil }
    func sendImage(_ png: Data, created: Date = Date(), id: UUID = UUID()) {
        guard !privacyPaused, model?.paused != true else { return }
        guard ready, enabled, let space = activeSpace else {
            deliveryStatus = "图片已保存本机；未加入待发队列（同步暂停或尚未连接）。"; return
        }
        pendingImages = pendingImages.filter { $0.value.created.addingTimeInterval(ClipStore.lifetime) > Date() }
        guard png.count <= ImageWire.maxBytes, pendingImages.count < ImageWire.maxRecords,
              pendingImages.values.reduce(0, { $0 + $1.png.count }) + png.count <= ImageWire.maxStorage else {
            deliveryStatus = "图片已保存本机；图片待重试队列已满，已保留原始待发标记，稍后重试。"; return
        }
        let key = id.uuidString.lowercased()
        pendingImages[key] = pendingImages[key] ?? PendingImageSend(id: key, png: png, created: created, space: space)
        deliveryStatus = "图片已保存本机；正在保存加密待发队列，尚未上传。"
        retryPendingImages()
    }
    private func retryPendingImages() {
        guard ready, enabled, !privacyPaused, !busy, !sendingImage, let ticket = operationGate.ticket() else { return }
        let now = Date()
        pendingImages = pendingImages.filter { $0.value.created.addingTimeInterval(ClipStore.lifetime) > now }
        // Recover captures interrupted between durable local history and encrypted
        // outbox completion, without resending history captured while sync paused.
        for clip in model?.store.clips ?? [] where clip.kind == .image && clip.imageSyncSpace == activeSpace && clip.expires > now {
            let id = clip.id.uuidString.lowercased()
            if pendingImages[id] == nil, let space = clip.imageSyncSpace {
                guard pendingImages.count < ImageWire.maxRecords else { break }
                pendingImages[id] = PendingImageSend(id: id, png: clip.data, created: clip.created, space: space)
            }
        }
        guard let pending = pendingImages.values.filter({ $0.space == activeSpace && $0.retryAt <= now }).min(by: { $0.created < $1.created }) else { return }
        sendingImage = true
        worker.async {
            let result: Result<ImageManifest, Error>
            do {
                guard self.operationGate.permits(ticket), let engine = self.imageEngine, engine.pair.space == pending.space else { throw SyncFailure.suspended }
                result = .success(try engine.enqueue(pending.png, now: SyncWire.ms(pending.created), id: pending.id, allowed: { self.operationGate.permits(ticket) }))
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                self.sendingImage = false
                switch result {
                case .success:
                    // Clearing the intent is durable too. If that write fails the
                    // next attempt reuses the existing encrypted ID and sequence.
                    do {
                        try self.model?.store.markImageQueued(pending.id, space: pending.space)
                        self.worker.async {
                            if let engine = self.imageEngine, engine.pair.space == pending.space { try? engine.acknowledgeQueuedIntent(pending.id) }
                        }
                        self.pendingImages.removeValue(forKey: pending.id)
                        self.model?.clips = self.model?.store.clips ?? []
                        if self.operationGate.permits(ticket) { self.deliveryStatus = "图片已保存本机并加入加密待发队列；尚未确认上传 NAS。" }
                    } catch {
                        if var retry = self.pendingImages[pending.id] { retry.retryAt = Date().addingTimeInterval(5); self.pendingImages[pending.id] = retry }
                        self.deliveryStatus = "图片已进入加密待发队列；本机确认状态稍后重试。"
                    }
                case .failure(let error):
                    if self.operationGate.permits(ticket), var retry = self.pendingImages[pending.id] {
                        retry.attempts += 1
                        let delay = min(30.0, pow(2.0, Double(min(retry.attempts - 1, 5))))
                        retry.retryAt = Date().addingTimeInterval(delay); self.pendingImages[pending.id] = retry
                        self.deliveryStatus = "图片已保存本机；加密队列写入失败，\(Int(delay)) 秒后重试（已保留原始图片与待发标记）：\(error.localizedDescription)"
                    }
                }
                self.retryPendingImages()
            }
        }
    }
    func poll() {
        retryPendingSends(); retryPendingImages()
        guard ready, enabled, !privacyPaused, !busy, !polling, let model, !model.paused, let ticket = operationGate.ticket() else { return }
        polling = true
        let token = generation, session = activationID, expected = model.pasteboard.changeCount
        worker.async {
            do {
                guard let engine = self.engine else { throw SyncFailure.offline }
                let batch = try engine.poll(allowed: { self.operationGate.permits(ticket) })
                let imageResult = Result { () throws -> ImageBatch in
                    if self.imageEngine == nil {
                        self.imageEngine = try ImageFolderSync(folder: engine.root.deletingLastPathComponent().deletingLastPathComponent(), local: engine.local, pair: engine.pair, name: engine.name, device: engine.state.device)
                    }
                    guard let imageEngine = self.imageEngine else { throw SyncFailure.offline }
                    return try imageEngine.poll(allowed: { self.operationGate.permits(ticket) })
                }
                DispatchQueue.main.async {
                    self.polling = false
                    guard self.enabled, self.ready, !self.privacyPaused, self.operationGate.permits(ticket), session == self.activationID else { return }
                    // One shared clipboard generation/hold gates BOTH media. If one
                    // scan contains competing types, only a single newest source can
                    // win; equally timed or multi-device candidates stay in history.
                    let images = try? imageResult.get()
                    let canApply = token == self.generation && Date() >= self.holdUntil
                    var textAuto = canApply ? batch.automatic : nil
                    var imageAuto = canApply ? images?.automatic : nil
                    if let text = textAuto, let image = imageAuto {
                        if text.device != image.manifest.device || text.created == image.manifest.created {
                            textAuto = nil; imageAuto = nil
                        } else if text.created > image.manifest.created { imageAuto = nil }
                        else { textAuto = nil }
                    }
                    if self.model?.receive(batch.records, automatic: textAuto, expectedChange: expected) == true {
                        self.worker.async { if self.operationGate.permits(ticket) { try? engine.acknowledge(batch.records) } }
                    }
                    if let images, self.model?.receiveImages(images.records, automatic: imageAuto, expectedChange: expected) == true {
                        self.worker.async {
                            if self.operationGate.permits(ticket) { try? self.imageEngine?.acknowledge(images.records, allowed: { self.operationGate.permits(ticket) }) }
                        }
                    }
                    let rejected = batch.rejected + (images?.rejected ?? 0)
                    self.status = rejected > 0 ? "NAS 可达；\(rejected) 个不完整或无效文件等待重试" : "NAS 可达 · 每 2 秒检查 · 文字与图片端到端加密"
                    if case .failure(let error) = imageResult { self.status += "；图片重试中：" + error.localizedDescription }
                    let uploaded = batch.uploaded + (images?.uploaded ?? 0), pending = batch.pending + (images?.pending ?? 0)
                    if uploaded > 0 { self.deliveryStatus = "已上传 NAS：\(uploaded) 条；接收端是否收到未知（协议无回执）。" }
                    else if pending > 0 { self.deliveryStatus = "本机待发：\(pending) 条；尚未全部上传 NAS。" }
                }
            } catch { DispatchQueue.main.async {
                self.polling = false
                if self.operationGate.permits(ticket), session == self.activationID { self.status = error.localizedDescription }
            } }
        }
    }
    func pairingCode() {
        guard !privacyPaused, ready, let space = UserDefaults.standard.string(forKey: "syncSpace"), !folder.isEmpty else { return }
        do { beginPairing(pair: try PairVault.load(space), folder: URL(fileURLWithPath: folder)) }
        catch { pairMessage = error.localizedDescription }
    }
    private func beginPairing(pair: SyncPair, folder: URL) {
        pairMessage = "正在生成配对码…"; pairCode = ""; pairingActive = true
        runPairing(mode: "host", folder: folder, pair: pair)
    }
    private func runPairing(mode: String, folder: URL, pair: SyncPair? = nil, code: String? = nil) {
        pairingToken = UUID(); let token = pairingToken
        pairCode = ""; pairExpires = .distantPast; pairingActive = true
        let launch = { [weak self] in
            guard let self, token == self.pairingToken, !self.privacyPaused else { return }
            do {
                self.pairingProcess = try PairingProcess(mode: mode, folder: folder, pair: pair, code: code) { [weak self] result in
                    guard let self, token == self.pairingToken, !self.privacyPaused else { return }
                    switch result.type {
                    case "offer":
                        self.pairCode = result.code ?? ""
                        self.pairExpires = Date(timeIntervalSince1970: Double(result.expires ?? 0) / 1000)
                        self.pairMessage = result.message ?? "在另一台电脑输入这 6 位数字"
                        self.pairingActive = true
                    case "joined":
                        self.busy = false; self.pairingActive = false
                        guard let paired = result.pair else { self.pairMessage = "配对失败，请重试。"; return }
                        do { try self.activate(pair: paired, folder: folder, create: false); self.pairMessage = "配对成功" }
                        catch { self.pairMessage = error.localizedDescription }
                    case "success", "expired", "cancelled", "error":
                        self.pairingActive = false; self.pairCode = ""; self.busy = false
                        self.pairMessage = result.message ?? "配对已结束"
                    default: break
                    }
                }
            } catch { self.pairMessage = error.localizedDescription; self.pairingActive = false; self.busy = false }
        }
        if let previous = pairingProcess { previous.cancel(then: launch) } else { launch() }
    }

}
struct NASSettings: View {
    @ObservedObject var cloud: NASController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("NAS 文字与图片同步 · 预览版", systemImage: "externaldrive.connected.to.line.below").font(.headline)
            Text(cloud.status).font(.callout).foregroundStyle(cloud.privacyPaused ? Color.orange : Color.teal)
            Text(cloud.deliveryStatus).font(.caption).foregroundStyle(.secondary)
            Text("1. 在访达连接 NAS，再选择已挂载的共享文件夹。").font(.callout)
            Text("NAS 文件夹路径").font(.callout)
            HStack {
                TextField("例如 /Volumes/共享/轻贴", text: $cloud.folderInput)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("NAS 文件夹路径")
                Button("浏览…") { cloud.browseFolder() }
            }.disabled(cloud.busy)
            Button("2. 检查路径与读写权限") { cloud.checkFolder() }.disabled(cloud.busy)
            Text(cloud.pathDiagnostics).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("检查会创建、读回、重命名并删除一个随机测试文件，不修改已有数据；路径可达并不能证明两台设备选择的是同一目录。")
                .font(.caption).foregroundStyle(.secondary)
            if cloud.ready { Text("当前连接：" + cloud.folder).font(.caption).textSelection(.enabled) }
            Text("3. 第一台设备创建；其他设备加入，勿重复创建。").font(.callout)
            HStack {
                Button("第一台：创建空间…") { cloud.choose(create: true) }
                Button("其他设备：加入空间…") { cloud.choose(create: false) }
            }.disabled(cloud.busy || cloud.privacyPaused)
            if cloud.ready {
                HStack {
                    Button(cloud.enabled ? "暂停同步" : "恢复同步") { cloud.toggle() }
                    Button(cloud.pairMessage.isEmpty ? "配对另一台电脑…" : "重新生成配对码") { cloud.pairingCode() }
                }.disabled(cloud.busy || cloud.privacyPaused)
            }
            Text("隐私暂停同时停止记录、发送和接收，不清空历史或队列，24 小时到期规则不变。已开始的单次 NAS 写入可能完成；已上传内容不会撤回。恢复后待发队列继续。")
                .font(.caption).foregroundStyle(.secondary)
            if !cloud.pairMessage.isEmpty {
                PairingCodeCard(cloud: cloud)
            }
            Text("复制文字或图片后自动加密同步。文字最多 1 MB；静态 PNG 图片最多 20 MB、8192×8192 且不超过 1600 万像素。新内容可直接粘贴；重连、同时复制或本机刚复制后仅进入历史。24 小时过期；文件暂不支持。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct PairingCodeCard: View {
    @ObservedObject var cloud: NASController
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let seconds = max(0, Int(ceil(cloud.pairExpires.timeIntervalSince(timeline.date))))
            VStack(alignment: .leading, spacing: 8) {
                if !cloud.pairCode.isEmpty && seconds > 0 {
                    HStack {
                        Text(String(cloud.pairCode.prefix(3)) + " " + String(cloud.pairCode.suffix(3)))
                            .font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.teal)
                            .accessibilityLabel("配对码 " + cloud.pairCode)
                        Spacer()
                        ZStack {
                            Circle().stroke(Color.teal.opacity(0.15), lineWidth: 4)
                            Circle().trim(from: 0, to: min(1, Double(seconds) / 120)).stroke(Color.teal, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                            Text(String(format: "%d:%02d", seconds / 60, seconds % 60)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        }.frame(width: 52, height: 52).accessibilityLabel("剩余 \(seconds) 秒")
                    }
                }
                Text(cloud.pairCode.isEmpty || seconds > 0 ? cloud.pairMessage : "配对码已过期，点击重新生成")
                    .font(.caption).foregroundStyle(.secondary)
                if !cloud.pairCode.isEmpty && seconds > 0 { Text("2 分钟内有效 · 成功后失效 · 无需复制").font(.caption2).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(14).background(Color.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
#endif
