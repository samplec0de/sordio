import Foundation

/// Комбинация клавиш для управления микрофоном.
///
/// Маска модификаторов передаётся как «сырое» значение `CGEventFlags`,
/// чтобы ядро не зависело от AppKit и оставалось тестируемым.
public struct HotkeyCombo: Equatable, Codable {
    public var keyCode: UInt16
    public var control: Bool
    public var option: Bool
    public var command: Bool
    public var shift: Bool

    public init(keyCode: UInt16, control: Bool, option: Bool, command: Bool, shift: Bool) {
        self.keyCode = keyCode
        self.control = control
        self.option = option
        self.command = command
        self.shift = shift
    }

    public static let `default` = HotkeyCombo(keyCode: 0, control: true, option: true,
                                              command: false, shift: false)

    private enum Mask {
        static let shift: UInt64   = 0x20000
        static let control: UInt64 = 0x40000
        static let option: UInt64  = 0x80000
        static let command: UInt64 = 0x100000
        static let all: UInt64 = shift | control | option | command
    }

    private var requiredMask: UInt64 {
        var mask: UInt64 = 0
        if control { mask |= Mask.control }
        if option  { mask |= Mask.option }
        if command { mask |= Mask.command }
        if shift   { mask |= Mask.shift }
        return mask
    }

    /// Совпадение по клавише и точному набору модификаторов.
    public func matches(keyCode: UInt16, flags: UInt64) -> Bool {
        keyCode == self.keyCode && (flags & Mask.all) == requiredMask
    }

    /// Все ли модификаторы комбинации всё ещё зажаты.
    /// Отпускание любого из них завершает push-to-talk.
    public func modifiersHeld(in flags: UInt64) -> Bool {
        (flags & requiredMask) == requiredMask
    }

    public var displayString: String {
        var out = ""
        if control { out += "⌃" }
        if option  { out += "⌥" }
        if shift   { out += "⇧" }
        if command { out += "⌘" }
        return out + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt16) -> String {
        if let named = namedKeys[code] { return named }
        if let letter = letterKeys[code] { return letter }
        return "Key\(code)"
    }

    private static let namedKeys: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        118: "F4", 120: "F2", 122: "F1", 126: "↑", 125: "↓", 123: "←", 124: "→"
    ]

    private static let letterKeys: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0"
    ]
}
