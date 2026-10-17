import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32 // Carbon modifier bits; independent of keyboard layout.
    let keyName: String
    #if CLOUD
    static let standard = Shortcut(keyCode: 9, modifiers: UInt32(controlKey | optionKey | shiftKey), keyName: "V")
    #else
    static let standard = Shortcut(keyCode: 9, modifiers: UInt32(controlKey | optionKey), keyName: "V")
    #endif
    var label: String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") +
        (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
        (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") +
        (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + keyName
    }
    static func from(_ event: NSEvent) -> Shortcut {
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        let names: [UInt16: String] = [36:"Return", 48:"Tab", 49:"Space", 51:"Delete", 53:"Esc", 123:"←",124:"→",125:"↓",126:"↑",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12"]
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods, keyName: names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
    }
}

final class HotKeyManager {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var current: Shortcut?
    var onPress: (() -> Void)?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
            manager.onPress?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    deinit { if let ref { UnregisterEventHotKey(ref) }; if let handler { RemoveEventHandler(handler) } }

    static func systemConflict(_ shortcut: Shortcut) throws -> String? {
        var array: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&array)
        guard status == noErr, let array else { throw ClipError.message("暂时无法读取系统快捷键（\(status)），未更改设置。") }
        let keys = array.takeRetainedValue() as NSArray
        for case let key as NSDictionary in keys {
            let enabled = (key[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue ?? false
            let code = (key[kHISymbolicHotKeyCode] as? NSNumber)?.uint32Value
            let mods = (key[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value
            if enabled && code == shortcut.keyCode && mods == shortcut.modifiers {
                return "\(shortcut.label) 已用于 macOS 系统功能，请换一个组合。"
            }
        }
        return nil
    }
    static func basicConflict(_ shortcut: Shortcut) -> String? {
        guard shortcut.modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else { return "请至少搭配 Command、Control 或 Option，避免影响正常输入。" }
        if [53, 57, 63].contains(shortcut.keyCode) { return "这个按键不适合作为剪贴板快捷键，请换一个。" }
        // Standard text editing and application commands must never be intercepted globally.
        let common: Set<UInt32> = [0,1,2,3,4,6,7,8,9,12,13,15,17,31,32,35,37,45,46,48,49,50]
        if shortcut.modifiers == UInt32(cmdKey) && common.contains(shortcut.keyCode) { return "\(shortcut.label) 是常用系统或应用操作，已避免占用。请增加 Control / Option 等修饰键。" }
        if shortcut.keyCode == 48 && shortcut.modifiers & UInt32(cmdKey) != 0 { return "这个组合用于切换应用，请换一个。" }
        if shortcut.keyCode == 12 && shortcut.modifiers == UInt32(cmdKey | controlKey) { return "这个组合用于锁定屏幕，请换一个。" }
        return nil
    }
    func set(_ shortcut: Shortcut) throws {
        if let reason = Self.basicConflict(shortcut) { throw ClipError.message(reason) }
        if let reason = try Self.systemConflict(shortcut) { throw ClipError.message(reason) }
        if current?.keyCode == shortcut.keyCode && current?.modifiers == shortcut.modifiers { return }
        var proposed: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x434C4950, id: 1), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &proposed)
        guard status == noErr, let proposed else {
            if status == eventHotKeyExistsErr { throw ClipError.message("\(shortcut.label) 已被其他全局快捷键占用，原设置已保留。") }
            throw ClipError.message("无法启用 \(shortcut.label)（系统返回 \(status)），原设置已保留。")
        }
        if let ref { UnregisterEventHotKey(ref) }
        ref = proposed; current = shortcut
    }
}
