import Foundation
import CryptoKit

enum ClipKind: String, Codable { case text, image }

struct Clip: Codable, Identifiable {
    let id: UUID
    let created: Date
    let kind: ClipKind
    let data: Data
    let digest: String
    var text: String { kind == .text ? (String(data: data, encoding: .utf8) ?? "") : "图片" }
    var preview: String { kind == .image ? "图片" : String(text.prefix(600)) }
    var expires: Date { created.addingTimeInterval(ClipStore.lifetime) }
}

private struct StoredClip: Codable {
    let id: UUID
    let created: Date
    let kind: ClipKind
    let digest: String
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

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/io.jlmac.ClipDay")) {
        self.directory = directory
    }

    func load(now: Date = Date()) throws {
        guard fm.fileExists(atPath: database.path) else { return }
        // Expired data is removed on launch before it reaches the interface.
        let index = try JSONDecoder().decode([StoredClip].self, from: Data(contentsOf: database))
        clips = try index.filter { $0.created.addingTimeInterval(Self.lifetime) > now && $0.created <= now.addingTimeInterval(300) }.map { entry in
            let data = try Data(contentsOf: payloads.appendingPathComponent(entry.id.uuidString + ".bin"))
            return Clip(id: entry.id, created: entry.created, kind: entry.kind, data: data, digest: entry.digest)
        }
        // Prune expired payloads without loading their contents into memory.
        try persist()
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
        let index = clips.map { StoredClip(id: $0.id, created: $0.created, kind: $0.kind, digest: $0.digest) }
        try JSONEncoder().encode(index).write(to: database, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
        let valid = Set(clips.map { $0.id.uuidString + ".bin" })
        for file in try fm.contentsOfDirectory(at: payloads, includingPropertiesForKeys: nil) where file.pathExtension == "bin" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil && !valid.contains(file.lastPathComponent) {
            try fm.removeItem(at: file)
        }
        needsPersist = false
    }

    @discardableResult func prune(now: Date = Date()) throws -> Bool {
        let previous = clips.count
        clips.removeAll { $0.expires <= now || $0.created > now.addingTimeInterval(300) }
        if clips.count != previous || needsPersist { try persist(); return true }
        return false
    }

    @discardableResult func append(kind: ClipKind, data: Data, now: Date = Date()) throws -> Clip {
        guard !data.isEmpty else { throw ClipError.message("空内容未记录。") }
        guard data.count <= Self.maxItemBytes else { throw ClipError.message("单条内容超过 20 MB，未记录。") }
        if kind == .text, String(data: data, encoding: .utf8) == nil { throw ClipError.message("文字编码无法识别。") }
        try prune(now: now)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        clips.removeAll { $0.kind == kind && $0.digest == digest }
        let clip = Clip(id: UUID(), created: now, kind: kind, data: data, digest: digest)
        clips.insert(clip, at: 0)
        var bytes = clips.reduce(0) { $0 + $1.data.count }
        lastEvictedCount = 0
        while clips.count > Self.maxCount || bytes > Self.maxTotalBytes {
            bytes -= clips.removeLast().data.count; lastEvictedCount += 1
        }
        try persist()
        return clip
    }

    func active(_ id: UUID, now: Date = Date()) throws -> Clip {
        try prune(now: now)
        guard let clip = clips.first(where: { $0.id == id }) else { throw ClipError.message("这条记录已到期或已删除。") }
        return clip
    }
    func remove(_ id: UUID) throws { clips.removeAll { $0.id == id }; try persist() }
    func clear() throws { clips = []; try persist() }

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
