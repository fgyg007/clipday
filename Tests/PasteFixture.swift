import AppKit

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    let root: URL
    let source = NSTextView()
    let destination = NSTextView()
    var window: NSWindow!
    var timer: Timer?
    var sequence = -1
    init(root: URL) { self.root = root }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        for (label, action, key) in [("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { edit.addItem(withTitle: label, action: Selector(action), keyEquivalent: key) }
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 620, height: 380), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "轻贴临时测试窗口（仅测试数据）"; window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 380))
        for (text, y, label) in [(source, CGFloat(210), "复制源"), (destination, CGFloat(35), "粘贴目标")] {
            let title = NSTextField(labelWithString: label); title.frame = NSRect(x: 20, y: y + 135, width: 500, height: 22); content.addSubview(title)
            let scroll = NSScrollView(frame: NSRect(x: 20, y: y, width: 580, height: 130)); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
            text.frame = scroll.contentView.bounds; text.isRichText = false; text.isEditable = true; text.isSelectable = true; text.autoresizingMask = [.width, .height]
            scroll.documentView = text; content.addSubview(scroll)
        }
        window.contentView = content; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.poll() }
        writeState()
    }
    func poll() {
        if let data = try? Data(contentsOf: root.appendingPathComponent("command.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let seq = object["seq"] as? Int, seq != sequence {
            sequence = seq
            switch object["operation"] as? String {
            case "source":
                source.string = object["text"] as? String ?? ""
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                window.makeFirstResponder(source); source.selectAll(nil)
            case "target":
                destination.string = ""
                window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                window.makeFirstResponder(destination)
            case "quit": NSApp.terminate(nil)
            default: break
            }
        }
        writeState()
    }
    func writeState() {
        let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "seq": sequence, "destination": destination.string,
                                  "sourceFocused": window?.firstResponder === source, "targetFocused": window?.firstResponder === destination]
        if let data = try? JSONSerialization.data(withJSONObject: state) { try? data.write(to: root.appendingPathComponent("state.json"), options: .atomic) }
    }
}

@main enum Fixture {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = FixtureDelegate(root: URL(fileURLWithPath: CommandLine.arguments[1]))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
