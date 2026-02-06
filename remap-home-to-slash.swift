import Cocoa
import Foundation

// MARK: - Configuration types

struct ModifierMapping: Decodable {
    let shift: String?
    let option: String?
    let ctrl: String?
    let cmd: String?

    // Compound modifiers via dynamic keys
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    let all: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var dict: [String: String] = [:]
        for key in container.allKeys {
            dict[key.stringValue] = try container.decode(String.self, forKey: key)
        }
        self.shift = dict["shift"]
        self.option = dict["option"]
        self.ctrl = dict["ctrl"]
        self.cmd = dict["cmd"]
        self.all = dict
    }
}

struct KeyMapping: Decodable {
    let from: Int64
    let to: String
    let modifiers: ModifierMapping?
}

struct Config: Decodable {
    let mappings: [KeyMapping]
}

// MARK: - Resolved mapping types

struct ResolvedMapping {
    let defaultChar: UniChar
    let modifiers: [String: UniChar?]  // nil = passthrough
}

// MARK: - Global state

var eventTap: CFMachPort?
var mappingTable: [Int64: ResolvedMapping] = [:]
var activeRemaps: Set<Int64> = []

// MARK: - Config loading

func configPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.config/remap-home-to-slash/config.json"
}

func parseHex(_ hex: String) -> UniChar? {
    return UInt16(hex, radix: 16)
}

func loadConfig() -> [Int64: ResolvedMapping] {
    var table: [Int64: ResolvedMapping] = [:]

    let path = configPath()
    guard FileManager.default.fileExists(atPath: path),
          let data = FileManager.default.contents(atPath: path) else {
        fputs("Config not found at \(path), using default Home→/ mapping.\n", stderr)
        table[115] = ResolvedMapping(
            defaultChar: 0x002F,
            modifiers: ["shift": 0x003F]
        )
        return table
    }

    do {
        let config = try JSONDecoder().decode(Config.self, from: data)
        for mapping in config.mappings {
            guard let defaultChar = parseHex(mapping.to) else {
                fputs("Warning: invalid hex '\(mapping.to)' for keycode \(mapping.from), skipping.\n", stderr)
                continue
            }

            var modMap: [String: UniChar?] = [:]
            if let mods = mapping.modifiers {
                for (key, value) in mods.all {
                    if value.lowercased() == "passthrough" {
                        modMap[key] = nil as UniChar?
                    } else if let char = parseHex(value) {
                        modMap[key] = char
                    } else {
                        fputs("Warning: invalid hex '\(value)' for modifier '\(key)' on keycode \(mapping.from), skipping modifier.\n", stderr)
                    }
                }
            }

            table[mapping.from] = ResolvedMapping(defaultChar: defaultChar, modifiers: modMap)
        }

        if table.isEmpty {
            fputs("Warning: config has no valid mappings.\n", stderr)
        }
    } catch {
        fputs("Error parsing config: \(error). Using default Home→/ mapping.\n", stderr)
        table[115] = ResolvedMapping(
            defaultChar: 0x002F,
            modifiers: ["shift": 0x003F]
        )
    }

    return table
}

// MARK: - Modifier detection

func activeModifierKey(flags: CGEventFlags) -> String? {
    var parts: [String] = []
    if flags.contains(.maskCommand) { parts.append("cmd") }
    if flags.contains(.maskControl) { parts.append("ctrl") }
    if flags.contains(.maskAlternate) { parts.append("option") }
    if flags.contains(.maskShift) { parts.append("shift") }

    if parts.isEmpty { return nil }
    // Already alphabetically sorted: cmd, ctrl, option, shift
    return parts.joined(separator: "+")
}

// MARK: - Event callback

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

    let keycode = event.getIntegerValueField(.keyboardEventKeycode)

    guard let resolved = mappingTable[keycode] else {
        return Unmanaged.passRetained(event)
    }

    if type == .keyUp {
        if activeRemaps.contains(keycode) {
            activeRemaps.remove(keycode)
            event.setIntegerValueField(.keyboardEventKeycode, value: 9)
        }
        return Unmanaged.passRetained(event)
    }

    // keyDown
    let modKey = activeModifierKey(flags: event.flags)
    var charToSet: UniChar

    if let modKey = modKey, let modEntry = resolved.modifiers[modKey] {
        if let char = modEntry {
            charToSet = char
        } else {
            // passthrough — don't remap this key
            return Unmanaged.passRetained(event)
        }
    } else if let modKey = modKey, resolved.modifiers[modKey] == nil {
        // Modifier combo not in config — use default
        charToSet = resolved.defaultChar
    } else {
        // No modifiers pressed
        charToSet = resolved.defaultChar
    }

    activeRemaps.insert(keycode)
    event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &charToSet)
    event.setIntegerValueField(.keyboardEventKeycode, value: 9)

    return Unmanaged.passRetained(event)
}

// MARK: - Main

mappingTable = loadConfig()

var mappingDesc: [String] = []
for (keycode, resolved) in mappingTable.sorted(by: { $0.key < $1.key }) {
    let defaultStr = String(format: "U+%04X", resolved.defaultChar)
    var desc = "keycode \(keycode) → \(defaultStr)"
    for (mod, charOpt) in resolved.modifiers.sorted(by: { $0.key < $1.key }) {
        if let char = charOpt {
            desc += ", \(mod) → \(String(format: "U+%04X", char))"
        } else {
            desc += ", \(mod) → passthrough"
        }
    }
    mappingDesc.append(desc)
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
    fputs("Error: Could not create event tap. Grant Accessibility permission in System Settings → Privacy & Security → Accessibility.\n", stderr)
    exit(1)
}

eventTap = tap

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

if mappingDesc.isEmpty {
    print("remap-home-to-slash: running (no mappings loaded)")
} else {
    print("remap-home-to-slash: running (\(mappingDesc.joined(separator: "; ")))")
}

CFRunLoopRun()
