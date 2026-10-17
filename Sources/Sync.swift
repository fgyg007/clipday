import Foundation
import CryptoKit

// Wire format shared with Windows/ClipDay.Sync. Never place a key in the NAS folder.
struct SyncPair: Codable {
    var v = 1
    let space: String
    let key: String
    static func create() -> SyncPair {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
        return SyncPair(space: UUID().uuidString.lowercased(), key: key)
    }
    func validate() throws {
        guard v == 1, SyncWire.isID(space), Data(base64Encoded: key)?.count == 32 else { throw SyncFailure.invalid }
    }
    var code: String { "clipday1:" + (try! JSONEncoder().encode(self)).base64EncodedString() }
    var driveCode: String { "clipday-drive1:" + (try! JSONEncoder().encode(self)).base64EncodedString() }
    static func parseDrive(_ code: String) throws -> SyncPair {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines), prefix = "clipday-drive1:"
        guard text.hasPrefix(prefix), text.count < 1024, let data = Data(base64Encoded: String(text.dropFirst(prefix.count))) else { throw SyncFailure.invalid }
        let pair = try JSONDecoder().decode(SyncPair.self, from: data); try pair.validate(); return pair
    }
    static func parse(_ code: String) throws -> SyncPair {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("clipday1:"), text.count < 1024, let data = Data(base64Encoded: String(text.dropFirst(9))) else { throw SyncFailure.invalid }
        let pair = try JSONDecoder().decode(SyncPair.self, from: data); try pair.validate(); return pair
    }
}
struct SyncRecord: Codable {
    var v = 1
    let id: String
    let space: String
    let device: String
    let name: String
    let seq: Int64
    let created: Int64
    let expires: Int64
    let observed: [String: Int64]
    let text: String
}
enum SyncFailure: LocalizedError {
    case invalid, offline, full, suspended
    var errorDescription: String? {
        switch self {
        case .suspended: return "已暂停同步；保留队列，恢复后重试。"
        case .invalid: return "配对信息或同步文件无效。"
        case .offline: return "NAS 目录不可用，已保留本地记录，稍后自动重试。"
        case .full: return "同步队列达到容量限制，这条文字仅保留在本机。"
        }
    }
}
enum SyncWire {
    static let lifetime: Int64 = 86_400_000
    static let maxText = 1024 * 1024
    static let maxFile = 2 * 1024 * 1024
    static func ms(_ date: Date = Date()) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    static func isID(_ value: String) -> Bool { UUID(uuidString: value) != nil && value == value.lowercased() }
    static func seal(_ record: SyncRecord, pair: SyncPair) throws -> Data {
        try pair.validate()
        let box = try AES.GCM.seal(JSONEncoder().encode(record), using: SymmetricKey(data: Data(base64Encoded: pair.key)!), authenticating: Data("clipday-sync-v1:\(pair.space)".utf8))
        return box.combined!
    }
    static func open(_ data: Data, pair: SyncPair) throws -> SyncRecord {
        try pair.validate()
        guard data.count >= 28, data.count <= maxFile else { throw SyncFailure.invalid }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: Data(base64Encoded: pair.key)!), authenticating: Data("clipday-sync-v1:\(pair.space)".utf8))
        let r = try JSONDecoder().decode(SyncRecord.self, from: clear)
        guard r.v == 1, r.space == pair.space, isID(r.id), isID(r.device), r.seq > 0,
              r.created > 0, r.created <= Int64.max - lifetime, r.expires == r.created + lifetime,
              !r.text.isEmpty, r.text.utf8.count <= maxText, r.name.utf8.count <= 256,
              r.observed.count <= 100, r.observed.allSatisfy({ isID($0.key) && $0.value >= 0 }) else { throw SyncFailure.invalid }
        return r
    }
    static func read(_ file: URL) throws -> Data {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? maxFile + 1) <= maxFile else { throw SyncFailure.invalid }
        return try Data(contentsOf: file)
    }
}
struct SyncState: Codable {
    var device = UUID().uuidString.lowercased()
    var seq: Int64 = 0
    var seen: [String: Int64] = [:]
    var clock: [String: Int64] = [:]
}
// The UI can invalidate queued work without waiting for a blocked NAS call.
// A filesystem call already in progress cannot be recalled; check again before
// every subsequent side effect and before applying a returned batch.
final class SyncOperationGate {
    private let lock = NSLock()
    private var epoch = 0
    private var active = false
    func update(active: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.active = active; epoch += 1
    }
    func ticket() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return active ? epoch : nil
    }
    func permits(_ ticket: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && ticket == epoch
    }
}

struct NASPathDiagnostics {
    var reachable = false
    var readable = false
    var writable = false
    var existingSpaces = 0
    var detail = ""
    var passed: Bool { reachable && readable && writable }
    var summary: String {
        "路径：\(reachable ? "可达" : "不可达") · 读取：\(readable ? "通过" : "未通过") · 写入：\(writable ? "通过" : "未通过")" + (detail.isEmpty ? "" : "\n" + detail)
    }
    static func inspect(_ folder: URL, cloudDrive: Bool = false) -> NASPathDiagnostics {
        let fm = FileManager.default
        var result = NASPathDiagnostics(), isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            result.detail = cloudDrive ? "请先在云盘客户端配置双向同步，选择已存在且完整保留在本机的文件夹；不会自动安装、登录或新建缺失路径。" : "请先在访达连接 NAS，并选择已挂载且存在的共享文件夹；不会自动新建缺失路径。"; return result
        }
        result.reachable = true
        do {
            _ = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            result.readable = true
            let spaces = cloudDrive ? folder.appendingPathComponent("ClipDayDrive").appendingPathComponent("v1") : folder.appendingPathComponent("ClipDaySync")
            if fm.fileExists(atPath: spaces.path) {
                result.existingSpaces = try fm.contentsOfDirectory(at: spaces, includingPropertiesForKeys: nil).filter {
                    SyncWire.isID($0.lastPathComponent) && fm.fileExists(atPath: $0.appendingPathComponent("space.json").path)
                }.count
            }
        } catch { result.detail = "无法读取目录，请检查共享读取权限：\(error.localizedDescription)"; return result }
        let probe = folder.appendingPathComponent(".clipday-check-" + UUID().uuidString)
        let renamedProbe = folder.appendingPathComponent(".clipday-check-" + UUID().uuidString)
        // Only our randomly named, newly created probes are ever removed.
        var created = false, renamed = false
        defer {
            if created { try? fm.removeItem(at: probe) }
            if renamed { try? fm.removeItem(at: renamedProbe) }
        }
        do {
            let data = Data("ClipDay connection check".utf8)
            try data.write(to: probe, options: .withoutOverwriting); created = true
            guard try Data(contentsOf: probe) == data else { throw SyncFailure.invalid }
            try fm.moveItem(at: probe, to: renamedProbe); created = false; renamed = true
            guard try Data(contentsOf: renamedProbe) == data else { throw SyncFailure.invalid }
            try fm.removeItem(at: renamedProbe); renamed = false
            result.writable = true
            result.detail = result.existingSpaces > 0 ? "发现已有空间。第二台设备请选择加入，并使用第一台设备的配对码。" : "未发现已有空间。第一台设备创建；第二台设备需先核对是否选中同一共享目录。"
        } catch { result.detail = "写入／读回／重命名／删除测试未通过，请检查共享写入权限和剩余空间：\(error.localizedDescription)" }
        return result
    }
}

struct SyncBatch {
    var records: [SyncRecord] = []
    var automatic: SyncRecord?
    var pending = 0
    var rejected = 0
    var uploaded = 0
}

// All calls run on one worker queue. NAS I/O must never run on the UI thread.
final class FolderSync {
    let pair: SyncPair
    let root: URL
    let cloudDrive: Bool
    var automaticWindow: Int64 { cloudDrive ? 300_000 : 10_000 }
    let local: URL
    let name: String
    private(set) var state = SyncState()
    private var lastPoll: Int64?
    private(set) var unreadableInboxCount = 0
    private let fm = FileManager.default
    var recordsURL: URL { root.appendingPathComponent("records") }
    var outbox: URL { local.appendingPathComponent("outbox") }
    var inbox: URL { local.appendingPathComponent("inbox") }
    var stateURL: URL { local.appendingPathComponent("state.json") }
    init(folder: URL, local: URL, pair: SyncPair, name: String, cloudDrive: Bool = false) throws {
        try pair.validate(); self.pair = pair; self.local = local; self.name = String(name.prefix(60))
        self.cloudDrive = cloudDrive
        root = Self.spaceRoot(folder: folder, pair: pair, cloudDrive: cloudDrive)
        if fm.fileExists(atPath: stateURL.path) { state = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: stateURL)) }
        else { state = SyncState() }
        guard SyncWire.isID(state.device), state.seq >= 0 else { throw SyncFailure.invalid }
        try fm.createDirectory(at: outbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try save()
    }
    func history(now: Int64 = SyncWire.ms()) throws -> [SyncRecord] {
        var records: [SyncRecord] = []
        unreadableInboxCount = 0
        for file in try fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) where file.pathExtension == "clip" {
            do {
                let r = try SyncWire.open(SyncWire.read(file), pair: pair)
                if r.expires <= now { try fm.removeItem(at: file) } else { records.append(r) }
            } catch { unreadableInboxCount += 1 } // Isolate one damaged inbox file, retain it for recovery.
        }
        return records.sorted { $0.created < $1.created }
    }
    static func spaceRoot(folder: URL, pair: SyncPair, cloudDrive: Bool = false) -> URL {
        let base = cloudDrive ? folder.appendingPathComponent("ClipDayDrive").appendingPathComponent("v1") : folder.appendingPathComponent("ClipDaySync")
        return base.appendingPathComponent(pair.space)
    }
    static func setup(folder: URL, pair: SyncPair, create: Bool, cloudDrive: Bool = false, allowed: () -> Bool = { true }) throws {
        func checkActive() throws { guard allowed() else { throw SyncFailure.suspended } }
        try checkActive()
        try pair.validate()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { throw SyncFailure.offline }
        let root = spaceRoot(folder: folder, pair: pair, cloudDrive: cloudDrive)
        let marker = root.appendingPathComponent("space.json")
        if create {
            guard !FileManager.default.fileExists(atPath: root.path) else { throw SyncFailure.invalid }
            try checkActive()
            try FileManager.default.createDirectory(at: root.appendingPathComponent("records"), withIntermediateDirectories: true)
            try checkActive()
            try JSONSerialization.data(withJSONObject: ["v": 1, "space": pair.space]).write(to: marker, options: .atomic)
            let now = SyncWire.ms()
            let proof = SyncRecord(id: pair.space, space: pair.space, device: pair.space, name: "", seq: 1, created: now, expires: now + SyncWire.lifetime, observed: [:], text: "clipday-space-v1")
            try checkActive()
            try SyncWire.seal(proof, pair: pair).write(to: root.appendingPathComponent("space.check"), options: .atomic)
        }
        try checkActive()
        try verify(root: root, pair: pair)
    }
    static func verify(root: URL, pair: SyncPair) throws {
        guard let data = try? SyncWire.read(root.appendingPathComponent("space.json")),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              marker["v"] as? Int == 1, marker["space"] as? String == pair.space,
              FileManager.default.fileExists(atPath: root.appendingPathComponent("records").path) else { throw SyncFailure.offline }
        let proof = try SyncWire.open(SyncWire.read(root.appendingPathComponent("space.check")), pair: pair)
        guard proof.text == "clipday-space-v1", proof.id == pair.space else { throw SyncFailure.invalid }
    }
    private func save() throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    func suspend() { lastPoll = nil }
    func acknowledge(_ records: [SyncRecord]) throws {
        for r in records where SyncWire.isID(r.id) {
            let file = inbox.appendingPathComponent(r.id + ".clip")
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }
    }
    @discardableResult func enqueue(_ text: String, now: Int64 = SyncWire.ms(), id: String = UUID().uuidString.lowercased()) throws -> SyncRecord {
        guard !text.isEmpty, text.utf8.count <= SyncWire.maxText, SyncWire.isID(id) else { throw SyncFailure.invalid }
        let destination = outbox.appendingPathComponent(id + ".clip")
        if fm.fileExists(atPath: destination.path) {
            let existing = try SyncWire.open(SyncWire.read(destination), pair: pair)
            guard existing.id == id, existing.device == state.device, existing.text == text, existing.created == now else { throw SyncFailure.invalid }
            return existing // Retry after an uncertain write must not allocate another record/sequence.
        }
        let files = try fm.contentsOfDirectory(at: outbox, includingPropertiesForKeys: [.fileSizeKey])
        guard files.count < 2000, files.reduce(0, { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }) < 100 * 1024 * 1024 else { throw SyncFailure.full }
        state.seq += 1
        // Persist counter first: a crash may skip a number, but can never reuse one.
        try save()
        let record = SyncRecord(id: id, space: pair.space, device: state.device, name: name, seq: state.seq, created: now, expires: now + SyncWire.lifetime, observed: state.clock, text: text)
        try SyncWire.seal(record, pair: pair).write(to: destination, options: .atomic)
        return record
    }
    func poll(now: Int64 = SyncWire.ms(), allowed: () -> Bool = { true }) throws -> SyncBatch {
        func checkActive() throws { guard allowed() else { lastPoll = nil; throw SyncFailure.suspended } }
        try checkActive()
        var batch = SyncBatch()
        let continuous = lastPoll.map { now >= $0 && now - $0 < 6000 } ?? false
        lastPoll = nil // Any failure forces a history-only catch-up on the next successful scan.
        try Self.verify(root: root, pair: pair)
        try checkActive()
        for file in try fm.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil) where file.pathExtension == "clip" {
            try checkActive()
            let data: Data, r: SyncRecord
            do { data = try SyncWire.read(file); r = try SyncWire.open(data, pair: pair) }
            catch { batch.rejected += 1; continue } // A damaged local file must not block all queued items.
            if r.expires <= now { try fm.removeItem(at: file); continue }
            let target = recordsURL.appendingPathComponent(r.id + ".clip")
            // Atomic replacement also repairs an interrupted/partial NAS write on retry.
            try checkActive()
            try data.write(to: target, options: .atomic)
            // If pause arrived during the write, leave the outbox for safe retry.
            try checkActive()
            try fm.removeItem(at: file)
            batch.uploaded += 1
        }
        try checkActive()
        batch.records = try history(now: now)
        batch.rejected += unreadableInboxCount
        var incomingBytes = batch.records.reduce(0) { $0 + $1.text.utf8.count }
        let before = state.clock
        state.seen = state.seen.filter { $0.value > now }
        var fresh: [SyncRecord] = []
        let files = try fm.contentsOfDirectory(at: recordsURL, includingPropertiesForKeys: [.fileSizeKey])
        guard files.count <= 20_000 else { throw SyncFailure.full }
        for file in files where file.pathExtension == "clip" && SyncWire.isID(file.deletingPathExtension().lastPathComponent) {
            try checkActive()
            if state.seen[file.deletingPathExtension().lastPathComponent] != nil { continue }
            do {
                let r = try SyncWire.open(SyncWire.read(file), pair: pair)
                try checkActive()
                guard file.lastPathComponent == r.id + ".clip" else { throw SyncFailure.invalid }
                if r.expires <= now { try? fm.removeItem(at: file); continue }
                guard r.created <= now + 300_000 else { batch.rejected += 1; continue }
                // A new device never writes automatically during its first scan or reconnect.
                if r.device != state.device {
                    if batch.records.count >= 2000 || incomingBytes + r.text.utf8.count > 100 * 1024 * 1024 { continue }
                    incomingBytes += r.text.utf8.count
                    try checkActive()
                    try SyncWire.seal(r, pair: pair).write(to: inbox.appendingPathComponent(r.id + ".clip"), options: .atomic)
                    batch.records.append(r)
                    if continuous, r.seq > (before[r.device] ?? 0), r.created <= now, now - r.created <= automaticWindow,
                       (r.observed[state.device] ?? 0) >= state.seq { fresh.append(r) }
                }
                state.seen[r.id] = r.expires
                state.clock[r.device] = max(state.clock[r.device] ?? 0, r.seq)
            } catch SyncFailure.suspended { throw SyncFailure.suspended }
            catch { batch.rejected += 1 } // Partial/authentication failures are retried next scan.
        }
        let devices = Set(fresh.map(\.device))
        if devices.count == 1 { batch.automatic = fresh.max(by: { $0.seq < $1.seq }) }
        batch.records.sort { $0.created < $1.created }
        try checkActive()
        try save()
        lastPoll = now
        batch.pending = (try fm.contentsOfDirectory(atPath: outbox.path)).count
        return batch
    }
}
