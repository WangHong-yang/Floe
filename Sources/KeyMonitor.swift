import AppKit
import IOKit.hid

final class KeyMonitor {
    var onHold: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onUnavailable: (() -> Void)?
    var onInteraction: (() -> Void)?
    var hotkey = Hotkey.fn
    /// While the settings window records a new shortcut, pass everything through.
    var suspended = false
    /// Toggle mode with a modifier key: fire on a clean tap (press + release
    /// with no other key in between), so ⌥← / ⌥-click etc. don't toggle recording.
    var toggleTap = false
    private var modifierDown = false
    private var chorded = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hid: IOHIDManager?
    private var pressed = false

    func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyMonitor>.fromOpaque(context).takeUnretainedValue()
            if event.getIntegerValueField(.eventSourceUserData) == LiveInsertion.eventMarker {
                return Unmanaged.passUnretained(event)
            }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                monitor.setPressed(false)
                monitor.onUnavailable?()
                return Unmanaged.passUnretained(event)
            }
            if monitor.suspended { return Unmanaged.passUnretained(event) }
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let hotkey = monitor.hotkey
            if monitor.modifierDown && (type == .keyDown || type == .leftMouseDown || type == .rightMouseDown
                || (type == .flagsChanged && key != hotkey.code)) {
                monitor.chorded = true
            }
            if type == .keyDown && key == 53 {
                monitor.setPressed(false)
                monitor.onCancel?()
            } else if type == .flagsChanged {
                if hotkey.isModifierKey && key == hotkey.code, let bit = Hotkey.modifierBits[key] {
                    let down = event.flags.rawValue & bit != 0
                    if monitor.toggleTap {
                        if down { if !monitor.modifierDown { monitor.modifierDown = true; monitor.chorded = false } }
                        else if monitor.modifierDown {
                            monitor.modifierDown = false
                            if !monitor.chorded { monitor.setPressed(true); monitor.setPressed(false) }
                        }
                    } else {
                        monitor.setPressed(down)
                    }
                }
            } else if !hotkey.isModifierKey && key == hotkey.code && (type == .keyDown || type == .keyUp) {
                // Regular-key shortcut: consume it so it does not type into the app.
                if type == .keyUp {
                    if monitor.pressed { monitor.setPressed(false); return nil }
                } else if monitor.pressed {
                    return nil   // auto-repeat while held
                } else if event.flags.rawValue & Hotkey.modifierMask == hotkey.modifiers,
                          event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    monitor.setPressed(true)
                    return nil
                }
                if type == .keyDown { monitor.onInteraction?() }
            } else if type == .keyDown || type == .leftMouseDown || type == .rightMouseDown {
                monitor.onInteraction?()
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: hotkey.isModifierKey ? .listenOnly : .defaultTap, eventsOfInterest: CGEventMask(mask), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        // Some Apple keyboards expose Fn only through the vendor HID element.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6],
            [kIOHIDDeviceUsagePageKey: 0xff, kIOHIDDeviceUsageKey: 1]
        ] as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let monitor = Unmanaged<KeyMonitor>.fromOpaque(context).takeUnretainedValue()
            guard monitor.hotkey.code == 63, !monitor.suspended else { return }
            let element = IOHIDValueGetElement(value)
            // Apple vendor top-case Fn: usage page 0xff, usage 3.
            if IOHIDElementGetUsagePage(element) == 0xff && IOHIDElementGetUsage(element) == 3 {
                let down = IOHIDValueGetIntegerValue(value) != 0
                guard monitor.toggleTap else { return monitor.setPressed(down) }
                // Shares state with the flagsChanged path, so only one fires.
                if down { if !monitor.modifierDown { monitor.modifierDown = true; monitor.chorded = false } }
                else if monitor.modifierDown {
                    monitor.modifierDown = false
                    if !monitor.chorded { monitor.setPressed(true); monitor.setPressed(false) }
                }
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        if opened { hid = manager }
        else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        return tap != nil || opened
    }

    private func setPressed(_ value: Bool) {
        guard pressed != value else { return }
        pressed = value
        onHold?(value)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if let hid {
            IOHIDManagerUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        tap = nil
        source = nil
        hid = nil
        pressed = false
    }
}
