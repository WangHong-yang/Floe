import AppKit
import ApplicationServices

enum DictationClipboard {
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    @discardableResult
    static func write(_ text: String, transient: Bool, to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        if transient {
            guard item.setData(Data(), forType: transientType) else { return false }
        }
        // Publish the text and marker together, so history observers never
        // see an intermediate plain-text fragment without its ignore marker.
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

/// Grapheme clusters keep emoji and Chinese intact when a hypothesis changes.
struct TranscriptPatch {
    let removeCount: Int
    let append: String
    static func between(_ old: String, _ new: String) -> TranscriptPatch {
        let before = Array(old), after = Array(new)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        return TranscriptPatch(removeCount: before.count - prefix, append: String(after.dropFirst(prefix)))
    }
}

/// Main-thread updates replace only the suffix that we inserted ourselves.
final class LiveInsertion {
    static let eventMarker: Int64 = 0x474C4F42
    private let pid: pid_t
    private var inserted = ""
    init?() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        pid = app.processIdentifier
    }
    func update(_ text: String) -> Bool {
        guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        // A browser/editor may not expose a focused AX element; normal paste
        // still works there, so a missing element must not block insertion.
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            let field = value as! AXUIElement
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole)
            if (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return false }
        }
        let patch = TranscriptPatch.between(inserted, text)
        guard patch.removeCount > 0 || !patch.append.isEmpty else { return true }
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        var events: [CGEvent] = []
        func key(_ code: CGKeyCode, _ flags: CGEventFlags) -> Bool {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
            for event in [down, up] {
                event.flags = flags
                event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
                events.append(event)
            }
            return true
        }
        for _ in 0..<patch.removeCount { guard key(123, .maskShift) else { return false } }
        if !patch.append.isEmpty {
            guard key(9, .maskCommand) else { return false }
            guard DictationClipboard.write(patch.append, transient: true) else { return false }
        } else if patch.removeCount > 0 {
            guard key(51, []) else { return false }
        }
        for event in events { event.postToPid(pid) }
        inserted = text
        return true
    }
}
