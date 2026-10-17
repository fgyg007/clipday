import Foundation
import CryptoKit

enum ClipKind: String, Codable { case text, image }

struct Clip: Codable, Identifiable {
    let id: UUID
    let created: Date
    let kind: ClipKind
    let data: Data
    let digest: String
    var source: String? = nil
    var imageSyncSpace: String? = nil
    var text: String { kind == .text ? (String(data: data, encoding: .utf8) ?? "") : "图片" }
    var preview: String { kind == .image ? "图片" : String(text.prefix(600)) }
    var expires: Date { created.addingTimeInterval(ClipStore.lifetime) }
}

private struct StoredClip: Codable {
    let id: UUID
    let created: Date
    let kind: ClipKind
    let digest: String
    var source: String? = nil
    var imageSyncSpace: String? = nil
}

enum ClipError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class ClipStore {
    static let lifetime: TimeInterval = 24 * 60 * 60
    static let maxItemBytes = 20 * 1024 * 1024
    static let maxTotalBytes = 200 * 1024 * 1024
    static let maxCount = 2000
    let directory: URL
    let fm = FileManager.default
    private(set) var clips: [Clip] = []
    var lastEvictedCount = 0
    var database: URL { directory.appendingPathComponent("history.json") }
    var payloads: URL { directory.appendingPathComponent("items") }
    private var needsPersist = false
    // Keep unavailable entries in the existing index so a restored blob can recover.
    // A single missing/corrupt blob must not disable capture or delete other history.
    private var unavailable: [StoredClip] = []
    private(set) var unavailableCount = 0

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/io.jlmac.ClipDay")) {
        self.directory = directory
    }

    func load(now: Date = Date()) throws {
        guard fm.fileExists(atPath: database.path) else { return }
        // Expired data is removed on launch before it reaches the interface.
        let index = try JSONDecoder().decode([StoredClip].self, from: Data(contentsOf: database))
        clips = []; unavailable = []
        for entry in index where entry.created.addingTimeInterval(Self.lifetime) > now && entry.created <= now.addingTimeInterval(300) {
            do { clips.append(try read(entry)) }
            catch { unavailable.append(entry) }
        }
        unavailableCount = unavailable.count
        // Prune expired payloads without loading their contents into memory.
        try persist()
    }

    private func read(_ entry: StoredClip) throws -> Clip {
        let file = payloads.appendingPathComponent(entry.id.uuidString + ".bin")
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Self.maxItemBytes + 1) <= Self.maxItemBytes else { throw ClipError.message("历史文件不可读取。") }
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard !data.isEmpty, digest == entry.digest, entry.kind != .text || String(data: data, encoding: .utf8) != nil else {
            throw ClipError.message("历史文件不完整。")
        }
        var displayData = data
        #if CLOUD
        // Preserve the original legacy blob and its digest on disk while keeping
        // unsafe ancillary metadata away from native preview/copy decoders.
        if entry.kind == .image { displayData = try ImageSafety.clipboardPNG(data) }
        #endif
        return Clip(id: entry.id, created: entry.created, kind: entry.kind, data: displayData, digest: entry.digest, source: entry.source, imageSyncSpace: entry.imageSyncSpace)
    }

    private func persist() throws {
        needsPersist = true
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: payloads, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for clip in clips {
            let file = payloads.appendingPathComponent(clip.id.uuidString + ".bin")
            if !fm.fileExists(atPath: file.path) {
                try clip.data.write(to: file, options: [.atomic])
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        let index = clips.map { StoredClip(id: $0.id, created: $0.created, kind: $0.kind, digest: $0.digest, source: $0.source, imageSyncSpace: $0.imageSyncSpace) } + unavailable
        try JSONEncoder().encode(index).write(to: database, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
        let valid = Set(index.map { $0.id.uuidString + ".bin" })
        for file in try fm.contentsOfDirectory(at: payloads, includingPropertiesForKeys: nil) where file.pathExtension == "bin" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil && !valid.contains(file.lastPathComponent) {
            try fm.removeItem(at: file)
        }
        needsPersist = false
    }

    @discardableResult func prune(now: Date = Date()) throws -> Bool {
        let previous = clips.count, previousUnavailable = unavailable.count
        clips.removeAll { $0.expires <= now || $0.created > now.addingTimeInterval(300) }
        unavailable = unavailable.filter { entry in
            guard entry.created.addingTimeInterval(Self.lifetime) > now, entry.created <= now.addingTimeInterval(300) else { return false }
            if let recovered = try? read(entry) { clips.append(recovered); return false }
            return true
        }
        unavailableCount = unavailable.count
        clips.sort { $0.created > $1.created }
        if clips.count != previous || unavailable.count != previousUnavailable || needsPersist { try persist(); return true }
        return false
    }

    @discardableResult func append(kind: ClipKind, data: Data, now: Date = Date(), id: UUID = UUID(), created: Date? = nil, imageSyncSpace: String? = nil) throws -> Clip {
        guard !data.isEmpty else { throw ClipError.message("空内容未记录。") }
        guard data.count <= Self.maxItemBytes else { throw ClipError.message("单条内容超过 20 MB，未记录。") }
        if kind == .text, String(data: data, encoding: .utf8) == nil { throw ClipError.message("文字编码无法识别。") }
        #if CLOUD
        if kind == .image { _ = try ImageSafety.png(data) }
        #endif
        try prune(now: now)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let previous = clips, previousEvicted = lastEvictedCount
        clips.removeAll { $0.id == id || ($0.kind == kind && $0.digest == digest && $0.imageSyncSpace == nil) }
        #if CLOUD
        if kind == .image, clips.filter({ $0.kind == .image }).count >= ImageWire.maxRecords || clips.reduce(0, { $0 + $1.data.count }) + data.count > Self.maxTotalBytes {
            clips = previous; throw ClipError.message("图片历史容量已满，此条未记录；请等待旧记录到期或删除不需要的历史。")
        }
        #endif
        let clip = Clip(id: id, created: created ?? now, kind: kind, data: data, digest: digest, imageSyncSpace: kind == .image ? imageSyncSpace : nil)
        clips.insert(clip, at: 0)
        var bytes = clips.reduce(0) { $0 + $1.data.count }
        lastEvictedCount = 0
        while clips.count > Self.maxCount || bytes > Self.maxTotalBytes {
            guard let index = clips.lastIndex(where: { $0.imageSyncSpace == nil }) else { clips = previous; throw ClipError.message("待同步图片已占满本机容量，请等待上传或旧记录到期。") }
            bytes -= clips.remove(at: index).data.count; lastEvictedCount += 1
        }
        do { try persist() }
        catch { clips = previous; lastEvictedCount = previousEvicted; throw error }
        return clip
    }

    // Import a whole scan in one disk transaction, preserving original expiry.
    func importTexts(_ entries: [(id: UUID, text: String, created: Date, source: String)], now: Date = Date()) throws {
        try prune(now: now)
        let previous = clips
        var changed = false
        for entry in entries {
            let data = Data(entry.text.utf8)
            guard !data.isEmpty, data.count <= Self.maxItemBytes, entry.created.addingTimeInterval(Self.lifetime) > now,
                  entry.created <= now.addingTimeInterval(300), !clips.contains(where: { $0.id == entry.id }) else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if clips.contains(where: { $0.kind == .text && $0.digest == digest && $0.created >= entry.created }) { continue }
            clips.removeAll { $0.kind == .text && $0.digest == digest }
            clips.append(Clip(id: entry.id, created: entry.created, kind: .text, data: data, digest: digest, source: entry.source))
            changed = true
        }
        guard changed || needsPersist else { return }
        clips.sort { $0.created > $1.created }
        var bytes = clips.reduce(0) { $0 + $1.data.count }
        while clips.count > Self.maxCount || bytes > Self.maxTotalBytes {
            guard let index = clips.lastIndex(where: { $0.imageSyncSpace == nil }) else { clips = previous; throw ClipError.message("历史容量已满，待同步图片将继续保留。") }
            bytes -= clips.remove(at: index).data.count
        }
        do { try persist() }
        catch { clips = previous; throw error }
    }

    #if CLOUD
    func markImageQueued(_ id: String, space: String) throws {
        guard let uuid = UUID(uuidString: id), let index = clips.firstIndex(where: { $0.id == uuid && $0.imageSyncSpace == space }) else { return }
        let previous = clips[index]
        clips[index].imageSyncSpace = nil
        do { try persist() } catch { clips[index] = previous; throw error }
    }
    func importImages(_ entries: [ReceivedImage], now: Date = Date()) throws {
        try prune(now: now)
        let previous = clips
        do {
            for entry in entries {
                let m = entry.manifest
                let created = Date(timeIntervalSince1970: Double(m.created) / 1000)
                guard m.expires > SyncWire.ms(now), created <= now.addingTimeInterval(300) else { continue }
                try ImageWire.verify(entry.png, manifest: m)
                guard let id = UUID(uuidString: m.id) else { throw SyncFailure.invalid }
                if clips.contains(where: { $0.id == id && $0.kind == .image && $0.digest == m.sha256 }) { continue }
                if clips.contains(where: { $0.id == id }) { throw SyncFailure.invalid }
                if clips.contains(where: { $0.kind == .image && $0.digest == m.sha256 && $0.created >= created }) { continue }
                clips.removeAll { $0.kind == .image && $0.digest == m.sha256 && $0.imageSyncSpace == nil }
                guard clips.filter({ $0.kind == .image }).count < ImageWire.maxRecords,
                      clips.count < Self.maxCount,
                      clips.reduce(0, { $0 + $1.data.count }) + entry.png.count <= Self.maxTotalBytes else { throw SyncFailure.full }
                clips.append(Clip(id: id, created: created, kind: .image, data: entry.png, digest: m.sha256, source: m.name))
            }
            clips.sort { $0.created > $1.created }
            try persist()
        } catch { clips = previous; throw error }
    }
    #endif

    func active(_ id: UUID, now: Date = Date()) throws -> Clip {
        try prune(now: now)
        guard let clip = clips.first(where: { $0.id == id }) else { throw ClipError.message("这条记录已到期或已删除。") }
        return clip
    }
    func remove(_ id: UUID) throws {
        guard !clips.contains(where: { $0.id == id && $0.imageSyncSpace != nil }),
              !unavailable.contains(where: { $0.id == id && $0.imageSyncSpace != nil }) else {
            throw ClipError.message("这张图片尚未进入加密待发队列，暂不能删除；请等待入队或 24 小时到期。")
        }
        clips.removeAll { $0.id == id }; try persist()
    }
    func clear() throws {
        guard !clips.contains(where: { $0.imageSyncSpace != nil }), !unavailable.contains(where: { $0.imageSyncSpace != nil }) else {
            throw ClipError.message("有图片尚未进入加密待发队列，暂不能清空；已保留历史与待发记录。")
        }
        clips = []; unavailable = []; unavailableCount = 0; try persist()
    }

    func export(_ id: UUID, to downloads: URL, now: Date = Date()) throws -> URL {
        let clip = try active(id, now: now)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let ext = clip.kind == .text ? "txt" : "png"
        let base = "剪贴板-\(formatter.string(from: now))-\(clip.id.uuidString.prefix(6))"
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        // Never overwrite an existing download, including repeated saves within one second.
        for n in 0..<10000 {
            let suffix = n == 0 ? "" : "-\(n)"
            let path = downloads.appendingPathComponent(base + suffix + "." + ext)
            do { try clip.data.write(to: path, options: [.withoutOverwriting]); return path }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { continue }
        }
        throw ClipError.message("无法创建不重名的文件。")
    }
}
