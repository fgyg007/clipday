import AppKit
import ApplicationServices

struct PasteTarget {
    let app: NSRunningApplication
    let window: AXUIElement?
    let element: AXUIElement?
    init(app: NSRunningApplication) {
        self.app = app
        guard AXIsProcessTrusted() else { window = nil; element = nil; return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        window = Self.attribute(application, kAXFocusedWindowAttribute)
        element = Self.attribute(application, kAXFocusedUIElementAttribute)
    }
    private static func attribute(_ object: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(object, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    func restoreFocus() {
        if let window {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        if let element { AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) }
    }
}

enum PasteGate: Equatable {
    case wait, ready, cancel(String)
    static func evaluate(trusted: Bool, alive: Bool, front: pid_t?, target: pid_t, own: pid_t, unchanged: Bool, released: Bool, elapsed: TimeInterval) -> PasteGate {
        if !trusted { return .cancel("辅助功能权限未开启，内容已复制，但尚未粘贴。") }
        if !alive { return .cancel("目标应用已退出，内容已复制，但尚未粘贴。") }
        if !unchanged { return .cancel("剪贴板内容已变化，本次自动粘贴已取消。") }
        if elapsed >= 2 { return .cancel("未能恢复目标窗口，或修饰键尚未松开。内容已复制，可按 ⌘V 粘贴。") }
        if let front, front != target && front != own { return .cancel("你已切换到其他应用，本次自动粘贴已取消。") }
        return front == target && released ? .ready : .wait
    }
}

final class AutoPaster {
    private var generation = UUID()
    static var authorized: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }
    static func openPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    func cancel() { generation = UUID() }
    static func pasteEvents() -> (CGEvent, CGEvent)? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return nil }
        down.flags = .maskCommand; up.flags = .maskCommand
        return (down, up)
    }
    func paste(to target: PasteTarget, pasteboard: NSPasteboard, completion: @escaping (String?) -> Void) {
        cancel()
        let token = generation, started = Date(), changeCount = pasteboard.changeCount
        let own = ProcessInfo.processInfo.processIdentifier
        guard Self.authorized else { completion("请先在辅助功能中允许“轻贴”，才能直接粘贴。内容已复制，但尚未粘贴。"); return }
        guard !target.app.isTerminated, target.app.processIdentifier != own else { completion("请先点选目标应用中的输入位置，再打开轻贴。"); return }
        guard target.app.activate(options: []) else { completion("无法激活目标应用。内容已复制，可手动粘贴。"); return }
        var focusRestored = false
        func poll() {
            guard self.generation == token else { return }
            let flags = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
            let state = PasteGate.evaluate(trusted: Self.authorized, alive: !target.app.isTerminated,
                front: NSWorkspace.shared.frontmostApplication?.processIdentifier, target: target.app.processIdentifier,
                own: own, unchanged: pasteboard.changeCount == changeCount, released: flags.isEmpty, elapsed: Date().timeIntervalSince(started))
            switch state {
            case .cancel(let reason): completion(reason)
            case .wait: DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
            case .ready:
                if !focusRestored {
                    target.restoreFocus(); focusRestored = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: poll)
                    return
                }
                guard let (down, up) = Self.pasteEvents() else {
                    completion("无法创建粘贴操作。内容已复制，可手动粘贴。"); return
                }
                // Only send Command-V to the selected app; never type text or send Return.
                down.postToPid(target.app.processIdentifier); up.postToPid(target.app.processIdentifier)
                completion(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: poll)
    }
}
