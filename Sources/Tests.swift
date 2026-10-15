import Foundation
import AppKit
import Carbon

@main enum Tests {
    static var passed = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
        guard value() else { throw ClipError.message("FAIL: " + label) }
        passed += 1; print("PASS: " + label)
    }
    static func run() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("build/Test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = ClipStore(directory: root.appendingPathComponent("history"))
        let t = Date()
        let first = try store.append(kind: .text, data: Data("你好，剪贴板！\n第二行".utf8), now: t)
        try check(store.clips.count == 1 && first.text.contains("第二行"), "Unicode multiline text retained")
        let loaded = ClipStore(directory: store.directory)
        try loaded.load(now: t.addingTimeInterval(1))
        try check(loaded.clips.first?.id == first.id, "history persists across restarts")
        let attributes = try fm.attributesOfItem(atPath: store.database.path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "history file restricted to owner")
        try store.prune(now: t.addingTimeInterval(86399))
        try check(store.clips.count == 1, "entry survives until 24 hour boundary")
        let downloads = root.appendingPathComponent("Downloads")
        let saved = try store.export(first.id, to: downloads, now: t.addingTimeInterval(2))
        let savedAgain = try store.export(first.id, to: downloads, now: t.addingTimeInterval(2))
        try check(saved != savedAgain && saved.pathExtension == "txt", "repeated save never overwrites a download")
        let savedData = try Data(contentsOf: saved)
        try check(savedData == first.data, "text export preserves complete original content")
        try store.prune(now: t.addingTimeInterval(86400))
        try check(store.clips.isEmpty, "entry expires at exactly 24 hours")
        let remainingPayloads = try fm.contentsOfDirectory(atPath: store.payloads.path)
        try check(remainingPayloads.isEmpty, "expired payload bytes removed from disk")
        try check(fm.fileExists(atPath: saved.path), "saved downloads survive history expiry")
        var expiredRejected = false
        do { _ = try store.export(first.id, to: downloads, now: t.addingTimeInterval(86401)) } catch { expiredRejected = true }
        try check(expiredRejected, "expired entries cannot be exported")
        _ = try store.append(kind: .text, data: Data("duplicate".utf8), now: t)
        let duplicate = try store.append(kind: .text, data: Data("duplicate".utf8), now: t.addingTimeInterval(50))
        try check(store.clips.count == 1 && store.clips[0].created == duplicate.created, "external duplicate refreshes timestamp without accumulating copies")
        let staleReload = ClipStore(directory: store.directory)
        try staleReload.load(now: t.addingTimeInterval(86500))
        try check(staleReload.clips.isEmpty, "startup removes expired disk records")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        rep.setColor(NSColor(deviceRed: 0.1, green: 0.7, blue: 0.6, alpha: 1), atX: 0, y: 0)
        let png = rep.representation(using: .png, properties: [:])!
        let image = try store.append(kind: .image, data: png, now: t)
        let imageFile = try store.export(image.id, to: downloads, now: t)
        let imageData = try Data(contentsOf: imageFile)
        try check(imageFile.pathExtension == "png" && imageData == png && NSImage(data: imageData) != nil, "image export creates valid matching PNG")
        var oversizeRejected = false
        do { _ = try store.append(kind: .text, data: Data(repeating: 65, count: ClipStore.maxItemBytes + 1), now: t) } catch { oversizeRejected = true }
        try check(oversizeRejected, "oversize entries are rejected")

        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let isolated = ClipStore(directory: root.appendingPathComponent("poll-history"))
        let model = ClipboardModel(store: isolated, pasteboard: pb, startMonitoring: false)
        model.paused = false
        pb.clearContents(); pb.setString("test only, not general pasteboard", forType: .string); model.tick()
        try check(model.clips.count == 1, "clipboard polling captures external text")
        let recorded = model.clips[0]
        let clearedVersion = pb.clearContents()
        model.tick()
        pb.setString("delivered after ownership changed", forType: .string)
        try check(pb.changeCount == clearedVersion, "delayed clipboard delivery uses unchanged version")
        model.tick()
        try check(model.clips.first?.text == "delivered after ownership changed", "content arriving after empty poll is retried and captured")
        try isolated.remove(model.clips[0].id); model.refresh()
        model.copy(recorded); model.tick()
        try check(model.clips.count == 1 && model.clips[0].id == recorded.id, "history copy is not recorded again or extended")
        var pasteRequests = 0
        var textReadyBeforePaste = false
        model.onPaste = { pasteRequests += 1; textReadyBeforePaste = pb.string(forType: .string) == recorded.text }
        model.paste(recorded)
        try check(pasteRequests == 1 && textReadyBeforePaste, "selecting history requests paste after writing clipboard")
        model.copy(recorded)
        try check(pasteRequests == 1, "explicit copy-only never requests paste")
        pb.clearContents(); pb.setString("private fixture", forType: .string); pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")); model.tick()
        try check(model.clips.count == 1, "concealed clipboard content is skipped")
        model.paused = true
        pb.clearContents(); pb.setString("paused fixture", forType: .string); model.tick()
        try check(model.clips.count == 1, "pause stops capture")
        model.paused = false
        pb.clearContents(); pb.setData(png, forType: .png); model.tick()
        try check(model.clips.count == 2 && model.clips.first?.kind == .image, "clipboard polling captures PNG")
        var imageReadyBeforePaste = false
        model.onPaste = { pasteRequests += 1; imageReadyBeforePaste = pb.data(forType: .png) == png }
        model.paste(model.clips[0])
        try check(imageReadyBeforePaste && pasteRequests == 2, "image selection also routes through automatic paste")
        pb.clearContents(); pb.setString("file:///tmp/fixture", forType: .fileURL); pb.setString("file fixture", forType: .string); model.tick()
        try check(model.clips.count == 2, "file copies are not mistaken for plain text")
        let stale = try isolated.append(kind: .text, data: Data("expired fixture".utf8), now: Date().addingTimeInterval(-90000))
        model.paste(stale)
        try check(pasteRequests == 2, "expired entry cannot trigger automatic paste")
        // Realistic A -> history B -> new C -> history B -> new D sequence,
        // including a new external copy immediately before selecting history.
        pb.clearContents(); pb.setString("sequence A", forType: .string); model.tick()
        let a = model.clips.first!
        pb.clearContents(); pb.setString("sequence B", forType: .string); model.tick()
        let b = model.clips.first!
        model.paste(a)
        try check(pb.string(forType: .string) == "sequence A", "history selection places selected A on clipboard once")
        pb.clearContents(); pb.setString("sequence C", forType: .string)
        model.tick(); model.tick()
        try check(pb.string(forType: .string) == "sequence C" && model.clips.first?.text == "sequence C", "new external C replaces history A and remains latest")
        pb.clearContents(); pb.setString("sequence D", forType: .string)
        model.paste(b)
        try check(model.clips.contains { $0.text == "sequence D" }, "history selection first captures external copy missed by timer")
        pb.clearContents(); pb.setString("sequence E", forType: .string)
        model.tick(); model.tick()
        try check(pb.string(forType: .string) == "sequence E" && model.clips.first?.text == "sequence E", "repeated history selection never pins the system clipboard")

        func gate(trusted: Bool = true, alive: Bool = true, front: pid_t? = 42, unchanged: Bool = true, released: Bool = true, elapsed: Double = 0.3) -> PasteGate {
            PasteGate.evaluate(trusted: trusted, alive: alive, front: front, target: 42, own: 99, unchanged: unchanged, released: released, elapsed: elapsed)
        }
        func cancelled(_ value: PasteGate) -> Bool { if case .cancel = value { return true }; return false }
        try check(gate() == .ready, "paste allowed only after target regains focus")
        try check(gate(front: 99) == .wait, "paste waits while clipboard window still has focus")
        try check(gate(released: false) == .wait, "paste waits for shortcut modifiers to release")
        try check(cancelled(gate(trusted: false)), "missing permission prevents event posting")
        try check(cancelled(gate(alive: false)), "exited target prevents event posting")
        try check(cancelled(gate(front: 77)), "switching to unrelated app cancels pending paste")
        try check(cancelled(gate(unchanged: false)), "changed clipboard cancels pending paste")
        try check(cancelled(gate(elapsed: 2)), "focus restoration has bounded timeout")
        guard let (down, up) = AutoPaster.pasteEvents() else { throw ClipError.message("Cannot create paste events") }
        try check(down.type == .keyDown && up.type == .keyUp && down.getIntegerValueField(.keyboardEventKeycode) == 9 && up.getIntegerValueField(.keyboardEventKeycode) == 9 && down.flags == .maskCommand && up.flags == .maskCommand, "generated input is Command-V down/up only, with no Return")

        try check(HotKeyManager.basicConflict(Shortcut(keyCode: 9, modifiers: UInt32(cmdKey), keyName: "V")) != nil, "standard paste shortcut blocked")
        try check(HotKeyManager.basicConflict(Shortcut(keyCode: 9, modifiers: 0, keyName: "V")) != nil, "unmodified character shortcut blocked")
        var keys: Unmanaged<CFArray>?
        let keyStatus = CopySymbolicHotKeys(&keys)
        try check(keyStatus == noErr && keys != nil, "system shortcut configuration readable")
        if let keys {
            let array = keys.takeRetainedValue() as NSArray
            if let key = array.compactMap({ $0 as? NSDictionary }).first(where: { ($0[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true }),
               let code = key[kHISymbolicHotKeyCode] as? NSNumber, let mods = key[kHISymbolicHotKeyModifiers] as? NSNumber {
                let candidate = Shortcut(keyCode: code.uint32Value, modifiers: mods.uint32Value, keyName: "Fixture")
                let conflict = try HotKeyManager.systemConflict(candidate)
                try check(conflict != nil, "active macOS system shortcut detected")
            }
        }
        let manager = HotKeyManager()
        let candidates: [UInt32] = [79,80,90,106,113,107]
        var original: Shortcut?
        for code in candidates {
            let s = Shortcut(keyCode: code, modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey), keyName: "Test")
            if (try? manager.set(s)) != nil { original = s; break }
        }
        guard let original else { throw ClipError.message("Could not acquire a test shortcut") }
        var blocker: EventHotKeyRef?
        var occupied: Shortcut?
        for code in candidates where code != original.keyCode {
            let s = Shortcut(keyCode: code, modifiers: original.modifiers, keyName: "Occupied")
            if RegisterEventHotKey(code, s.modifiers, EventHotKeyID(signature: 0x54455354, id: 2), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &blocker) == noErr { occupied = s; break }
        }
        defer { if let blocker { UnregisterEventHotKey(blocker) } }
        guard let occupied else { throw ClipError.message("Could not acquire conflict test shortcut") }
        var rejected = false
        do { try manager.set(occupied) } catch { rejected = true }
        try check(rejected && manager.current == original, "registered hotkey conflict rejected while previous shortcut stays active")
        print("All \(passed) checks passed. General clipboard, actual downloads and user history were not modified.")
    }
    static func main() {
        do { try run() } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
    }
}
