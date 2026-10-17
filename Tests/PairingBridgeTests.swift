import Foundation

@main enum PairingBridgeTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipDayPair-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pair = SyncPair.create(); try FolderSync.setup(folder: root, pair: pair, create: true)
        var offer: PairingEvent?, result: PairingEvent?, completed = false
        let host = try PairingProcess(mode: "host", folder: root, pair: pair) { event in
            if event.type == "offer" { offer = event }
            if event.type == "success" { completed = true }
        }
        func until(_ predicate: () -> Bool) throws {
            let end = Date().addingTimeInterval(12)
            while !predicate() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            guard predicate() else { throw ClipError.message("pairing bridge timeout") }
        }
        try until { offer != nil }
        guard let code = offer?.code, code.count == 6 else { throw SyncFailure.invalid }
        print("PASS: Swift bridge receives live six-digit offer before helper exits")
        let client = try PairingProcess(mode: "join", folder: root, code: code) { event in if event.type == "joined" || event.type == "error" { result = event } }
        try until { result != nil }
        guard result?.pair?.key == pair.key, result?.pair?.space == pair.space else { throw SyncFailure.invalid }
        print("PASS: native helper pair exchange decodes into Swift without clipboard use")
        try until { completed }
        print("PASS: native helper reports consumption to Swift host")
        var stopped = false
        client.cancel { stopped = true }; try until { stopped }
        stopped = false; host.cancel { stopped = true }; try until { stopped }
        let second = try PairingProcess(mode: "host", folder: root, pair: pair) { event in if event.type == "offer" { offer = event } }
        offer = nil; try until { offer != nil }
        stopped = false; second.cancel { stopped = true }; try until { stopped }
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("ClipDaySync/Pairing-v2/active.json").path) else { throw SyncFailure.invalid }
        print("PASS: cancelling Swift pairing helper clears NAS invitation")
    }
}
