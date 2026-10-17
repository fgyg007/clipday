import Foundation

@main enum AndroidInteropTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let pair = SyncPair(space: "c1416f42-de6e-43e0-97f0-122e9016a926", key: Data(0..<32).base64EncodedString())
        if CommandLine.arguments[1] == "write" {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FolderSync.setup(folder: root, pair: pair, create: true)
        }
        let sync = try FolderSync(folder: root, local: root.appendingPathComponent("swift-local"), pair: pair, name: "Mac interop")
        if CommandLine.arguments[1] == "write" {
            _ = try sync.enqueue("Mac → Android 你好 🍎\nline two"); _ = try sync.poll()
            print("PASS: Mac fixture published")
        } else {
            let batch = try sync.poll()
            guard batch.records.contains(where: { $0.text == "Android → desktop 你好 📱\r\nline two" || $0.text == "Android share fixture 你好 📱" }) else { throw SyncFailure.invalid }
            print("PASS: Android record decrypted by Mac CryptoKit")
        }
    }
}
