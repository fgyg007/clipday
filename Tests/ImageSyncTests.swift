import Foundation
import CryptoKit

@main enum ImageSyncTests {
    static var count = 0
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw NSError(domain: "ImageSyncTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        count += 1; print("PASS: " + name)
    }
    static func rejects(_ name: String, _ body: () throws -> Void) throws {
        var rejected = false; do { try body() } catch { rejected = true }
        try check(rejected, name)
    }
    static func number(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    static func chunk(_ type: String, _ payload: Data) -> Data {
        let content = Data(type.utf8) + payload
        var crc: UInt32 = 0xffffffff
        for byte in content {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1 }
        }
        return number(UInt32(payload.count)) + content + number(crc ^ 0xffffffff)
    }
    static func insert(_ png: Data, type: String, payload: Data) -> Data {
        Data(png.dropLast(12)) + chunk(type, payload) + Data(png.suffix(12))
    }
    struct Fixture: Decodable {
        let keyBase64: String
        let space: String
        let pngBase64: String
        let manifest: ImageManifest
        let manifestAad: String
        let manifestEnvelopeBase64: String
        let chunkAad: String
        let chunkEnvelopeBase64: String
    }
    static func fixture() throws -> (Fixture, Data, SyncPair) {
        let url = URL(fileURLWithPath: "Tests/Fixtures/image-v1.json")
        let vector = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        return (vector, Data(base64Encoded: vector.pngBase64)!, SyncPair(space: vector.space, key: vector.keyBase64))
    }
    static func wire(_ vector: Fixture, _ png: Data, _ pair: SyncPair) throws {
        let m = try ImageWire.open(Data(base64Encoded: vector.manifestEnvelopeBase64)!, pair: pair)
        try check(m.id == vector.manifest.id && m.name == vector.manifest.name && m.width == 2 && m.height == 2, "shared manifest fixture decrypts with Unicode and dimensions")
        try check(String(data: ImageWire.manifestAAD(pair), encoding: .utf8) == vector.manifestAad, "manifest AAD matches shared specification")
        try check(String(data: ImageWire.chunkAAD(m, 0), encoding: .utf8) == vector.chunkAad, "chunk AAD matches shared specification")
        let encrypted = Data(base64Encoded: vector.chunkEnvelopeBase64)!
        let plain = try ImageWire.openChunk(encrypted, manifest: m, index: 0, pair: pair)
        try check(plain == png && ImageWire.digest(plain) == vector.manifest.sha256, "shared chunk fixture decrypts and complete PNG SHA-256 matches")
        try ImageWire.verify(plain, manifest: m)
        try check(try ImageSafety.png(png).width == 2, "PNG native metadata and decoded dimensions validated")
        let sealed = try ImageWire.seal(m, pair: pair)
        try check(try ImageWire.open(sealed, pair: pair).sha256 == m.sha256, "manifest encryption round trip")
        try check(try ImageWire.openChunk(ImageWire.sealChunk(png, manifest: m, index: 0, pair: pair), manifest: m, index: 0, pair: pair) == png, "chunk encryption round trip")
        var corrupt = encrypted; corrupt[20] ^= 1
        try rejects("tampered chunk rejected") { _ = try ImageWire.openChunk(corrupt, manifest: m, index: 0, pair: pair) }
        try rejects("wrong chunk index rejected") { _ = try ImageWire.openChunk(encrypted, manifest: m, index: 1, pair: pair) }
        try rejects("wrong space manifest rejected") { _ = try ImageWire.open(sealed, pair: .create()) }
        try rejects("wrong key chunk rejected") { _ = try ImageWire.openChunk(encrypted, manifest: m, index: 0, pair: SyncPair(space: pair.space, key: SyncPair.create().key)) }
        try rejects("MIME confusion rejected") { var bad = m; bad.mime = "image/svg+xml"; _ = try ImageWire.seal(bad, pair: pair) }
        try rejects("version confusion rejected") { var bad = m; bad.v = 2; _ = try ImageWire.seal(bad, pair: pair) }
        try rejects("chunk size cannot be chosen by sender") { var bad = m; bad.chunkSize = 3; _ = try ImageWire.seal(bad, pair: pair) }
        try rejects("truncated PNG rejected") { _ = try ImageSafety.png(Data(png.dropLast())) }
        try rejects("SVG is not a PNG") { _ = try ImageSafety.png(Data("<svg width=\"2\" height=\"2\"/>".utf8)) }
        var crcBad = png; crcBad[29] ^= 1
        try rejects("PNG CRC corruption rejected before native decode") { _ = try ImageSafety.png(crcBad) }
        try rejects("APNG animation rejected") { _ = try ImageSafety.png(insert(png, type: "acTL", payload: number(1) + number(0))) }
        for type in ["iCCP", "zTXt", "iTXt"] {
            try rejects("unsafe metadata " + type + " rejected before native decode") { _ = try ImageSafety.png(insert(png, type: type, payload: Data([0, 0]))) }
        }
        let profiled = insert(png, type: "iCCP", payload: Data("Profile\0\0".utf8) + Data([120, 156, 0]))
        try check(try ImageSafety.clipboardPNG(profiled) == png, "clipboard normalization strips ICC metadata without asking native decoder to decompress it")
        try rejects("clipboard normalization never flattens APNG") { _ = try ImageSafety.clipboardPNG(insert(png, type: "acTL", payload: number(1) + number(0))) }
        var huge = png; huge.replaceSubrange(16..<20, with: number(8193))
        try rejects("oversized header rejected before native decode") { _ = try ImageSafety.png(huge) }
        try rejects("oversized encoded PNG rejected before native decode") { _ = try ImageSafety.png(Data(repeating: 0, count: ImageWire.maxBytes + 1)) }
        try rejects("pixel allocation bound independent of dimension bound") { try ImageSafety.dimensions(8192, 8192) }
        try rejects("zero dimension rejected") { try ImageSafety.dimensions(0, 2) }
        try check(!ImageWire.isID("{11111111-1111-4111-8111-111111111111}"), "noncanonical UUID rejected")
    }
    static func engine(_ png: Data, root: URL) throws {
        let fm = FileManager.default, now = SyncWire.ms()
        let pair = SyncPair.create()
        try FolderSync.setup(folder: root, pair: pair, create: true)
        let textA = try FolderSync(folder: root, local: root.appendingPathComponent("a"), pair: pair, name: "Mac A")
        let textB = try FolderSync(folder: root, local: root.appendingPathComponent("b"), pair: pair, name: "Windows B")
        let a = try ImageFolderSync(folder: root, local: textA.local, pair: pair, name: "Mac A", device: textA.state.device)
        let b = try ImageFolderSync(folder: root, local: textB.local, pair: pair, name: "Windows B", device: textB.state.device)
        _ = try a.poll(now: now); _ = try b.poll(now: now)
        let m = try a.enqueue(png, now: now + 100)
        try check(textA.state.seq == 0 && a.state.device == textA.state.device && a.state.seq == 1, "image sequence is independent and shares stable device ID")
        let retry = try a.enqueue(png, now: now + 100, id: m.id)
        try check(retry.seq == m.seq && retry.expires == m.expires, "same queue ID retry preserves sequence and original expiry")
        try rejects("retry ID cannot replace different PNG") { _ = try a.enqueue(insert(png, type: "tEXt", payload: Data("Comment\0changed".utf8)), now: now + 100, id: m.id) }
        let queueChunk = a.outbox.appendingPathComponent(ImageWire.chunkName(m.id, 0))
        try check(try Data(contentsOf: queueChunk) != png, "durable outbox never stores plaintext PNG")
        let mode = try fm.attributesOfItem(atPath: queueChunk.path)[.posixPermissions] as? NSNumber
        try check(mode?.intValue == 0o600, "encrypted local chunks have private filesystem permissions")
        let uploaded = try a.poll(now: now + 200)
        try check(uploaded.uploaded == 1 && uploaded.pending == 0, "image manifest is committed after complete chunk upload")
        let preAckRestart = try ImageFolderSync(folder: root, local: textA.local, pair: pair, name: "A", device: textA.state.device)
        let sentRetry = try preAckRestart.enqueue(png, now: now + 100, id: m.id)
        try check(sentRetry.seq == m.seq && preAckRestart.state.seq == m.seq && !fm.fileExists(atPath: a.outbox.appendingPathComponent(m.id + ".img").path), "restart after upload before history acknowledgement keeps original sequence without re-upload")
        try preAckRestart.acknowledgeQueuedIntent(m.id)
        try check(!fm.fileExists(atPath: a.outbox.appendingPathComponent(m.id + ".sent").path), "history acknowledgement retires encrypted sent tombstone")
        let received = try b.poll(now: now + 300)
        try check(received.records.count == 1 && received.automatic?.manifest.id == m.id && received.records[0].png == png, "continuous fresh causal image automatically becomes eligible")
        try b.acknowledge(received.records)
        try check(try b.poll(now: now + 400).records.isEmpty, "acknowledged image does not repeat")
        let restarted = try ImageFolderSync(folder: root, local: textB.local, pair: pair, name: "B", device: textB.state.device)
        try check(try restarted.poll(now: now + 500).records.isEmpty, "image seen state survives restart")
        b.suspend()
        let backlog = try a.enqueue(png, now: now + 600); _ = try a.poll(now: now + 700)
        let catchup = try b.poll(now: now + 800)
        try check(catchup.records.contains { $0.manifest.id == backlog.id } && catchup.automatic == nil, "reconnect image goes to history without replacing clipboard")
        try b.acknowledge(catchup.records)
        _ = try a.enqueue(png, now: now + 900); _ = try b.enqueue(png, now: now + 900)
        let ap = try a.poll(now: now + 1000), bp = try b.poll(now: now + 1000), ap2 = try a.poll(now: now + 1100)
        try check(ap.automatic == nil && bp.automatic == nil && ap2.automatic == nil, "simultaneous image copies do not overwrite either clipboard")
        try a.acknowledge(ap.records + ap2.records); try b.acknowledge(bp.records)

        let big = insert(png, type: "tEXt", payload: Data("Comment\0".utf8) + Data(repeating: 65, count: ImageWire.chunkSize))
        let multi = try a.enqueue(big, now: now + 1200)
        try check(multi.chunks == 2, "PNG larger than 1 MiB is chunked")
        let remoteManifest = a.recordsURL.appendingPathComponent(multi.id + ".img")
        let remoteFirst = a.recordsURL.appendingPathComponent(ImageWire.chunkName(multi.id, 0))
        try rejects("pause between chunks prevents manifest publication") {
            _ = try a.poll(now: now + 1300, allowed: { !fm.fileExists(atPath: remoteFirst.path) })
        }
        try check(!fm.fileExists(atPath: remoteManifest.path) && fm.fileExists(atPath: a.outbox.appendingPathComponent(multi.id + ".img").path), "partial upload keeps encrypted pending queue and never advertises incomplete image")
        _ = try a.poll(now: now + 1400)
        let second = a.recordsURL.appendingPathComponent(ImageWire.chunkName(multi.id, 1))
        let originalSecond = try Data(contentsOf: second)
        try Data([0, 1, 2]).write(to: second)
        let invalid = try b.poll(now: now + 1500)
        try check(invalid.rejected > 0 && !invalid.records.contains { $0.manifest.id == multi.id } && b.state.seen[multi.id] == nil, "corrupt or missing chunk never reaches history and remains retryable")
        try originalSecond.write(to: second)
        let repaired = try b.poll(now: now + 1600)
        try check(repaired.records.contains { $0.manifest.id == multi.id && $0.png == big }, "repaired multichunk payload retries successfully")
        try b.acknowledge(repaired.records)
        try rejects("chunk-index AAD prevents swapping chunks") {
            _ = try ImageWire.openChunk(Data(contentsOf: remoteFirst), manifest: multi, index: 1, pair: pair)
        }
        let symlink = a.recordsURL.appendingPathComponent("symlink.chunk")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: remoteFirst)
        try rejects("symlink files are never read") { _ = try ImageWire.read(symlink, maximum: ImageWire.chunkSize + 28) }
        try fm.removeItem(at: symlink)
        let linkedDirectory = root.appendingPathComponent("linked-images")
        try fm.createSymbolicLink(at: linkedDirectory, withDestinationURL: a.recordsURL)
        try rejects("user directory symlinks remain rejected despite system alias support") {
            try ImageWire.checkDirectory(linkedDirectory)
        }
        try fm.removeItem(at: linkedDirectory)
        let pending = try a.enqueue(png, now: now + 1700)
        try rejects("privacy pause prevents all subsequent transfer steps") { _ = try a.poll(now: now + 1800, allowed: { false }) }
        try check(fm.fileExists(atPath: a.outbox.appendingPathComponent(pending.id + ".img").path), "privacy pause retains durable image queue")
        let restartA = try ImageFolderSync(folder: root, local: textA.local, pair: pair, name: "A", device: textA.state.device)
        try check(try restartA.poll(now: now + 1900).uploaded == 1, "durable queued image uploads after restart")
        _ = try b.poll(now: now + SyncWire.lifetime + 5000)
        try check(!fm.fileExists(atPath: remoteManifest.path) && !fm.fileExists(atPath: remoteFirst.path) && !fm.fileExists(atPath: second.path), "original 24-hour expiry deletes manifest and owned chunks")

        let bounded = try ImageFolderSync(folder: root, local: root.appendingPathComponent("bounded"), pair: pair, name: "bound", device: UUID().uuidString.lowercased())
        for n in 0..<ImageWire.maxRecords { _ = try bounded.enqueue(png, now: now + Int64(n)) }
        try rejects("100-record image storage rejects new additions rather than evicting pending images") { _ = try bounded.enqueue(png, now: now + 200) }
        try check((try fm.contentsOfDirectory(atPath: bounded.outbox.path)).filter { $0.hasSuffix(".img") }.count == 100, "full queue preserves all pending manifests")
        let oldOrphan = a.recordsURL.appendingPathComponent(ImageWire.chunkName(UUID().uuidString.lowercased(), 0))
        let freshOrphan = a.recordsURL.appendingPathComponent(ImageWire.chunkName(UUID().uuidString.lowercased(), 0))
        try Data([1, 2, 3]).write(to: oldOrphan); try Data([1, 2, 3]).write(to: freshOrphan)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(now - SyncWire.lifetime - 600_000) / 1000)], ofItemAtPath: oldOrphan.path)
        _ = try a.poll(now: now + 2000)
        try check(!fm.fileExists(atPath: oldOrphan.path) && fm.fileExists(atPath: freshOrphan.path), "orphan cleanup only removes provably old app-owned chunks")
    }
    static func main() throws {
        let (vector, png, pair) = try fixture()
        try wire(vector, png, pair)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ClipDay-image-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try engine(png, root: root)
        print("\(count) image protocol/queue checks passed; general clipboard untouched")
    }
}
