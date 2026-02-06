import Cocoa

let homeKeyCode: Int64 = 115
let slash: UniChar = 0x002F  // '/'
let question: UniChar = 0x003F  // '?'

var eventTap: CFMachPort?

func remapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown || type == .keyUp else {
        return Unmanaged.passRetained(event)
    }

    if event.getIntegerValueField(.keyboardEventKeycode) == homeKeyCode {
        if type == .keyDown {
            var char: UniChar = event.flags.contains(.maskShift) ? question : slash
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)
        }
        // Use a neutral keycode (9 = 'v' on US, but the Unicode string overrides it)
        event.setIntegerValueField(.keyboardEventKeycode, value: 9)
    }

    return Unmanaged.passRetained(event)
}

let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: eventMask,
    callback: remapCallback,
    userInfo: nil
) else {
    fputs("Error: Could not create event tap. Grant Input Monitoring permission in System Settings → Privacy & Security → Input Monitoring.\n", stderr)
    exit(1)
}

eventTap = tap

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("remap-home-to-slash: running (Home → /, Shift+Home → ?)")
CFRunLoopRun()
