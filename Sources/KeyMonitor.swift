import AppKit
import IOKit.hid

final class KeyMonitor {
    var onHold: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onUnavailable: (() -> Void)?
    var onInteraction: (() -> Void)?
    var useGlobe = true
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hid: IOHIDManager?
    private var pressed = false

    func start() -> Bool {
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
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
            } else if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                monitor.setPressed(false)
                monitor.onCancel?()
            } else if type == .flagsChanged {
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                if monitor.useGlobe && key == 63 {
                    monitor.setPressed(event.flags.contains(.maskSecondaryFn))
                } else if !monitor.useGlobe && key == 61 {
                    // NX_DEVICERALTKEYMASK distinguishes right Option from left.
                    monitor.setPressed(event.flags.rawValue & 0x40 != 0)
                }
            } else if type == .keyDown || type == .leftMouseDown || type == .rightMouseDown {
                monitor.onInteraction?()
            }
            return Unmanaged.passUnretained(event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: callback,
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
            guard monitor.useGlobe else { return }
            let element = IOHIDValueGetElement(value)
            // Apple vendor top-case Fn: usage page 0xff, usage 3.
            if IOHIDElementGetUsagePage(element) == 0xff && IOHIDElementGetUsage(element) == 3 {
                monitor.setPressed(IOHIDValueGetIntegerValue(value) != 0)
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
