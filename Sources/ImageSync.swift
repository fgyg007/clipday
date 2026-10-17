import Foundation
import CryptoKit
import ImageIO
import CoreGraphics
import Darwin

// Image v1 is deliberately independent of the text v1 sequence and directory.
struct ImageManifest: Codable {
    var v = 1
    var kind = "image"
    let id: String
    let space: String
    let device: String
    let name: String
    let seq: Int64
    let created: Int64
    let expires: Int64
    let observed: [String: Int64]
    var mime = "image/png"
    let width: Int
    let height: Int
    let byteCount: Int
    var chunkSize = ImageWire.chunkSize
    let chunks: Int
    let sha256: String
}
struct ReceivedImage {
    let manifest: ImageManifest
    let png: Data // In memory only. Durable transfer files are always encrypted.
}
struct ImageBatch {
    var records: [ReceivedImage] = []
    var automatic: ReceivedImage?
    var pending = 0
    var rejected = 0
    var uploaded = 0
}

// Read native metadata with caching disabled BEFORE allocating decoded pixels.
// Parse all PNG chunk boundaries to reject APNG even if a decoder selects frame 0.
enum ImageSafety {
    static let maxDimension = 8192
    static let maxPixels = 16_777_216
    static func dimensions(_ width: Int, _ height: Int) throws {
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension,
              width <= maxPixels / height else { throw SyncFailure.invalid }
    }
    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? 0xedb88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    private static func crc(_ data: Data.SubSequence) -> UInt32 {
        var c: UInt32 = 0xffffffff
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 255)] ^ (c >> 8) }
        return c ^ 0xffffffff
    }
    static func png(_ data: Data, decode: Bool = true) throws -> (width: Int, height: Int) {
        guard data.count >= 45, data.count <= ImageWire.maxBytes,
              data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              u32(data, 8) == 13, data[12..<16] == Data("IHDR".utf8) else { throw SyncFailure.invalid }
        let width = Int(u32(data, 16)), height = Int(u32(data, 20))
        try dimensions(width, height)
        var offset = 8, ended = false, hasIDAT = false
        while offset < data.count {
            guard data.count - offset >= 12 else { throw SyncFailure.invalid }
            let length = Int(u32(data, offset))
            guard length <= data.count - offset - 12 else { throw SyncFailure.invalid }
            let type = data[(offset + 4)..<(offset + 8)]
            guard type.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  type != Data("acTL".utf8), type != Data("fcTL".utf8), type != Data("fdAT".utf8),
                  type != Data("iCCP".utf8), type != Data("zTXt".utf8), type != Data("iTXt".utf8),
                  offset == 8 || type != Data("IHDR".utf8),
                  crc(data[(offset + 4)..<(offset + 8 + length)]) == u32(data, offset + 8 + length) else { throw SyncFailure.invalid }
            if let first = type.first, first & 32 == 0,
               !["IHDR", "PLTE", "IDAT", "IEND"].contains(String(data: type, encoding: .ascii) ?? "") { throw SyncFailure.invalid }
            if type == Data("IDAT".utf8) { hasIDAT = true }
            offset += length + 12
            if type == Data("IEND".utf8) {
                guard length == 0, offset == data.count else { throw SyncFailure.invalid }
                ended = true; break
            }
        }
        guard ended, hasIDAT else { throw SyncFailure.invalid }
        let source = try nativeSource(data, type: "public.png", width: width, height: height)
        if decode {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
                  image.width == width, image.height == height,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw SyncFailure.invalid }
        }
        return (width, height)
    }
    private static func nativeSource(_ data: Data, type: String, width: Int? = nil, height: Int? = nil) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let nativeType = CGImageSourceGetType(source), nativeType as String == type, CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [String: Any],
              let w = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue else { throw SyncFailure.invalid }
        try dimensions(w, h)
        guard (width == nil || width == w), (height == nil || height == h) else { throw SyncFailure.invalid }
        return source
    }
    // Only strips ancillary metadata emitted by our native PNG encoder. It never
    // permits animated or malformed payloads; the result is fully validated below.
    static func clipboardPNG(_ data: Data) throws -> Data {
        let canonical = try strippingMetadata(data)
        _ = try png(canonical)
        return canonical
    }
    private static func strippingMetadata(_ data: Data) throws -> Data {
        guard data.count >= 8, data.count <= ImageWire.maxBytes else { throw SyncFailure.invalid }
        var output = Data(data.prefix(8)), offset = 8
        while offset < data.count {
            guard data.count - offset >= 12 else { throw SyncFailure.invalid }
            let length = Int(u32(data, offset))
            guard length <= data.count - offset - 12 else { throw SyncFailure.invalid }
            guard crc(data[(offset + 4)..<(offset + 8 + length)]) == u32(data, offset + 8 + length) else { throw SyncFailure.invalid }
            let type = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            if !["iCCP", "zTXt", "iTXt"].contains(type) { output.append(data[offset..<(offset + length + 12)]) }
            offset += length + 12
        }
        return output
    }
    static func fromTIFF(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 80 * 1024 * 1024 else { throw SyncFailure.invalid }
        let source = try nativeSource(data, type: "public.tiff")
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw SyncFailure.invalid }
        try dimensions(image.width, image.height)
        let result = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(result as CFMutableData, "public.png" as CFString, 1, nil) else { throw SyncFailure.invalid }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw SyncFailure.invalid }
        let png = try strippingMetadata(result as Data)
        _ = try self.png(png)
        return png
    }
}

enum ImageWire {
    static let maxBytes = 20 * 1024 * 1024
    static let chunkSize = 1024 * 1024
    static let maxManifest = 32_768
    static let maxStorage = 200 * 1024 * 1024
    static let maxRecords = 100
    static func isID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validate(_ m: ImageManifest, pair: SyncPair) throws {
        try pair.validate()
        try ImageSafety.dimensions(m.width, m.height)
        guard m.v == 1, m.kind == "image", m.mime == "image/png", isID(m.id), isID(m.space), isID(m.device),
              m.space == pair.space, m.seq > 0, m.created > 0, m.created <= Int64.max - SyncWire.lifetime,
              m.expires == m.created + SyncWire.lifetime, m.name.utf8.count <= 256,
              m.byteCount > 0, m.byteCount <= maxBytes, m.chunkSize == chunkSize,
              m.chunks == (m.byteCount + chunkSize - 1) / chunkSize,
              m.sha256.utf8.count == 64, m.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              m.observed.count <= 100, m.observed.allSatisfy({ isID($0.key) && $0.value >= 0 }) else { throw SyncFailure.invalid }
    }
    static func chunkLength(_ m: ImageManifest, _ index: Int) throws -> Int {
        guard index >= 0, index < m.chunks else { throw SyncFailure.invalid }
        return min(chunkSize, m.byteCount - index * chunkSize)
    }
    static func manifestAAD(_ pair: SyncPair) -> Data { Data("clipday-image-manifest-v1:\(pair.space)".utf8) }
    static func chunkAAD(_ m: ImageManifest, _ index: Int) throws -> Data {
        Data("clipday-image-chunk-v1:\(m.space):\(m.id):\(index):\(try chunkLength(m, index))".utf8)
    }
    static func seal(_ m: ImageManifest, pair: SyncPair) throws -> Data {
        try validate(m, pair: pair)
        let clear = try JSONEncoder().encode(m)
        guard clear.count <= maxManifest else { throw SyncFailure.invalid }
        return try AES.GCM.seal(clear, using: SymmetricKey(data: Data(base64Encoded: pair.key)!), authenticating: manifestAAD(pair)).combined!
    }
    static func open(_ data: Data, pair: SyncPair) throws -> ImageManifest {
        try pair.validate()
        guard data.count >= 28, data.count <= maxManifest + 28 else { throw SyncFailure.invalid }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: Data(base64Encoded: pair.key)!), authenticating: manifestAAD(pair))
        let m = try JSONDecoder().decode(ImageManifest.self, from: clear)
        try validate(m, pair: pair); return m
    }
    static func sealChunk(_ clear: Data, manifest: ImageManifest, index: Int, pair: SyncPair) throws -> Data {
        try validate(manifest, pair: pair)
        guard clear.count == (try chunkLength(manifest, index)) else { throw SyncFailure.invalid }
        return try AES.GCM.seal(clear, using: SymmetricKey(data: Data(base64Encoded: pair.key)!), authenticating: chunkAAD(manifest, index)).combined!
    }
    static func openChunk(_ encrypted: Data, manifest: ImageManifest, index: Int, pair: SyncPair) throws -> Data {
        try validate(manifest, pair: pair)
        guard encrypted.count == (try chunkLength(manifest, index)) + 28 else { throw SyncFailure.invalid }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: Data(base64Encoded: pair.key)!), authenticating: chunkAAD(manifest, index))
    }
    static func verify(_ data: Data, manifest: ImageManifest) throws {
        guard data.count == manifest.byteCount, digest(data) == manifest.sha256 else { throw SyncFailure.invalid }
        let size = try ImageSafety.png(data)
        guard size.width == manifest.width, size.height == manifest.height else { throw SyncFailure.invalid }
    }
    static func chunkName(_ id: String, _ index: Int) -> String { "\(id).\(String(format: "%03d", index)).chunk" }

    // O_NOFOLLOW and a size check on the opened descriptor prevent symlink and
    // file-replacement races from turning a bounded read into an arbitrary read.
    static func read(_ file: URL, maximum: Int) throws -> Data {
        try checkDirectory(file.deletingLastPathComponent())
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SyncFailure.invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size >= 0, info.st_size <= maximum else { throw SyncFailure.invalid }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count == Int(info.st_size), data.count <= maximum else { throw SyncFailure.invalid }
        return data
    }
    static func checkDirectory(_ directory: URL) throws {
        var path = directory.standardizedFileURL
        while path.path != "/" {
            let v = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard v.isDirectory == true, v.isSymbolicLink != true else { throw SyncFailure.invalid }
            path.deleteLastPathComponent()
        }
    }
    static func write(_ data: Data, to file: URL, privateFile: Bool) throws {
        try checkDirectory(file.deletingLastPathComponent())
        if let v = try? file.resourceValues(forKeys: [.isSymbolicLinkKey]), v.isSymbolicLink == true { throw SyncFailure.invalid }
        try data.write(to: file, options: .atomic)
        if privateFile { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    }
}

// Worker-queue confined. No NAS writes or decoded images are produced on the UI thread.
final class ImageFolderSync {
    let pair: SyncPair
    let root: URL
    let local: URL
    let name: String
    private(set) var state: SyncState
    private var lastPoll: Int64?
    private var scanOffset = 0
    private var confirmedIntents: [String: Int64] = [:]
    private let fm = FileManager.default
    var recordsURL: URL { root.appendingPathComponent("images-v1") }
    var outbox: URL { local.appendingPathComponent("outbox") }
    var inbox: URL { local.appendingPathComponent("inbox") }
    var stateURL: URL { local.appendingPathComponent("state.json") }
    private var confirmationsURL: URL { local.appendingPathComponent("intent-confirmations.json") }
    let cloudDrive: Bool
    init(folder: URL, local: URL, pair: SyncPair, name: String, device: String, cloudDrive: Bool = false) throws {
        self.cloudDrive = cloudDrive
        try pair.validate(); guard ImageWire.isID(device) else { throw SyncFailure.invalid }
        self.pair = pair; self.local = local.appendingPathComponent("images-v1"); self.name = String(name.prefix(60))
        root = FolderSync.spaceRoot(folder: folder, pair: pair, cloudDrive: cloudDrive)
        state = SyncState(); state.device = device
        if fm.fileExists(atPath: stateURL.path) { state = try JSONDecoder().decode(SyncState.self, from: ImageWire.read(stateURL, maximum: 2 * 1024 * 1024)) }
        guard state.device == device, state.seq >= 0, state.clock.count <= 100,
              state.clock.allSatisfy({ ImageWire.isID($0.key) && $0.value >= 0 }),
              state.seen.count <= 25_000, state.seen.allSatisfy({ ImageWire.isID($0.key) && $0.value > 0 }) else { throw SyncFailure.invalid }
        for directory in [self.local, outbox, inbox] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ImageWire.checkDirectory(directory)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        if fm.fileExists(atPath: confirmationsURL.path) {
            confirmedIntents = try JSONDecoder().decode([String: Int64].self, from: ImageWire.read(confirmationsURL, maximum: 32_768))
            guard confirmedIntents.count <= ImageWire.maxRecords, confirmedIntents.allSatisfy({ ImageWire.isID($0.key) && $0.value > 0 }) else { throw SyncFailure.invalid }
        }
        try save()
    }
    private func saveConfirmations() throws {
        try ImageWire.write(JSONEncoder().encode(confirmedIntents), to: confirmationsURL, privateFile: true)
    }
    // The history intent and outbox are two durable transactions. Keep an
    // encrypted sent tombstone across their acknowledgement gap, so a retry
    // after upload returns the ORIGINAL sequence instead of allocating another.
    func acknowledgeQueuedIntent(_ id: String) throws {
        guard ImageWire.isID(id) else { throw SyncFailure.invalid }
        let queued = outbox.appendingPathComponent(id + ".img")
        if fm.fileExists(atPath: queued.path) {
            let m = try manifest(queued)
            confirmedIntents[id] = m.expires
            guard confirmedIntents.count <= ImageWire.maxRecords else { throw SyncFailure.full }
            try saveConfirmations()
        }
        let receipt = outbox.appendingPathComponent(id + ".sent")
        if fm.fileExists(atPath: receipt.path) {
            _ = try manifest(receipt)
            try ImageWire.checkDirectory(outbox); try fm.removeItem(at: receipt)
        }
    }
    private func save() throws { try ImageWire.write(JSONEncoder().encode(state), to: stateURL, privateFile: true) }
    func suspend() { lastPoll = nil }
    private func list(_ directory: URL) throws -> [URL] {
        try ImageWire.checkDirectory(directory)
        var failure: Error?
        guard let scan = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in failure = error; return false }) else { throw SyncFailure.offline }
        var files: [URL] = []
        while let file = scan.nextObject() as? URL {
            guard files.count < 25_000 else { throw SyncFailure.full }
            files.append(file)
        }
        if let failure { throw failure }
        return files
    }
    private func ownedID(_ file: URL) -> String? {
        let parts = file.lastPathComponent.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, ImageWire.isID(String(first)) else { return nil }
        if parts.count == 2, parts[1] == "img" || parts[1] == "sent" { return String(first) }
        if parts.count == 3, parts[2] == "chunk", parts[1].count == 3,
           let n = Int(parts[1]), n >= 0, n < 20, String(format: "%03d", n) == parts[1] { return String(first) }
        return nil
    }
    private func remove(_ m: ImageManifest, from directory: URL, allowed: () -> Bool) throws {
        // Remove the commit marker first. All names below are derived, never supplied paths.
        for name in [m.id + ".img"] + (0..<m.chunks).map({ ImageWire.chunkName(m.id, $0) }) {
            guard allowed() else { throw SyncFailure.suspended }
            try ImageWire.checkDirectory(directory)
            let file = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path) {
                let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true else { throw SyncFailure.invalid }
                try fm.removeItem(at: file)
            }
        }
    }
    private func prune(_ directory: URL, now: Int64, orphansOnly: Bool = false, allowed: () -> Bool) throws {
        let files = try list(directory)
        for file in files {
            guard allowed() else { throw SyncFailure.suspended }
            guard ownedID(file) != nil, !orphansOnly || file.pathExtension != "sent" else { continue }
            if !orphansOnly, ["img", "sent"].contains(file.pathExtension), let m = try? manifest(file), m.expires <= now {
                if file.pathExtension == "sent" { try ImageWire.checkDirectory(directory); try fm.removeItem(at: file) }
                else { try remove(m, from: directory, allowed: allowed) }
            } else if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey, .isRegularFileKey]),
                      values.isSymbolicLink != true, values.isRegularFile == true,
                      let date = values.contentModificationDate,
                      date.timeIntervalSince1970 * 1000 < Double(now) - Double(SyncWire.lifetime + 300_000) {
                // Also bounds interrupted manifest-last uploads. A five-minute skew
                // margin ensures no allowed future-created record is removed early.
                try ImageWire.checkDirectory(directory); try fm.removeItem(at: file)
            }
        }
    }
    private func manifest(_ file: URL) throws -> ImageManifest {
        let m = try ImageWire.open(ImageWire.read(file, maximum: ImageWire.maxManifest + 28), pair: pair)
        guard ["img", "sent"].contains(file.pathExtension), file.deletingPathExtension().lastPathComponent == m.id else { throw SyncFailure.invalid }
        return m
    }
    private func load(_ m: ImageManifest, from directory: URL, allowed: () -> Bool) throws -> ReceivedImage {
        var clear = Data(); clear.reserveCapacity(m.byteCount)
        for index in 0..<m.chunks {
            guard allowed() else { throw SyncFailure.suspended }
            let encrypted = try ImageWire.read(directory.appendingPathComponent(ImageWire.chunkName(m.id, index)), maximum: (try ImageWire.chunkLength(m, index)) + 28)
            clear.append(try ImageWire.openChunk(encrypted, manifest: m, index: index, pair: pair))
        }
        guard allowed() else { throw SyncFailure.suspended }
        try ImageWire.verify(clear, manifest: m)
        return ReceivedImage(manifest: m, png: clear)
    }
    private func storage(adding m: ImageManifest, to directory: URL) throws {
        var bytes = 0, records = Set<String>()
        for dir in [inbox, outbox] {
            for file in try list(dir) {
                guard let id = ownedID(file) else { continue }
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true, let size = values.fileSize,
                      size >= 0, size <= ImageWire.maxBytes + ImageWire.maxManifest else { throw SyncFailure.invalid }
                if dir == directory && id == m.id { continue } // Replacement is idempotent.
                bytes += size; records.insert(dir.lastPathComponent + "/" + id)
            }
        }
        let addedBytes = m.byteCount + m.chunks * 28 + (try ImageWire.seal(m, pair: pair)).count
        guard records.count < ImageWire.maxRecords, bytes + addedBytes <= ImageWire.maxStorage else { throw SyncFailure.full }
    }
    @discardableResult func enqueue(_ png: Data, now: Int64 = SyncWire.ms(), id: String = UUID().uuidString.lowercased(), allowed: () -> Bool = { true }) throws -> ImageManifest {
        guard allowed() else { throw SyncFailure.suspended }
        guard ImageWire.isID(id), now > 0, now <= Int64.max - SyncWire.lifetime else { throw SyncFailure.invalid }
        let size = try ImageSafety.png(png), hash = ImageWire.digest(png)
        let target = outbox.appendingPathComponent(id + ".img")
        if fm.fileExists(atPath: target.path) {
            let existing = try manifest(target)
            guard existing.device == state.device, existing.created == now, existing.sha256 == hash else { throw SyncFailure.invalid }
            _ = try load(existing, from: outbox, allowed: allowed)
            return existing
        }
        let receipt = outbox.appendingPathComponent(id + ".sent")
        if fm.fileExists(atPath: receipt.path) {
            let sent = try manifest(receipt)
            guard sent.device == state.device, sent.created == now, sent.sha256 == hash else { throw SyncFailure.invalid }
            return sent // Already uploaded, but the local capture intent was not yet acknowledged.
        }
        try prune(outbox, now: now, allowed: allowed); try prune(inbox, now: now, allowed: allowed)
        guard state.seq < Int64.max else { throw SyncFailure.full }
        let m = ImageManifest(id: id, space: pair.space, device: state.device, name: name, seq: state.seq + 1,
                              created: now, expires: now + SyncWire.lifetime, observed: state.clock, width: size.width, height: size.height,
                              byteCount: png.count, chunks: (png.count + ImageWire.chunkSize - 1) / ImageWire.chunkSize, sha256: hash)
        try storage(adding: m, to: outbox)
        guard allowed() else { throw SyncFailure.suspended }
        state.seq = m.seq; try save() // Never reuse a sequence after a crash.
        for index in 0..<m.chunks {
            guard allowed() else { throw SyncFailure.suspended }
            let start = index * ImageWire.chunkSize, end = start + (try ImageWire.chunkLength(m, index))
            try ImageWire.write(ImageWire.sealChunk(png.subdata(in: start..<end), manifest: m, index: index, pair: pair),
                                to: outbox.appendingPathComponent(ImageWire.chunkName(id, index)), privateFile: true)
        }
        guard allowed() else { throw SyncFailure.suspended }
        try ImageWire.write(ImageWire.seal(m, pair: pair), to: target, privateFile: true)
        return m
    }
    func acknowledge(_ records: [ReceivedImage], allowed: () -> Bool = { true }) throws {
        for record in records { try remove(record.manifest, from: inbox, allowed: allowed) }
    }
    func poll(now: Int64 = SyncWire.ms(), allowed: () -> Bool = { true }) throws -> ImageBatch {
        func check() throws { guard allowed() else { lastPoll = nil; throw SyncFailure.suspended } }
        try check()
        var batch = ImageBatch()
        let continuous = lastPoll.map { now >= $0 && now - $0 < 6000 } ?? false
        lastPoll = nil
        try ImageWire.checkDirectory(root)
        try FolderSync.verify(root: root, pair: pair)
        try check()
        try fm.createDirectory(at: recordsURL, withIntermediateDirectories: false)
        try ImageWire.checkDirectory(recordsURL)
        confirmedIntents = confirmedIntents.filter { $0.value > now }
        try saveConfirmations()
        for dir in [outbox, inbox] { try prune(dir, now: now, allowed: allowed) }
        try prune(recordsURL, now: now, orphansOnly: true, allowed: allowed)
        for file in try list(outbox) where file.pathExtension == "img" && ownedID(file) != nil {
            try check()
            guard batch.uploaded < 2 else { break }
            do {
                let m = try manifest(file)
                guard m.expires > now, m.created <= now + 300_000 else { continue }
                _ = try load(m, from: outbox, allowed: allowed)
                for index in 0..<m.chunks {
                    try check()
                    let name = ImageWire.chunkName(m.id, index)
                    let data = try ImageWire.read(outbox.appendingPathComponent(name), maximum: (try ImageWire.chunkLength(m, index)) + 28)
                    try check(); try ImageWire.write(data, to: recordsURL.appendingPathComponent(name), privateFile: false)
                }
                try check()
                try ImageWire.write(ImageWire.read(file, maximum: ImageWire.maxManifest + 28), to: recordsURL.appendingPathComponent(m.id + ".img"), privateFile: false)
                try check() // A late pause keeps the same durable ID for retry.
                if confirmedIntents[m.id] == nil {
                    try ImageWire.write(ImageWire.seal(m, pair: pair), to: outbox.appendingPathComponent(m.id + ".sent"), privateFile: true)
                }
                try check()
                try remove(m, from: outbox, allowed: allowed)
                confirmedIntents.removeValue(forKey: m.id); try saveConfirmations()
                batch.uploaded += 1
            } catch SyncFailure.suspended { throw SyncFailure.suspended }
            catch { batch.rejected += 1 }
        }
        for file in try list(inbox) where file.pathExtension == "img" && ownedID(file) != nil {
            try check()
            guard batch.records.count < 2 else { break }
            do {
                let m = try manifest(file)
                if m.expires > now, m.created <= now + 300_000 { batch.records.append(try load(m, from: inbox, allowed: allowed)) }
            } catch SyncFailure.suspended { throw SyncFailure.suspended }
            catch { batch.rejected += 1 }
        }
        state.seen = state.seen.filter { $0.value > now }
        let before = state.clock
        var fresh: [ReceivedImage] = [], freshDevices = Set<String>()
        let files = try list(recordsURL).filter { $0.pathExtension == "img" && ownedID($0) != nil }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var processed = 0, truncated = false
        if !files.isEmpty {
            let start = scanOffset % files.count
            for delta in 0..<files.count {
                let position = (start + delta) % files.count, file = files[position]
                try check()
                if state.seen[file.deletingPathExtension().lastPathComponent] != nil { continue }
                guard processed < 1000 else { scanOffset = position; truncated = true; break }
                processed += 1
                do {
                    let m = try manifest(file)
                    if m.expires <= now { try remove(m, from: recordsURL, allowed: allowed); continue }
                    guard m.created <= now + 300_000 else { continue }
                    let eligible = continuous && m.seq > (before[m.device] ?? 0) && m.created <= now && now - m.created <= (cloudDrive ? 300_000 : 10_000) && (m.observed[state.device] ?? 0) >= state.seq
                    if m.device != state.device, eligible { freshDevices.insert(m.device) }
                    guard state.clock[m.device] != nil || state.clock.count < 100, state.seen.count < 25_000 else { throw SyncFailure.full }
                    if m.device != state.device {
                        guard batch.records.count < 2 || batch.records.contains(where: { $0.manifest.id == m.id }) else { truncated = true; continue }
                        let incoming = try load(m, from: recordsURL, allowed: allowed)
                        if !batch.records.contains(where: { $0.manifest.id == m.id }) {
                            try storage(adding: m, to: inbox)
                            for index in 0..<m.chunks {
                                try check()
                                let name = ImageWire.chunkName(m.id, index)
                                let encrypted = try ImageWire.read(recordsURL.appendingPathComponent(name), maximum: (try ImageWire.chunkLength(m, index)) + 28)
                                _ = try ImageWire.openChunk(encrypted, manifest: m, index: index, pair: pair)
                                try check(); try ImageWire.write(encrypted, to: inbox.appendingPathComponent(name), privateFile: true)
                            }
                            // Verify the exact locally persisted chunks, not an earlier NAS snapshot.
                            _ = try load(m, from: inbox, allowed: allowed)
                            try check(); try ImageWire.write(ImageWire.seal(m, pair: pair), to: inbox.appendingPathComponent(m.id + ".img"), privateFile: true)
                            batch.records.append(incoming)
                        }
                        if eligible { fresh.append(incoming) }
                    }
                    try check()
                    state.seen[m.id] = m.expires; state.clock[m.device] = max(state.clock[m.device] ?? 0, m.seq)
                } catch SyncFailure.suspended { throw SyncFailure.suspended }
                catch { batch.rejected += 1 } // Never mark missing/corrupt/paused content seen.
            }
        }
        if !truncated, freshDevices.count == 1 { batch.automatic = fresh.max { $0.manifest.seq < $1.manifest.seq } }
        batch.records.sort { $0.manifest.created < $1.manifest.created }
        try check(); try save(); lastPoll = now
        batch.pending = try list(outbox).filter { $0.pathExtension == "img" && ownedID($0) != nil }.count
        return batch
    }
}
