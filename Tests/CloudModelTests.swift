import AppKit
import Foundation
import CryptoKit

@main enum CloudModelTests {
    static func main() throws {
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(["selectedSyncMode": "nas"], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipDayCloud-model-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pb = NSPasteboard.withUniqueName(); defer { pb.releaseGlobally() }
        let store = ClipStore(directory: root)
        let model = ClipboardModel(store: store, pasteboard: pb, startMonitoring: false); model.paused = false
        var n = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw ClipError.message("FAIL: " + label) }; n += 1; print("PASS: " + label)
        }
        func record(_ text: String, age: Int64 = 0) -> SyncRecord {
            let t = SyncWire.ms() - age
            return SyncRecord(id: UUID().uuidString.lowercased(), space: UUID().uuidString.lowercased(), device: UUID().uuidString.lowercased(), name: "Windows fixture", seq: 1, created: t, expires: t + SyncWire.lifetime, observed: [:], text: text)
        }
        let first = record("from Windows")
        model.receive([first], automatic: first, expectedChange: pb.changeCount)
        try check(pb.string(forType: .string) == first.text && model.clips.first?.source == first.name, "remote text reaches clipboard and keeps source")
        model.tick()
        try check(model.clips.count == 1 && model.clips.first?.id == UUID(uuidString: first.id), "received clipboard is not recaptured as local")
        let expected = pb.changeCount
        pb.clearContents(); pb.setString("new local copy", forType: .string)
        let delayed = record("delayed response")
        model.receive([delayed], automatic: delayed, expectedChange: expected)
        try check(pb.string(forType: .string) == "new local copy", "in-flight NAS response cannot replace unprocessed local copy")
        model.tick()
        let currentID = model.clips.first?.id
        let older = record("new local copy", age: 10_000)
        model.receive([older], automatic: nil, expectedChange: -1)
        try check(model.clips.first?.id == currentID, "older remote duplicate cannot shorten or refresh a local entry")
        let expired = record("expired", age: SyncWire.lifetime + 1)
        model.receive([expired], automatic: expired, expectedChange: pb.changeCount)
        try check(pb.string(forType: .string) == "new local copy" && !model.clips.contains { $0.text == "expired" }, "late callback cannot paste or import expired text")
        let aged = record("backlog", age: 60_000)
        model.receive([aged], automatic: aged, expectedChange: pb.changeCount)
        try check(pb.string(forType: .string) == "new local copy" && model.clips.contains { $0.text == "backlog" }, "stale callback only adds history")
        let syncSetting = model.cloud.nas!.enabled
        let storedBeforePause = model.clips.count
        model.paused = true
        try check(model.cloud.nas!.privacyPaused && model.cloud.nas!.enabled == syncSetting, "privacy pause gates cloud without changing separate sync preference")
        model.cloud.send("must not queue during privacy pause")
        let paused = record("while paused")
        try check(!model.receive([paused], automatic: paused, expectedChange: pb.changeCount), "paused model leaves incoming records unacknowledged")
        try check(pb.string(forType: .string) == "new local copy", "pause protects system clipboard")
        try check(model.clips.count == storedBeforePause, "privacy pause does not clear existing history")
        pb.clearContents(); pb.setString("copied during privacy pause", forType: .string)
        model.paused = false; model.tick()
        try check(!model.cloud.nas!.privacyPaused && model.cloud.nas!.enabled == syncSetting && !model.clips.contains { $0.text == "copied during privacy pause" }, "privacy resume retains sync setting and skips paused clipboard version")
        model.cloud.nas!.ready = false
        pb.clearContents(); pb.setString("local only status fixture", forType: .string); model.tick()
        try check(model.cloud.nas!.deliveryStatus.contains("已保存本机") && model.cloud.nas!.deliveryStatus.contains("未加入待发队列"), "unconnected capture is not reported as uploaded or received")
        let oldCreated = model.clips.first(where: { $0.id == UUID(uuidString: first.id) })!.created
        let restored = ClipStore(directory: root); try restored.load()
        try check(restored.clips.first(where: { $0.id == UUID(uuidString: first.id) })?.source == first.name, "source survives local history reload")
        try check(abs(oldCreated.timeIntervalSince1970 * 1000 - Double(first.created)) < 1, "remote expiry uses original creation time")
        // An isolated pasteboard covers actual automatic image writes, no loops,
        // shared text/image ordering, privacy pause, and durable capture intents.
        let imagePB = NSPasteboard.withUniqueName(); defer { imagePB.releaseGlobally() }
        let imageRoot = root.appendingPathComponent("image-history")
        let imageStore = ClipStore(directory: imageRoot)
        let imageModel = ClipboardModel(store: imageStore, pasteboard: imagePB, startMonitoring: false)
        imageModel.paused = false
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/image-v1.json"))) as! [String: Any]
        let png = Data(base64Encoded: fixture["pngBase64"] as! String)!
        func imageRecord(created: Int64, id: String = UUID().uuidString.lowercased()) -> ReceivedImage {
            let manifest = ImageManifest(id: id, space: UUID().uuidString.lowercased(), device: UUID().uuidString.lowercased(), name: "image fixture", seq: 1,
                                         created: created, expires: created + SyncWire.lifetime, observed: [:], width: 2, height: 2,
                                         byteCount: png.count, chunks: 1, sha256: ImageWire.digest(png))
            return ReceivedImage(manifest: manifest, png: png)
        }
        let imageTime = SyncWire.ms() - 2
        let image = imageRecord(created: imageTime)
        try check(imageModel.receiveImages([image], automatic: image, expectedChange: imagePB.changeCount), "verified fresh image accepted")
        try check(imagePB.data(forType: .png) == png && imageModel.clips.first?.source == "image fixture", "automatic image arrives on clipboard with source history")
        imageModel.tick()
        try check(imageModel.clips.count == 1 && imageModel.clips.first?.id == UUID(uuidString: image.manifest.id), "received image is not recaptured or uploaded again")
        let olderText = SyncRecord(id: UUID().uuidString.lowercased(), space: image.manifest.space, device: image.manifest.device, name: "older text", seq: 1,
                                   created: imageTime - 1, expires: imageTime - 1 + SyncWire.lifetime, observed: [:], text: "older than image")
        imageModel.receive([olderText], automatic: olderText, expectedChange: imagePB.changeCount)
        try check(imagePB.data(forType: .png) == png, "older text cannot overwrite a newer automatically applied image")
        let newerText = record("newer than image")
        imageModel.receive([newerText], automatic: newerText, expectedChange: imagePB.changeCount)
        try check(imagePB.string(forType: .string) == newerText.text, "newer remote text can apply after an image")
        let oldImage = imageRecord(created: imageTime - 1)
        imageModel.receiveImages([oldImage], automatic: oldImage, expectedChange: imagePB.changeCount)
        try check(imagePB.string(forType: .string) == newerText.text, "older image cannot overwrite newer remote text")
        let imageExpected = imagePB.changeCount
        imagePB.clearContents(); imagePB.setString("uncaptured local text", forType: .string)
        let lateImage = imageRecord(created: SyncWire.ms())
        imageModel.receiveImages([lateImage], automatic: lateImage, expectedChange: imageExpected)
        try check(imagePB.string(forType: .string) == "uncaptured local text", "late image cannot replace unprocessed newer local text")
        imageModel.paused = true
        try check(!imageModel.receiveImages([lateImage], automatic: lateImage, expectedChange: imagePB.changeCount), "privacy pause leaves images retryable and unapplied")
        imageModel.paused = false
        let intentSpace = UUID().uuidString.lowercased(), intentID = UUID(), intentDate = Date()
        try imageStore.append(kind: .image, data: png, id: intentID, created: intentDate, imageSyncSpace: intentSpace)
        var refusedRemove = false, refusedClear = false
        do { try imageStore.remove(intentID) } catch { refusedRemove = true }
        do { try imageStore.clear() } catch { refusedClear = true }
        try check(refusedRemove && refusedClear && imageStore.clips.contains { $0.id == intentID }, "history remove/clear cannot silently cancel a pending image capture intent")
        let reloadedImages = ClipStore(directory: imageRoot); try reloadedImages.load()
        try check(reloadedImages.clips.contains { $0.id == intentID && $0.imageSyncSpace == intentSpace && $0.created == intentDate }, "queue intent survives restart with original ID, space, and creation time")
        try reloadedImages.markImageQueued(intentID.uuidString.lowercased(), space: intentSpace)
        let confirmedImages = ClipStore(directory: imageRoot); try confirmedImages.load()
        try check(confirmedImages.clips.contains { $0.id == intentID && $0.imageSyncSpace == nil }, "encrypted enqueue confirmation clears durable intent")
        func pngNumber(_ value: UInt32) -> Data {
            Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
        let profilePayload = Data("Profile\0\0".utf8) + Data([120, 156, 0])
        let profileContent = Data("iCCP".utf8) + profilePayload
        var profileCRC: UInt32 = 0xffffffff
        for byte in profileContent {
            profileCRC ^= UInt32(byte)
            for _ in 0..<8 { profileCRC = profileCRC & 1 == 1 ? 0xedb88320 ^ (profileCRC >> 1) : profileCRC >> 1 }
        }
        let profileChunk = pngNumber(UInt32(profilePayload.count)) + profileContent + pngNumber(profileCRC ^ 0xffffffff)
        let legacyPNG = Data(png.dropLast(12)) + profileChunk + Data(png.suffix(12))
        let legacyRoot = root.appendingPathComponent("legacy-image-history"), legacyID = UUID()
        let legacyStore = ClipStore(directory: legacyRoot)
        try FileManager.default.createDirectory(at: legacyStore.payloads, withIntermediateDirectories: true)
        let legacyFile = legacyStore.payloads.appendingPathComponent(legacyID.uuidString + ".bin")
        try legacyPNG.write(to: legacyFile)
        let legacyDigest = SHA256.hash(data: legacyPNG).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: [["id": legacyID.uuidString, "created": Date().timeIntervalSinceReferenceDate,
                                                     "kind": "image", "digest": legacyDigest]]).write(to: legacyStore.database)
        try legacyStore.load()
        try check(legacyStore.clips.first?.data == png && legacyStore.clips.first?.digest == legacyDigest && (try Data(contentsOf: legacyFile)) == legacyPNG,
                  "legacy ICC PNG history stays readable with original on-disk blob/digest and sanitized in-memory preview")
        let legacyPB = NSPasteboard.withUniqueName(); defer { legacyPB.releaseGlobally() }
        let legacyModel = ClipboardModel(store: legacyStore, pasteboard: legacyPB, startMonitoring: false); legacyModel.paused = false
        try check(legacyModel.copy(legacyModel.clips[0]) && legacyPB.data(forType: .png) == png,
                  "legacy PNG can still be copied without passing unsafe metadata to clipboard decoders")
        let invalidImage = ReceivedImage(manifest: image.manifest, png: Data([0, 1, 2]))
        try check(!imageModel.receiveImages([invalidImage], automatic: invalidImage, expectedChange: imagePB.changeCount), "unverified image cannot enter history or clipboard")
        imageModel.cloud.nas!.ready = false
        imagePB.clearContents(); imagePB.setData(png, forType: .png); imageModel.tick()
        try check(imageModel.cloud.nas!.deliveryStatus.contains("图片已保存本机") && imageModel.clips.contains { $0.kind == .image }, "normal clipboard polling captures image and invokes automatic sync path")
        print("\(n) cloud model checks passed; general clipboard untouched")
    }
}
