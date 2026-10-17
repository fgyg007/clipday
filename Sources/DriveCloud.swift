#if CLOUD
import AppKit
import SwiftUI
import Security

private enum PairVault {
    static let service = "io.jlmac.ClipDay.Drive.sync"
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

final class DriveController: ObservableObject {
    static let defaults = UserDefaults(suiteName: "io.jlmac.ClipDay.Cloud.drive-settings")!
    static let providers = ["百度网盘", "OneDrive", "iCloud", "其他同步文件夹"]
    @Published var provider = DriveController.defaults.string(forKey: "driveProvider") ?? "其他同步文件夹" {
        didSet { DriveController.defaults.set(provider, forKey: "driveProvider"); folderPrerequisitesConfirmed = false }
    }
    @Published var folderPrerequisitesConfirmed = false
    @Published var status = "尚未连接本地同步文件夹"
    @Published var folder = DriveController.defaults.string(forKey: "syncFolder") ?? ""
    @Published var folderInput = DriveController.defaults.string(forKey: "syncFolder") ?? ""
    @Published var enabled = DriveController.defaults.bool(forKey: "syncEnabled")
    @Published var ready = false
    @Published var busy = false
    @Published var pairCode = ""
    @Published var pairExpires = Date.distantPast
    @Published var pairMessage = ""
    @Published var pairingActive = false
    @Published private(set) var privacyPaused = false
    @Published var pathDiagnostics = "尚未检查路径"
    @Published var deliveryStatus = "本机历史、写入同步目录、云端上传是不同状态；这里只能确认前两项，不能确认另一台电脑已收到。"
    private let operationGate = SyncOperationGate()
    private let worker = DispatchQueue(label: "io.jlmac.ClipDay.Drive.sync", qos: .utility)
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
    @Published private(set) var waitingForJoin = false
    private var pendingJoin: (pair: SyncPair, folder: URL)? {
        didSet { waitingForJoin = pendingJoin != nil }
    }
    private var joinAttempts = 0
    private var joinRetryAt = Date.distantPast
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
        if autoConnectionAllowed, !privacyPaused, !ready, !busy, let joining = pendingJoin {
            guard Date() >= joinRetryAt else { return }
            do { try activate(pair: joining.pair, folder: joining.folder, create: false) }
            catch { status = error.localizedDescription }
            return
        }
        guard autoConnectionAllowed, !privacyPaused, !ready, !busy, let space = DriveController.defaults.string(forKey: "syncSpace"), !folder.isEmpty else { return }
        do { try activate(pair: PairVault.load(space), folder: URL(fileURLWithPath: folder), create: nil) }
        catch { status = error.localizedDescription }
    }
    func setPrivacyPaused(_ paused: Bool, reconnect: Bool = true) {
        privacyPaused = paused; generation += 1; diagnosticID = UUID()
        operationGate.update(active: !paused)
        worker.async { self.engine?.suspend(); self.imageEngine?.suspend() }
        if paused {
            activationID = UUID()
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
    deinit { timer?.invalidate() }
    func browseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = false
        panel.prompt = "选择网盘同步文件夹"; panel.message = "请先登录网盘客户端，在其中新建专用文件夹并选择“始终保留在此设备上”。两台电脑选择同一云端文件夹对应的本地目录。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderInput = url.path
    }
    private func inputFolder() -> URL? {
        let path = (folderInput.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard folderPrerequisitesConfirmed else { status = "请先确认该目录支持双向同步且完整保留本地文件。"; return nil }
        guard !path.isEmpty else { status = "请先填写网盘本地同步文件夹路径，或点击浏览选择。"; return nil }
        guard path.hasPrefix("/") else {
            status = "请选择已由网盘客户端同步到本机的文件夹，不能填写网页链接。"; return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
    func checkFolder() { diagnosePath() }
    private func diagnosePath(then: ((URL, NASPathDiagnostics, UUID) -> Void)? = nil) {
        guard !busy, let url = inputFolder() else { return }
        diagnosticID = UUID(); let token = diagnosticID
        busy = true; pathDiagnostics = "正在检查路径、读取与写入权限…"
        worker.async {
            let report = NASPathDiagnostics.inspect(url, cloudDrive: true)
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
                self.pendingJoin = nil
                if report.existingSpaces > 0 {
                    let alert = NSAlert(); alert.messageText = "这个目录已有同步空间"
                    alert.informativeText = "如果这是第二台设备，请取消并选择“加入已有空间”。继续创建会生成互不相通的新空间，不会加入现有设备。"
                    alert.addButton(withTitle: "取消，使用加入"); alert.addButton(withTitle: "仍创建独立空间")
                    guard alert.runModal() == .alertSecondButtonReturn, attempt == self.diagnosticID, !self.privacyPaused else { return }
                }
                self.pairCode = ""; self.pairMessage = ""; self.pairingActive = false
                do { try self.activate(pair: .create(), folder: url, create: true) }
                catch { self.status = error.localizedDescription }
            } else {
                let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
                input.placeholderString = "clipday-drive1:…"
                let alert = NSAlert(); alert.messageText = "输入第一台电脑显示的秘密配对信息"
                alert.informativeText = "请通过可信的私密方式传递，不要保存到网盘文件夹。配对信息没有短时限；请等待网盘完成本地文件下载后加入。切勿在已启用剪贴板记录的设备上复制此秘密。"
                alert.accessoryView = input; alert.addButton(withTitle: "加入"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn, !self.privacyPaused, attempt == self.diagnosticID else { return }
                do {
                    let pair = try SyncPair.parseDrive(input.stringValue)
                    input.stringValue = ""
                    self.joinAttempts = 0; self.joinRetryAt = .distantPast
                    self.pendingJoin = (pair, url)
                    try self.activate(pair: pair, folder: url, create: false)
                } catch { input.stringValue = ""; self.status = "无法加入：" + error.localizedDescription }

            }
        }
    }
    private func activate(pair: SyncPair, folder url: URL, create: Bool?) throws {
        try pair.validate()
        guard !privacyPaused else { throw SyncFailure.suspended }
        operationGate.update(active: true)
        guard let ticket = operationGate.ticket() else { throw SyncFailure.suspended }
        generation += 1; activationID = UUID(); let token = activationID
        busy = true; ready = false; status = "正在检查本地同步目录…"
        worker.async { [weak self] in
            guard let self else { return }
            do {
                guard self.operationGate.permits(ticket) else { throw SyncFailure.suspended }
                if let create { try FolderSync.setup(folder: url, pair: pair, create: create, cloudDrive: true, allowed: { self.operationGate.permits(ticket) }) }
                guard self.operationGate.permits(ticket) else { throw SyncFailure.suspended }
                try PairVault.save(pair)
                let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/io.jlmac.ClipDay.Drive/sync/\(pair.space)")
                let engine = try FolderSync(folder: url, local: local, pair: pair, name: Host.current().localizedName ?? "Mac", cloudDrive: true)
                let history = try engine.history()
                guard self.operationGate.permits(ticket) else { throw SyncFailure.suspended }
                self.engine = engine
                // Reuse the stable text device ID, but never its sequence or clock.
                self.imageEngine = try? ImageFolderSync(folder: url, local: local, pair: pair, name: Host.current().localizedName ?? "Mac", device: engine.state.device, cloudDrive: true)
                DispatchQueue.main.async {
                    guard token == self.activationID, self.operationGate.permits(ticket), !self.privacyPaused else { return }
                    self.pendingJoin = nil
                    self.folder = url.path; self.folderInput = url.path; self.ready = true; self.busy = false; self.activeSpace = pair.space
                    if create != nil { self.enabled = true }
                    DriveController.defaults.set(url.path, forKey: "syncFolder"); DriveController.defaults.set(pair.space, forKey: "syncSpace")
                    DriveController.defaults.set(self.enabled, forKey: "syncEnabled")
                    if self.enabled, self.model?.receive(history, automatic: nil, expectedChange: -1) == true {
                        self.worker.async { if self.operationGate.permits(ticket) { try? engine.acknowledge(history) } }
                    }
                    self.status = self.enabled ? "本机配置已加载，等待本地目录检查" : "同步已暂停，本地记录继续"
                    if create == true { self.beginPairing(pair: pair, folder: url) }
                    self.poll()
                }
            } catch { DispatchQueue.main.async { if token == self.activationID, self.operationGate.permits(ticket) { self.busy = false
                if create == false, self.pendingJoin != nil {
                    // Markers and encrypted proofs can arrive separately or partly.
                    // A bad secret is indistinguishable from an incomplete proof here.
                    self.joinAttempts = min(self.joinAttempts + 1, 5)
                    let delay = min(60.0, 5.0 * pow(2.0, Double(self.joinAttempts - 1)))
                    self.joinRetryAt = Date().addingTimeInterval(delay)
                    self.status = "空间文件未完整同步、配对信息不匹配，或本地保存失败；\(Int(delay)) 秒后重试。请检查目录和配对信息，或取消等待；不会新建远端空间。"
                } else { self.pendingJoin = nil; self.status = error.localizedDescription }
            } } }
        }
    }
    func cancelJoin() {
        guard pendingJoin != nil else { return }
        pendingJoin = nil; joinAttempts = 0; joinRetryAt = .distantPast
        activationID = UUID(); generation += 1; busy = false
        operationGate.update(active: false)
        status = "已取消等待加入；未创建远端空间。"
    }
    func toggle() {
        enabled.toggle(); generation += 1
        operationGate.update(active: !privacyPaused)
        DriveController.defaults.set(enabled, forKey: "syncEnabled")
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
                    if self.operationGate.permits(ticket) { self.deliveryStatus = "已保存本机并加入待发队列；尚未确认写入同步目录。" }
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
                        if self.operationGate.permits(ticket) { self.deliveryStatus = "图片已保存本机并加入加密待发队列；尚未确认写入同步目录。" }
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
        if !ready, !busy, !privacyPaused, let joining = pendingJoin {
            guard Date() >= joinRetryAt else { return }
            do { try activate(pair: joining.pair, folder: joining.folder, create: false) }
            catch { status = error.localizedDescription }
            return
        }
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
                        self.imageEngine = try ImageFolderSync(folder: URL(fileURLWithPath: self.folder), local: engine.local, pair: engine.pair, name: engine.name, device: engine.state.device, cloudDrive: true)
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
                    self.status = rejected > 0 ? "本地同步目录可达；\(rejected) 个不完整或无效文件等待重试" : "本地同步目录可达 · 每 2 秒检查 · 文字与图片端到端加密"
                    if case .failure(let error) = imageResult { self.status += "；图片重试中：" + error.localizedDescription }
                    let uploaded = batch.uploaded + (images?.uploaded ?? 0), pending = batch.pending + (images?.pending ?? 0)
                    if uploaded > 0 { self.deliveryStatus = "已写入本地同步目录：\(uploaded) 条；云端上传及接收端是否收到未知（协议无回执）。" }
                    else if pending > 0 { self.deliveryStatus = "本机待发：\(pending) 条；尚未全部写入同步目录。" }
                }
            } catch { DispatchQueue.main.async {
                self.polling = false
                if self.operationGate.permits(ticket), session == self.activationID { self.status = error.localizedDescription }
            } }
        }
    }
    func pairingCode() {
        guard !privacyPaused, ready, let space = DriveController.defaults.string(forKey: "syncSpace"), !folder.isEmpty else { return }
        do { beginPairing(pair: try PairVault.load(space), folder: URL(fileURLWithPath: folder)) }
        catch { pairMessage = error.localizedDescription }
    }
    private func beginPairing(pair: SyncPair, folder: URL) {
        // Reveal only. Never put the secret on the general pasteboard or in the sync directory.
        pairCode = pair.driveCode
        pairMessage = "秘密配对信息等同于同步密钥。仅通过可信的私密方式传给另一台电脑；不要存进云盘，也不要在剪贴板记录开启时复制。没有两分钟时限，云盘延迟后可再次加入。"
        pairingActive = false
    }
    func hidePairing() { pairCode = ""; pairMessage = "" }

}
struct DriveSettings: View {
    @ObservedObject var cloud: DriveController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("轻贴云盘版 · 电脑间同步开发预览", systemImage: "cloud").font(.headline)
            Text(cloud.status).font(.callout).foregroundStyle(cloud.privacyPaused ? Color.orange : Color.teal)
            Text(cloud.deliveryStatus).font(.caption).foregroundStyle(.secondary)
            Picker("同步文件夹来源（仅说明用途）", selection: $cloud.provider) {
                ForEach(DriveController.providers, id: \.self) { Text($0 + " · 未经真机验证").tag($0) }
            }
            Text("1. 自行登录网盘客户端，两台电脑选择真正双向同步的同一云端目录对应的本地文件夹。不能使用仅备份、网页下载目录或虚拟挂载；本软件不登录网盘，也不会自动配置客户端。").font(.callout)
            Text("2. 新建专用双向同步文件夹，两端都设置“始终保留在此设备上”或等效的完整本地保留选项，等待同步完成。这里只读写本地目录，无法确认网盘已上传或另一台电脑已收到。").font(.callout)
            Toggle("我已确认此目录双向同步，且两端完整保留本地文件（非占位符）", isOn: $cloud.folderPrerequisitesConfirmed)
            HStack {
                TextField("选择网盘对应的本地文件夹", text: $cloud.folderInput)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("网盘本地同步文件夹")
                Button("浏览…") { cloud.browseFolder() }
            }.disabled(cloud.busy)
            .onChange(of: cloud.folderInput) { _, _ in cloud.folderPrerequisitesConfirmed = false }
            Button("3. 检查本地路径与读写权限") { cloud.checkFolder() }.disabled(cloud.busy)
            Text(cloud.pathDiagnostics).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("检查会创建、读回、重命名并删除随机测试文件，网盘客户端可能同步测试文件。检查成功不代表选中了网盘，也不证明云端同步正常。").font(.caption).foregroundStyle(.secondary)
            if cloud.ready { Text("当前本地目录：" + cloud.folder).font(.caption).textSelection(.enabled) }
            Text("4. 第一台创建空间；第二台选择相同云端目录对应的本地文件夹，输入第一台的秘密配对信息加入。不要重复创建。").font(.callout)
            HStack {
                Button("第一台：创建空间…") { cloud.choose(create: true) }
                Button("另一台：输入配对信息…") { cloud.choose(create: false) }
            }.disabled(cloud.busy || cloud.privacyPaused)
            if cloud.waitingForJoin { Button("取消等待加入") { cloud.cancelJoin() } }
            if cloud.ready {
                HStack {
                    Button(cloud.enabled ? "暂停同步" : "恢复同步") { cloud.toggle() }
                    Button("显示秘密配对信息…") { cloud.pairingCode() }
                }.disabled(cloud.busy || cloud.privacyPaused)
            }
            if !cloud.pairMessage.isEmpty {
                Text(cloud.pairMessage).font(.caption).foregroundStyle(.orange)
                // Nonselectable to avoid accidental clipboard capture or cloud sharing.
                if !cloud.pairCode.isEmpty { Text(cloud.pairCode).font(.system(.caption, design: .monospaced)).textSelection(.disabled) }
                Button("隐藏配对信息") { cloud.hidePairing() }
            }
            Text("隐私暂停停止本软件的记录、发送和接收，不会暂停网盘客户端；客户端仍可上传先前已写入的文件。暂停同步仅停止本软件传输。已同步内容不会撤回，云盘回收站或版本历史可能保留旧数据。").font(.caption).foregroundStyle(.secondary)
            Text("复制文字或图片后自动加密写入同步目录；云端交付未知。文字最多 1 MB；静态 PNG 最多 20 MB、8192×8192 且不超过 1600 万像素。重连、同时复制或本机刚复制后仅进入历史。24 小时过期；不支持文件或手机。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
