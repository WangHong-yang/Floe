import AppKit

/// A user-chosen hold-to-talk key: a single modifier key (Fn, Right ⌥, …)
/// or a regular key with optional modifiers (F5, ⌃Space, …).
struct Hotkey: Equatable {
    var code: Int
    var modifiers: UInt64
    var name: String

    static let fn = Hotkey(code: 63, modifiers: 0, name: "🌐 / Fn")
    static let rightOption = Hotkey(code: 61, modifiers: 0, name: "Right ⌥ Option")
    static let modifierMask: UInt64 = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue

    /// Device-specific flag bit for each modifier key (NX_DEVICE*KEYMASK).
    static let modifierBits: [Int: UInt64] = [
        59: 0x01, 62: 0x2000,          // Control L/R
        56: 0x02, 60: 0x04,            // Shift L/R
        55: 0x08, 54: 0x10,            // Command L/R
        58: 0x20, 61: 0x40,            // Option L/R
        63: CGEventFlags.maskSecondaryFn.rawValue
    ]
    static let modifierNames: [Int: String] = [
        59: "Left ⌃ Control", 62: "Right ⌃ Control", 56: "Left ⇧ Shift", 60: "Right ⇧ Shift",
        55: "Left ⌘ Command", 54: "Right ⌘ Command", 58: "Left ⌥ Option", 61: "Right ⌥ Option",
        63: "🌐 / Fn"
    ]
    static let keyNames: [Int: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "⌦", 50: "`",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]

    var isModifierKey: Bool { Self.modifierBits[code] != nil }

    static func modifierSymbols(_ flags: UInt64) -> String {
        var s = ""
        if flags & CGEventFlags.maskControl.rawValue != 0 { s += "⌃" }
        if flags & CGEventFlags.maskAlternate.rawValue != 0 { s += "⌥" }
        if flags & CGEventFlags.maskShift.rawValue != 0 { s += "⇧" }
        if flags & CGEventFlags.maskCommand.rawValue != 0 { s += "⌘" }
        return s
    }

    static func load() -> Hotkey {
        let d = UserDefaults.standard
        if let code = d.object(forKey: "hotkeyCode") as? Int, let name = d.string(forKey: "hotkeyName") {
            return Hotkey(code: code, modifiers: UInt64(d.integer(forKey: "hotkeyModifiers")), name: name)
        }
        return (d.object(forKey: "useGlobe") as? Bool ?? true) ? .fn : .rightOption
    }

    func save() {
        let d = UserDefaults.standard
        d.set(code, forKey: "hotkeyCode")
        d.set(Int(modifiers), forKey: "hotkeyModifiers")
        d.set(name, forKey: "hotkeyName")
    }
}

/// Captures the next key the user presses inside Floe's own window.
/// A modifier alone is captured on release, so ⌃ then Space yields ⌃Space.
final class HotkeyRecorder {
    private var monitor: Any?
    private var pendingModifier: Int?

    func start(_ done: @escaping (Hotkey?) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let code = Int(event.keyCode)
            if event.type == .flagsChanged {
                guard let bit = Hotkey.modifierBits[code] else { return nil }
                let down = UInt64(event.modifierFlags.rawValue) & bit != 0
                if down { self.pendingModifier = code }
                else if self.pendingModifier == code {
                    self.finish(Hotkey(code: code, modifiers: 0, name: Hotkey.modifierNames[code] ?? "Key \(code)"), done)
                }
                return nil
            }
            if code == 53 { self.finish(nil, done); return nil }   // Esc cancels
            if event.isARepeat { return nil }
            let mods = UInt64(event.modifierFlags.rawValue) & Hotkey.modifierMask
            let key = Hotkey.keyNames[code]
                ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespaces)
                ?? ""
            let name = Hotkey.modifierSymbols(mods) + (key.isEmpty ? "Key \(code)" : key)
            self.finish(Hotkey(code: code, modifiers: mods, name: name), done)
            return nil
        }
    }

    private func finish(_ key: Hotkey?, _ done: (Hotkey?) -> Void) {
        stop()
        done(key)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingModifier = nil
    }
}
