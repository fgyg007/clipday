import Foundation

// Isolated synthetic local replicas. Does not use a real cloud account or clipboard.
@main enum DriveFolderTests {
    static func check(_ value: Bool, _ label: String) throws { if !value { throw SyncFailure.invalid }; print("PASS: \(label)") }
    static func rejects(_ label: String, _ body: () throws -> Void) throws { var failed = false; do { try body() } catch { failed = true }; try check(failed, label) }
    static func main() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("clipday-drive-synthetic-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let aFolder = root.appendingPathComponent("replica-a"), bFolder = root.appendingPathComponent("replica-b")
        for dir in [aFolder, bFolder] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let pair = SyncPair.create(), now: Int64 = 1_800_000_000_000
        try check(SyncPair.parseDrive(pair.driveCode).key == pair.key, "cloud bundle round trip")
        try rejects("cloud rejects NAS bundle") { _ = try SyncPair.parseDrive(pair.code) }
        try rejects("NAS rejects cloud bundle") { _ = try SyncPair.parse(pair.driveCode) }
        try FolderSync.setup(folder: aFolder, pair: pair, create: true, cloudDrive: true)
        try rejects("join waits without creating missing tree") { try FolderSync.setup(folder: bFolder, pair: pair, create: false, cloudDrive: true) }
        try check(!fm.fileExists(atPath: bFolder.appendingPathComponent("ClipDayDrive").path), "missing replica not synthesized")
        let ar = FolderSync.spaceRoot(folder: aFolder, pair: pair, cloudDrive: true), br = FolderSync.spaceRoot(folder: bFolder, pair: pair, cloudDrive: true)
        try fm.createDirectory(at: br.appendingPathComponent("records"), withIntermediateDirectories: true)
        try fm.copyItem(at: ar.appendingPathComponent("space.json"), to: br.appendingPathComponent("space.json"))
        try rejects("marker without key proof rejected") { try FolderSync.setup(folder: bFolder, pair: pair, create: false, cloudDrive: true) }
        try fm.copyItem(at: ar.appendingPathComponent("space.check"), to: br.appendingPathComponent("space.check"))
        try FolderSync.setup(folder: bFolder, pair: pair, create: false, cloudDrive: true)
        let a = try FolderSync(folder: aFolder, local: root.appendingPathComponent("local-a"), pair: pair, name: "A", cloudDrive: true)
        let b = try FolderSync(folder: bFolder, local: root.appendingPathComponent("local-b"), pair: pair, name: "B", cloudDrive: true)
        _ = try a.poll(now: now); _ = try b.poll(now: now)
        let sent = try a.enqueue("encrypted delayed text", now: now + 100); _ = try a.poll(now: now + 200)
        for elapsed in stride(from: Int64(2000), through: 30000, by: 2000) { try check(b.poll(now: now + elapsed).records.isEmpty, "not received before cloud replication") }
        let data = try Data(contentsOf: a.recordsURL.appendingPathComponent(sent.id + ".clip")), target = b.recordsURL.appendingPathComponent(sent.id + ".clip")
        try data.prefix(15).write(to: target)
        try check(b.poll(now: now + 31000).rejected > 0, "partial file not acknowledged")
        try data.write(to: target)
        let batch = try b.poll(now: now + 32000)
        try check(batch.automatic?.id == sent.id, "delayed complete record eligible without new local activity")
        try b.acknowledge(batch.records)
        try check(b.poll(now: now + 33000).records.isEmpty, "duplicate does not echo")
        try check(!fm.fileExists(atPath: aFolder.appendingPathComponent("ClipDaySync").path), "NAS namespace unchanged")
        print("Cloud-folder synthetic text tests passed")
    }
}
