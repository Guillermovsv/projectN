import Carbon.HIToolbox
import Foundation

/// The shortcut that starts dictation: a single modifier key (fn, right ⌘…), or any key, alone or with modifiers (A, ⌃⌥D, F13…).
struct DictationHotkey: Codable, Equatable {
    var keyCode: Int
    /// Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey). Zero for a single modifier key.
    var modifiers: Int = 0
    /// The key's name as typed on the user's keyboard layout. Empty for a single modifier key.
    var keyLabel: String = ""

    static let fn = DictationHotkey(keyCode: kVK_Function)

    /// Device-dependent flag of each modifier key, which tells left from right.
    private static let modifierFlags: [Int: UInt64] = [
        kVK_Control: 0x1, kVK_Shift: 0x2, kVK_RightShift: 0x4, kVK_Command: 0x8, kVK_RightCommand: 0x10,
        kVK_Option: 0x20, kVK_RightOption: 0x40, kVK_RightControl: 0x2000, kVK_Function: 0x800000,
    ]
    private static let soloNames: [Int: String] = [
        kVK_Function: "fn", kVK_RightCommand: "Right ⌘", kVK_RightOption: "Right ⌥", kVK_RightControl: "Right ⌃",
    ]
    private static let otherModifierNames: [Int: String] = [
        kVK_Command: "Left ⌘", kVK_Option: "Left ⌥", kVK_Control: "Left ⌃", kVK_Shift: "Left ⇧", kVK_RightShift: "Right ⇧",
    ]
    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Escape: "⎋",
    ]

    static func isModifierKey(_ keyCode: Int) -> Bool { modifierFlags[keyCode] != nil }

    /// Whether a modifier key is down, given the raw flags of an event (CGEventFlags and NSEvent agree on these bits).
    static func isPressed(modifierKey keyCode: Int, flags: UInt64) -> Bool {
        guard let mask = modifierFlags[keyCode] else { return false }
        return flags & mask != 0
    }

    /// The name of a key, preferring fixed names over what the layout types (arrows and F-keys type private characters).
    static func label(keyCode: Int, typed: String?) -> String {
        if let name = functionKeys[keyCode] ?? namedKeys[keyCode] { return name }
        let text = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return text.isEmpty ? "Key \(keyCode)" : text
    }

    var isModifierOnly: Bool { Self.isModifierKey(keyCode) }

    var displayName: String {
        if isModifierOnly { return Self.soloNames[keyCode] ?? Self.otherModifierNames[keyCode] ?? "Key \(keyCode)" }
        var name = ""
        if modifiers & controlKey != 0 { name += "⌃" }
        if modifiers & optionKey != 0 { name += "⌥" }
        if modifiers & shiftKey != 0 { name += "⇧" }
        if modifiers & cmdKey != 0 { name += "⌘" }
        return name + (keyLabel.isEmpty ? Self.label(keyCode: keyCode, typed: nil) : keyLabel)
    }

    /// Why this can't be the dictation shortcut, or nil if it can. Any key works, alone or with modifiers,
    /// except the two dictation itself relies on.
    var problem: String? {
        if keyCode == kVK_Escape && !isModifierOnly { return "Esc is what cancels a dictation. Pick another key." }
        if keyCode == kVK_ANSI_V && modifiers == cmdKey { return "⌘V is how dictation pastes your text. Pick another shortcut." }
        return nil
    }

    /// A heads-up for shortcuts that work but take over something you normally use, or nil.
    var caution: String? {
        if isModifierOnly {
            guard Self.soloNames[keyCode] == nil else { return nil }
            if keyCode == kVK_Shift || keyCode == kVK_RightShift {
                return "Every dictation will start with ⇧ held, so each one gets enhanced."
            }
            return "Tapping this key alone starts a dictation; using it in a shortcut (like ⌘C) doesn't."
        }
        if Self.functionKeys[keyCode] != nil { return nil }
        if modifiers & (cmdKey | optionKey | controlKey) == 0 {
            return "\(displayName) won't type anymore in any app while it's the dictation shortcut."
        }
        return nil
    }

    /// The saved shortcut, or fn if there is none or it's no longer valid.
    static func decoded(from data: Data?) -> DictationHotkey {
        guard let data, let hotkey = try? JSONDecoder().decode(DictationHotkey.self, from: data), hotkey.problem == nil else { return .fn }
        return hotkey
    }
}

/// Turns the key events pressed while recording a shortcut into a shortcut.
struct HotkeyCapture {
    enum Outcome: Equatable {
        case pending, cancelled
        case captured(DictationHotkey)
        case rejected(String)
    }

    private var held = Set<Int>()
    private var solo: Int?

    /// A single modifier is only known once it's released with nothing pressed alongside it.
    mutating func flagsChanged(keyCode: Int, flags: UInt64) -> Outcome {
        guard DictationHotkey.isModifierKey(keyCode) else { return .pending }
        if DictationHotkey.isPressed(modifierKey: keyCode, flags: flags) {
            solo = held.isEmpty ? keyCode : nil
            held.insert(keyCode)
            return .pending
        }
        held.remove(keyCode)
        guard solo == keyCode else { return .pending }
        solo = nil
        return Self.outcome(DictationHotkey(keyCode: keyCode))
    }

    mutating func keyDown(keyCode: Int, modifiers: Int, typed: String?) -> Outcome {
        solo = nil
        if keyCode == kVK_Escape && modifiers == 0 { return .cancelled }
        return Self.outcome(DictationHotkey(keyCode: keyCode, modifiers: modifiers,
                                            keyLabel: DictationHotkey.label(keyCode: keyCode, typed: typed)))
    }

    private static func outcome(_ hotkey: DictationHotkey) -> Outcome {
        hotkey.problem.map(Outcome.rejected) ?? .captured(hotkey)
    }
}
