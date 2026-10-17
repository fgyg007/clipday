import Foundation

@main enum SyncTests {
    static var count = 0
    static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw SyncFailure.invalid }
        count += 1; print("PASS: \(name)")
    }
    static func rejects(_ name: String, _ f: () throws -> Void) throws {
        var failed = false; do { try f() } catch { failed = true }; try check(failed, name)
    }
    static func run(root: URL) throws {
        let fm = FileManager.default, now: Int64 = 1_800_000_000_000
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let pair = SyncPair.create(); try FolderSync.setup(folder: root, pair: pair, create: true)
        let a = try FolderSync(folder: root, local: root.appendingPathComponent("a"), pair: pair, name: "Mac 测试")
        let b = try FolderSync(folder: root, local: root.appendingPathComponent("b"), pair: pair, name: "Windows 测试")
        try check(try SyncPair.parse(pair.code).key == pair.key, "pair code round trip")
        _ = try a.poll(now: now); _ = try b.poll(now: now)
        let first = try a.enqueue("你好 Windows 👋\n多行文字", now: now + 100)
        let uploaded = try a.poll(now: now + 200)
        try check(uploaded.uploaded == 1 && uploaded.pending == 0, "upload count reports NAS write completion, not receiver acknowledgement")
        let incoming = try b.poll(now: now + 300)
        try check(incoming.automatic?.text == first.text && incoming.records.count == 1, "live copy auto-applies with Unicode intact")
        try b.acknowledge(incoming.records)
        try check(try b.poll(now: now + 400).records.isEmpty, "poll deduplicates encrypted files")
        let reply = try b.enqueue("reply", now: now + 500)
        _ = try b.poll(now: now + 600)
        try check(try a.poll(now: now + 700).automatic?.id == reply.id, "causal response auto-applies in reverse direction")
        _ = try a.enqueue("A simultaneous", now: now + 800)
        _ = try b.enqueue("B simultaneous", now: now + 800)
        let ap = try a.poll(now: now + 900), bp = try b.poll(now: now + 900), ap2 = try a.poll(now: now + 1000)
        try check(ap.automatic == nil && bp.automatic == nil && ap2.automatic == nil, "concurrent copies cannot overwrite either clipboard")
        b.suspend()
        _ = try a.enqueue("offline backlog", now: now + 1100); _ = try a.poll(now: now + 1200)
        let backlog = try b.poll(now: now + 1300)
        try check(backlog.records.contains { $0.text == "offline backlog" } && backlog.automatic == nil, "reconnect imports history without replacing clipboard")
        let restart = try FolderSync(folder: root, local: b.local, pair: pair, name: "Windows")
        let recovered = try restart.poll(now: now + 1400)
        try check(!recovered.records.contains { $0.id == first.id }, "acknowledged records do not resurrect after restart")
        try check(try restart.history(now: now + 1400).contains { $0.text == "offline backlog" }, "received encrypted inbox survives restart")
        let partial = try a.enqueue("partial delivery", now: now + 1500)
        let bytes = try SyncWire.seal(partial, pair: pair)
        let partialURL = a.recordsURL.appendingPathComponent(partial.id + ".clip")
        try bytes.prefix(15).write(to: partialURL)
        try check(try b.poll(now: now + 1600).rejected > 0, "partial files rejected")
        try bytes.write(to: partialURL)
        try check(try b.poll(now: now + 1700).records.contains { $0.id == partial.id }, "repaired files are retried rather than lost")
        var corrupted = bytes; corrupted[15] ^= 1
        try rejects("tampered ciphertext rejected") { _ = try SyncWire.open(corrupted, pair: pair) }
        try rejects("wrong key rejected") { _ = try SyncWire.open(bytes, pair: SyncPair(space: pair.space, key: SyncPair.create().key)) }
        try rejects("wrong space rejected") { _ = try SyncWire.open(bytes, pair: SyncPair(space: UUID().uuidString.lowercased(), key: pair.key)) }
        let future = SyncRecord(id: UUID().uuidString.lowercased(), space: pair.space, device: a.state.device, name: "skew", seq: 999, created: now + 600_000, expires: now + 600_000 + SyncWire.lifetime, observed: [:], text: "future")
        try SyncWire.seal(future, pair: pair).write(to: a.recordsURL.appendingPathComponent(future.id + ".clip"))
        try check(try b.poll(now: now + 1800).rejected > 0, "large clock skew never writes clipboard")
        let rootOffline = root.appendingPathComponent("ClipDaySync")
        let parked = root.appendingPathComponent("parked")
        try fm.moveItem(at: rootOffline, to: parked)
        try rejects("missing NAS raises offline state") { _ = try b.poll(now: now + 1900) }
        _ = try b.enqueue("queued while offline", now: now + 2000)
        try check(!fm.fileExists(atPath: rootOffline.path), "offline queue never recreates a missing NAS mount")
        try fm.moveItem(at: parked, to: rootOffline)
        _ = try b.poll(now: now + 2100)
        try check(try a.poll(now: now + 2200).records.contains { $0.text == "queued while offline" }, "outbox sends after reconnect")
        _ = try b.poll(now: now + SyncWire.lifetime + 700_000)
        try check(try b.history(now: now + SyncWire.lifetime + 700_000).isEmpty, "expired received payloads removed locally")
        try check(!fm.fileExists(atPath: a.recordsURL.appendingPathComponent(first.id + ".clip").path), "expired shared payload removed")
        try bytes.write(to: a.recordsURL.appendingPathComponent(partial.id + ".clip"))
        try check(try b.poll(now: now + SyncWire.lifetime + 800_000).records.isEmpty, "expired file restored by NAS cannot reimport")
        try rejects("oversized text refused before encryption") { _ = try a.enqueue(String(repeating: "a", count: SyncWire.maxText + 1), now: now) }
        let gate = SyncOperationGate()
        try check(gate.ticket() == nil, "privacy operation gate begins closed")
        gate.update(active: true)
        let oldTicket = gate.ticket()!
        gate.update(active: false)
        try check(!gate.permits(oldTicket) && gate.ticket() == nil, "privacy pause invalidates already queued work")
        gate.update(active: true)
        try check(!gate.permits(oldTicket) && gate.permits(gate.ticket()!), "resume cannot resurrect pre-pause callbacks")

        let isolatedRoot = root.appendingPathComponent("privacy-fixture")
        try fm.createDirectory(at: isolatedRoot, withIntermediateDirectories: true)
        let isolatedPair = SyncPair.create()
        try rejects("paused setup cannot create a remote space") {
            try FolderSync.setup(folder: isolatedRoot, pair: isolatedPair, create: true, allowed: { false })
        }
        try check(!fm.fileExists(atPath: isolatedRoot.appendingPathComponent("ClipDaySync").path), "cancelled setup leaves remote folder untouched")
        try FolderSync.setup(folder: isolatedRoot, pair: isolatedPair, create: true)
        let pausedSender = try FolderSync(folder: isolatedRoot, local: isolatedRoot.appendingPathComponent("sender"), pair: isolatedPair, name: "privacy sender")
        let stableID = UUID().uuidString.lowercased()
        let pausedRecord = try pausedSender.enqueue("queued before pause", now: now, id: stableID)
        let enqueueRetry = try pausedSender.enqueue("queued before pause", now: now, id: stableID)
        try check(enqueueRetry.id == pausedRecord.id && enqueueRetry.seq == pausedRecord.seq && pausedSender.state.seq == pausedRecord.seq, "retrying the same queue write preserves ID, timestamp, and sequence")
        try rejects("same retry ID cannot replace different text") { _ = try pausedSender.enqueue("different", now: now, id: stableID) }
        let target = pausedSender.recordsURL.appendingPathComponent(pausedRecord.id + ".clip")
        let queued = pausedSender.outbox.appendingPathComponent(pausedRecord.id + ".clip")
        try rejects("paused poll cannot upload queued content") { _ = try pausedSender.poll(now: now, allowed: { false }) }
        try check(fm.fileExists(atPath: queued.path) && !fm.fileExists(atPath: target.path), "privacy pause retains outbox without transmitting")
        try rejects("pause during an upload stops subsequent work") {
            _ = try pausedSender.poll(now: now + 100, allowed: { !fm.fileExists(atPath: target.path) })
        }
        try check(fm.fileExists(atPath: target.path) && fm.fileExists(atPath: queued.path), "already-started upload may finish but cancelled batch retains retry state")
        let resumed = try pausedSender.poll(now: now + 200)
        try check(resumed.uploaded == 1 && resumed.pending == 0, "resume safely retries the same encrypted record without duplication")
        try Data([0, 1, 2]).write(to: pausedSender.outbox.appendingPathComponent(UUID().uuidString.lowercased() + ".clip"))
        try Data([0, 1, 2]).write(to: pausedSender.inbox.appendingPathComponent(UUID().uuidString.lowercased() + ".clip"))
        _ = try pausedSender.enqueue("healthy after damaged queue file", now: now + 300)
        let isolatedBatch = try pausedSender.poll(now: now + 400)
        try check(isolatedBatch.uploaded == 1 && isolatedBatch.rejected == 2, "damaged inbox or outbox file does not stop healthy queued upload")

        let blockedQueue = isolatedRoot.appendingPathComponent("blocked-queue")
        let retrySender = try FolderSync(folder: isolatedRoot, local: blockedQueue, pair: isolatedPair, name: "retry sender")
        let parkedOutbox = blockedQueue.appendingPathComponent("parked-outbox")
        try fm.moveItem(at: retrySender.outbox, to: parkedOutbox)
        try Data("temporary write failure".utf8).write(to: retrySender.outbox)
        let retryID = UUID().uuidString.lowercased()
        try rejects("failed outbox write remains retryable") { _ = try retrySender.enqueue("retry after disk repair", now: now, id: retryID) }
        try fm.removeItem(at: retrySender.outbox); try fm.moveItem(at: parkedOutbox, to: retrySender.outbox)
        let retriedQueue = try retrySender.enqueue("retry after disk repair", now: now, id: retryID)
        try check(retriedQueue.id == retryID && retriedQueue.created == now && retriedQueue.expires == now + SyncWire.lifetime, "outbox retry after repaired storage retains original record identity and expiry")

        let absent = isolatedRoot.appendingPathComponent("not-mounted")
        let absentCheck = NASPathDiagnostics.inspect(absent)
        try check(!absentCheck.reachable && !fm.fileExists(atPath: absent.path), "connection diagnostic never recreates a missing mount")
        let sentinel = isolatedRoot.appendingPathComponent("keep.txt")
        try Data("existing data".utf8).write(to: sentinel)
        let diagnostic = NASPathDiagnostics.inspect(isolatedRoot)
        try check(diagnostic.passed && diagnostic.existingSpaces == 1, "connection diagnostic verifies read and write and identifies existing space")
        try check(try Data(contentsOf: sentinel) == Data("existing data".utf8), "connection diagnostic leaves existing data unchanged")
        try check(!(try fm.contentsOfDirectory(atPath: isolatedRoot.path)).contains { $0.hasPrefix(".clipday-check-") }, "successful diagnostic removes only its own test file")
        let fileDiagnostic = NASPathDiagnostics.inspect(sentinel)
        try check(!fileDiagnostic.reachable && !fileDiagnostic.passed, "connection diagnostic rejects a file mistaken for a folder")
        let data = try SyncWire.seal(first, pair: pair)
        try check(data.range(of: Data(first.text.utf8)) == nil, "NAS payload contains no plaintext")
    }
    static let interopPair = SyncPair(space: "c1416f42-de6e-43e0-97f0-122e9016a926", key: Data(0..<32).base64EncodedString())
    static func main() throws {
        if CommandLine.arguments.count == 3 {
            let root = URL(fileURLWithPath: CommandLine.arguments[2]); let pair = interopPair
            if CommandLine.arguments[1] == "write" {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try FolderSync.setup(folder: root, pair: pair, create: true)
                let a = try FolderSync(folder: root, local: root.appendingPathComponent("swift"), pair: pair, name: "Mac interop")
                _ = try a.enqueue("Swift → C# 你好 👋\nline two"); _ = try a.poll()
                print("Swift interop fixture ready")
            } else {
                let a = try FolderSync(folder: root, local: root.appendingPathComponent("swift"), pair: pair, name: "Mac interop")
                let b = try a.poll()
                try check(b.records.contains { $0.text == "C# → Swift 你好 🪟\r\nline two" }, "C# AES-GCM records decrypt in Swift")
            }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipDaySync-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try run(root: root); print("\(count) sync checks passed")
    }
}
