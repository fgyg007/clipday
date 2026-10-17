#if CLOUD
import Foundation
import Darwin

struct PairingEvent: Decodable {
    let type: String
    let code: String?
    let expires: Int64?
    let message: String?
    let pair: SyncPair?
}

// The bundled native helper owns the PAKE state. Secrets travel only over private pipes.
final class PairingProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var onExit: (() -> Void)?
    private var ended = false
    init(mode: String, folder: URL, pair: SyncPair? = nil, code: String? = nil, event: @escaping (PairingEvent) -> Void) throws {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "ClipDayPair") else { throw ClipError.message("配对组件缺失，请重新安装云版。") }
        process.executableURL = executable
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        // The helper may finish between its final event and a cancellation request.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw ClipError.message("无法启动配对连接。") }
        struct Command: Encodable { let mode: String; let folder: String; let pair: SyncPair?; let code: String? }
        let data = try JSONEncoder().encode(Command(mode: mode, folder: folder.path, pair: pair, code: code)) + Data([10])
        try process.run()
        input.fileHandleForWriting.write(data)
        DispatchQueue.global(qos: .utility).async { [self] in
            var buffer = Data()
            var terminal = false
            while true {
                // Fixed-length reads can wait for a full buffer while the helper is still running.
                let bytes = output.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                buffer.append(bytes)
                if buffer.count > 32768 { process.terminate(); break }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                    if let value = try? JSONDecoder().decode(PairingEvent.self, from: line) {
                        if ["success", "joined", "expired", "error", "cancelled"].contains(value.type) { terminal = true }
                        DispatchQueue.main.async { event(value) }
                    }
                }
            }
            process.waitUntilExit()
            if !terminal {
                DispatchQueue.main.async { event(PairingEvent(type: "error", code: nil, expires: nil, message: "配对组件已退出，请重新生成配对码。", pair: nil)) }
            }
            DispatchQueue.main.async { self.ended = true; self.onExit?(); self.onExit = nil }
        }
    }
    func cancel(then completion: (() -> Void)? = nil) {
        if ended { completion?(); return }
        onExit = completion
        try? input.fileHandleForWriting.write(contentsOf: Data([10]))
        try? input.fileHandleForWriting.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if let self, !self.ended, self.process.isRunning { self.process.terminate() }
        }
    }
}
#endif
