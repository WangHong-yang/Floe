import AppKit
import ApplicationServices

/// Reads only the focused field and the span inserted by this dictation.
/// No key logger, clipboard observer, disk history, or other-field fallback.
final class CorrectionObserver {
    private let pid: pid_t
    private let field: AXUIElement
    private let prefix: String
    private let suffix: String
    private var original = ""
    private var last = ""
    private var considered = ""
    private var stableSince = Date()
    private var expires = Date()
    private var timer: Timer?
    var onCandidate: (((String, String)?) -> Void)?

    init?() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        pid = app.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        field = focused as! AXUIElement
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != kAXSecureTextFieldSubrole as String,
              let value = Self.value(field) else { return nil }
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selection as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0,
              range.location <= (value as NSString).length,
              range.length <= (value as NSString).length - range.location else { return nil }
        prefix = (value as NSString).substring(to: range.location)
        suffix = (value as NSString).substring(from: range.location + range.length)
    }

    func arm(_ transcript: String) {
        stop()
        guard !transcript.isEmpty, Self.value(field) == prefix + transcript + suffix else { return }
        original = transcript
        last = transcript
        considered = transcript
        expires = Date().addingTimeInterval(45)
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onCandidate?(nil)
    }

    private static func value(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func poll() {
        guard Date() < expires, AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { stop(); return }
        var focused: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFEqual(focused, field),
              let value = Self.value(field),
              value.hasPrefix(prefix), value.hasSuffix(suffix),
              value.count >= prefix.count + suffix.count else { stop(); return }
        let edited = String(value.dropFirst(prefix.count).dropLast(suffix.count))
        if edited != last {
            last = edited
            stableSince = Date()
            onCandidate?(nil)
        } else if edited != considered, Date().timeIntervalSince(stableSince) >= 1.2 {
            considered = edited
            onCandidate?(Hotwords.correction(from: original, to: edited))
        }
    }

    deinit { timer?.invalidate() }
}
