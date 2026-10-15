// Explicitly authorized, isolated native integration test. Uses only its own
// temporary text window plus the real ClipDay app. No user documents are edited.
import AppKit
import ApplicationServices
import CryptoKit

struct TestFailure: Error, LocalizedError {
    let label: String
    var errorDescription: String? { label }
}
final class Journey {
    let fm = FileManager.default
    let clipboard = NSPasteboard.general
    let testID = "CLIPDAY_E2E_" + UUID().uuidString
    let root: URL
    let appURL: URL = {
        let userApp = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/轻贴.app")
        return FileManager.default.fileExists(atPath: userApp.path) ? userApp : URL(fileURLWithPath: "/Applications/轻贴.app")
    }()
    let historyRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/io.jlmac.ClipDay")
    var fixture: Process?
    var seq = 0
    var original: [[NSPasteboard.PasteboardType: Data]] = []
    var markers = Set<String>()
    var tests = 0
    var touchedClipboard = false
    var pasteFailures: [String] = []
    init() throws {
        root = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("build/E2E-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.025))) }
    }
    func wait(_ label: String, seconds: Double = 5, _ condition: () -> Bool) throws {
        let end = Date().addingTimeInterval(seconds)
        repeat { if condition() { return }; pump(0.04) } while Date() < end
        let front = NSWorkspace.shared.frontmostApplication
        print("DIAGNOSTIC: front=\(front?.bundleIdentifier ?? "none"), fixtureFocused=\(front?.processIdentifier == fixture?.processIdentifier), modifiers=\(NSEvent.modifierFlags.rawValue)")
        let request = Process(); request.executableURL = appURL.appendingPathComponent("Contents/MacOS/ClipDay"); request.arguments = ["--request-status"]
        try? request.run(); request.waitUntilExit(); pump(0.2)
        if let data = try? Data(contentsOf: historyRoot.appendingPathComponent("runtime-status.json")), let status = String(data: data, encoding: .utf8) { print("APP STATUS: " + status) }
        throw TestFailure(label: label)
    }
    func pass(_ label: String) { tests += 1; print("PASS: " + label) }
    func state() -> [String: Any] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    func command(_ operation: String, text: String = "") throws {
        seq += 1
        let data = try JSONSerialization.data(withJSONObject: ["seq": seq, "operation": operation, "text": text])
        try data.write(to: root.appendingPathComponent("command.json"), options: .atomic)
        try wait("Fixture command timed out") { (self.state()["seq"] as? Int) == self.seq }
        if operation != "quit" { try wait("Fixture did not regain focus") { NSWorkspace.shared.frontmostApplication?.processIdentifier == self.fixture?.processIdentifier } }
    }
    func key(_ code: CGKeyCode, flags: CGEventFlags, global: Bool = false) throws {
        guard let source = CGEventSource(stateID: .privateState), let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false), let fixture else { throw TestFailure(label: "Could not construct test input") }
        down.flags = flags; up.flags = []
        if global { down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap) }
        else { down.postToPid(fixture.processIdentifier); up.postToPid(fixture.processIdentifier) }
    }
    func captureOriginal() throws {
        var size = 0
        for item in clipboard.pasteboardItems ?? [] {
            var saved: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { throw TestFailure(label: "Cannot safely preserve original clipboard; no test input sent") }
                size += data.count
                guard size < 100 * 1024 * 1024 else { throw TestFailure(label: "Original clipboard too large to snapshot; no test input sent") }
                saved[type] = data
            }
            original.append(saved)
        }
    }
    func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    func records() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: historyRoot.appendingPathComponent("history.json")), let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows
    }
    func isRecorded(_ marker: String) -> Bool { records().contains { $0["digest"] as? String == digest(marker) } }
    func checkHidden() throws {
        // Allow WindowServer's orderOut fade to finish.
        pump(0.5)
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "io.jlmac.ClipDay").first else { throw TestFailure(label: "ClipDay exited in background") }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier) && ($0[kCGWindowLayer as String] as? Int) == 0 }
        let visible = owned.contains { ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }
        guard !visible, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else {
            print("HIDDEN DIAGNOSTIC: front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"), windows=\(owned.map { ["bounds": $0[kCGWindowBounds as String] ?? "none", "alpha": $0[kCGWindowAlpha as String] ?? "none"] })")
            throw TestFailure(label: "Background test requires ClipDay window to stay hidden")
        }
        pass("ClipDay remains hidden and inactive; verified without activating it")
    }
    func copySource(_ suffix: String) throws -> String {
        let marker = testID + "_" + suffix; markers.insert(marker)
        try command("source", text: marker)
        touchedClipboard = true
        try key(8, flags: .maskCommand)
        try wait("Command-C did not update the actual system clipboard for " + suffix) { self.clipboard.string(forType: .string) == marker }
        pass("Real Command-C updated system clipboard: " + suffix)
        try wait("Running ClipDay did not record external copy " + suffix, seconds: 4) { self.isRecorded(marker) }
        pass("Installed app captured external copy: " + suffix)
        return marker
    }
    func regularPaste(_ expected: String, label: String) throws {
        try command("target")
        try key(9, flags: .maskCommand)
        try wait("Normal Command-V result incorrect: " + label) { self.state()["destination"] as? String == expected }
        pass("Real Command-V inserted expected content: " + label)
    }
    func stringAttribute(_ element: AXUIElement, _ key: String) -> String? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result as? String
    }
    func children(_ element: AXUIElement) -> [AXUIElement] {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &result) == .success else { return [] }
        return result as? [AXUIElement] ?? []
    }
    func findButton(_ element: AXUIElement, containing marker: String, ancestor: AXUIElement? = nil, depth: Int = 0) -> AXUIElement? {
        guard depth < 24 else { return nil }
        let isButton = stringAttribute(element, kAXRoleAttribute) == kAXButtonRole
        let button = isButton ? element : ancestor
        for key in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            if stringAttribute(element, key)?.contains(marker) == true, let button { return button }
        }
        for child in children(element) { if let found = findButton(child, containing: marker, ancestor: button, depth: depth + 1) { return found } }
        return nil
    }
    func historyPaste(_ marker: String, label: String) throws {
        try command("target")
        let plist = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/io.jlmac.ClipDay.plist")
        guard let prefs = NSDictionary(contentsOf: plist), let data = prefs["shortcut"] as? Data,
              let shortcut = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let code = shortcut["keyCode"] as? UInt16, let mods = shortcut["modifiers"] as? UInt32 else { throw TestFailure(label: "Cannot read selected shortcut") }
        var flags: CGEventFlags = []
        if mods & 256 != 0 { flags.insert(.maskCommand) }; if mods & 512 != 0 { flags.insert(.maskShift) }
        if mods & 2048 != 0 { flags.insert(.maskAlternate) }; if mods & 4096 != 0 { flags.insert(.maskControl) }
        try key(code, flags: flags, global: true)
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "io.jlmac.ClipDay").first else { throw TestFailure(label: "ClipDay not running") }
        try wait("Global shortcut did not open installed ClipDay") { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
        let root = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(root, 0.5)
        var button: AXUIElement?
        try wait("Test history row not accessible") { button = self.findButton(root, containing: marker); return button != nil }
        guard AXUIElementPerformAction(button!, kAXPressAction as CFString) == .success else { throw TestFailure(label: "Could not select test history row") }
        try wait("History click did not paste into target: " + label) { self.state()["destination"] as? String == marker }
        pass("Clicking installed app history pasted directly: " + label)
    }
    func run() throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw TestFailure(label: "Native test process lacks accessibility permission") }
        try captureOriginal()
        let process = Process(); process.executableURL = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("build/PasteFixture.app/Contents/MacOS/PasteFixture"); process.arguments = [root.path]
        try process.run(); fixture = process
        try wait("Fixture did not start") { self.state()["pid"] != nil }
        let a = try copySource("A"); try regularPaste(a, label: "A")
        let b = try copySource("B")
        do { try historyPaste(a, label: "older A") }
        catch { pasteFailures.append(error.localizedDescription); print("FAIL: " + error.localizedDescription) }
        if CommandLine.arguments.contains("--background-idle") {
            if pasteFailures.isEmpty { try checkHidden() }
            print("Waiting 75 seconds with ClipDay window hidden before next copy.")
            fflush(stdout)
            pump(75)
        }
        let c = try copySource("C"); try regularPaste(c, label: "new C after history A")
        if pasteFailures.isEmpty { try checkHidden() }
        do { try historyPaste(b, label: "older B") }
        catch { pasteFailures.append(error.localizedDescription); print("FAIL: " + error.localizedDescription) }
        let d = try copySource("D"); try regularPaste(d, label: "new D after history B")
        if pasteFailures.isEmpty { try checkHidden() }
        if !pasteFailures.isEmpty { throw TestFailure(label: "\(tests) checks passed; \(pasteFailures.count) automatic history pastes failed. Subsequent copy/paste checks completed.") }
        print("END-TO-END PASSED: \(tests) checks using actual installed app and temporary native text window.")
    }
    func cleanup() {
        fixture?.terminate()
        if touchedClipboard {
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: "io.jlmac.ClipDay").first
            app?.terminate(); pump(0.4)
            if let app, !app.isTerminated { kill(app.processIdentifier, SIGTERM); pump(0.2) }
            let digests = Set(markers.map(digest))
            let rows = records(), testRows = rows.filter { ($0["digest"] as? String).map(digests.contains) == true }
            let keep = rows.filter { ($0["digest"] as? String).map(digests.contains) != true }
            if let data = try? JSONSerialization.data(withJSONObject: keep) {
                try? data.write(to: historyRoot.appendingPathComponent("history.json"), options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyRoot.appendingPathComponent("history.json").path)
                for row in testRows {
                    if let id = row["id"] as? String, UUID(uuidString: id) != nil { try? fm.removeItem(at: historyRoot.appendingPathComponent("items/" + id + ".bin")) }
                }
            }
            if let current = clipboard.string(forType: .string), markers.contains(current) {
                clipboard.clearContents()
                let items = original.map { data -> NSPasteboardItem in let item = NSPasteboardItem(); for (type, value) in data { item.setData(value, forType: type) }; return item }
                if !items.isEmpty { clipboard.writeObjects(items) }
                print("Original clipboard restored; only generated test history removed.")
            } else { print("Clipboard changed externally; newer user copy preserved.") }
            let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open"); open.arguments = [appURL.path]; try? open.run(); open.waitUntilExit()
        }
        try? fm.removeItem(at: root)
    }
}

@main enum EndToEnd {
    static func main() {
        var journey: Journey?
        do { let test = try Journey(); journey = test; try test.run(); test.cleanup() }
        catch { FileHandle.standardError.write(Data("END-TO-END FAILED: \(error.localizedDescription)\n".utf8)); journey?.cleanup(); exit(1) }
    }
}
