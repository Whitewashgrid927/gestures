import Carbon
import Foundation

/// Presentation follows the executable key code, never a label from a shared file.
enum KeyDisplay {
    private static let special: [UInt16: String] = [
        123: "←", 124: "→", 125: "↓", 126: "↑", 36: "Return", 48: "Tab",
        49: "Space", 51: "Delete", 53: "Escape", 76: "Enter", 117: "Forward Delete",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20"
    ]
    static func label(for code: UInt16, command: Bool = false) -> String {
        if let label = special[code] { return label }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Key \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        return translated(code, data: data, command: command) ?? "Key \(code)"
    }
    // Accepting layout data also lets tests check another layout without changing the user's settings.
    static func translated(_ code: UInt16, data: CFData, command: Bool = false) -> String? {
        guard let bytes = CFDataGetBytePtr(data), CFDataGetLength(data) > 0 else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0, count = 0
        var characters = [UniChar](repeating: 0, count: 16)
        let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), command ? UInt32(cmdKey >> 8) : 0,
            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead,
            characters.count, &count, &characters)
        guard status == noErr, count > 0, count <= characters.count else { return nil }
        let value = String(utf16CodeUnits: characters, count: count).uppercased()
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value) }) else { return nil }
        return value
    }
}
