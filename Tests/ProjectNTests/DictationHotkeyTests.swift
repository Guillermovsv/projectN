import Carbon.HIToolbox
import Foundation
import Testing
@testable import ProjectN

struct DictationHotkeyTests {
    private func combo(_ keyCode: Int, _ modifiers: Int, _ label: String = "D") -> DictationHotkey {
        DictationHotkey(keyCode: keyCode, modifiers: modifiers, keyLabel: label)
    }

    @Test func acceptsSupportedShortcuts() {
        #expect(DictationHotkey.fn.problem == nil)
        #expect(DictationHotkey(keyCode: kVK_RightCommand).problem == nil)
        #expect(DictationHotkey(keyCode: kVK_RightOption).problem == nil)
        #expect(combo(kVK_F13, 0, "F13").problem == nil)
        #expect(combo(kVK_ANSI_D, controlKey | optionKey).problem == nil)
        #expect(combo(kVK_Space, optionKey, "Space").problem == nil)
    }

    @Test func acceptsAnyKeyAlone() {
        #expect(combo(kVK_ANSI_A, 0, "A").problem == nil)
        #expect(combo(kVK_ANSI_D, shiftKey).problem == nil)
        #expect(DictationHotkey(keyCode: kVK_Command).problem == nil)
        #expect(DictationHotkey(keyCode: kVK_Shift).problem == nil)
        #expect(combo(kVK_ANSI_A, 0, "A").caution != nil)
        #expect(DictationHotkey(keyCode: kVK_Command).caution != nil)
        #expect(combo(kVK_ANSI_D, controlKey | optionKey).caution == nil)
        #expect(DictationHotkey.fn.caution == nil)
    }

    @Test func rejectsOnlyWhatDictationNeeds() {
        #expect(combo(kVK_Escape, controlKey, "⎋").problem != nil)
        #expect(combo(kVK_ANSI_V, cmdKey, "V").problem != nil)
        #expect(combo(kVK_ANSI_V, cmdKey | shiftKey, "V").problem == nil)
    }

    @Test func namesShortcuts() {
        #expect(DictationHotkey.fn.displayName == "fn")
        #expect(DictationHotkey(keyCode: kVK_RightOption).displayName == "Right ⌥")
        #expect(combo(kVK_ANSI_D, cmdKey | controlKey | optionKey | shiftKey).displayName == "⌃⌥⇧⌘D")
        #expect(DictationHotkey.label(keyCode: kVK_F13, typed: "\u{F710}") == "F13")
        #expect(DictationHotkey.label(keyCode: kVK_ANSI_Semicolon, typed: "ñ") == "Ñ")
    }

    @Test func tellsLeftFromRight() {
        let rightOption: UInt64 = 0x80000 | 0x40
        #expect(DictationHotkey.isPressed(modifierKey: kVK_RightOption, flags: rightOption))
        #expect(!DictationHotkey.isPressed(modifierKey: kVK_Option, flags: rightOption))
        #expect(DictationHotkey.isPressed(modifierKey: kVK_Function, flags: 0x800000))
    }

    @Test func savedShortcutRoundTripsAndBadDataFallsBackToFn() throws {
        let hotkey = combo(kVK_ANSI_D, controlKey | optionKey)
        #expect(DictationHotkey.decoded(from: try JSONEncoder().encode(hotkey)) == hotkey)
        #expect(DictationHotkey.decoded(from: nil) == .fn)
        #expect(DictationHotkey.decoded(from: Data("nope".utf8)) == .fn)
        #expect(DictationHotkey.decoded(from: try JSONEncoder().encode(combo(kVK_ANSI_A, 0, "A"))) == combo(kVK_ANSI_A, 0, "A"))
        #expect(DictationHotkey.decoded(from: try JSONEncoder().encode(combo(kVK_ANSI_V, cmdKey, "V"))) == .fn)
    }

    @Test func capturesSingleModifierOnRelease() {
        var capture = HotkeyCapture()
        #expect(capture.flagsChanged(keyCode: kVK_RightCommand, flags: 0x100000 | 0x10) == .pending)
        #expect(capture.flagsChanged(keyCode: kVK_RightCommand, flags: 0) == .captured(DictationHotkey(keyCode: kVK_RightCommand)))
    }

    @Test func capturesKeyWithModifiersWithoutCapturingTheModifier() {
        var capture = HotkeyCapture()
        #expect(capture.flagsChanged(keyCode: kVK_Control, flags: 0x1) == .pending)
        #expect(capture.flagsChanged(keyCode: kVK_Option, flags: 0x1 | 0x20) == .pending)
        #expect(capture.keyDown(keyCode: kVK_ANSI_D, modifiers: controlKey | optionKey, typed: "d")
                == .captured(combo(kVK_ANSI_D, controlKey | optionKey)))
    }

    @Test func twoModifiersAloneCaptureNothing() {
        var capture = HotkeyCapture()
        _ = capture.flagsChanged(keyCode: kVK_RightCommand, flags: 0x10)
        _ = capture.flagsChanged(keyCode: kVK_RightOption, flags: 0x10 | 0x40)
        #expect(capture.flagsChanged(keyCode: kVK_RightOption, flags: 0x10) == .pending)
        #expect(capture.flagsChanged(keyCode: kVK_RightCommand, flags: 0) == .pending)
    }

    @Test func escCancelsAndAnyKeyIsCaptured() {
        var capture = HotkeyCapture()
        #expect(capture.keyDown(keyCode: kVK_Escape, modifiers: 0, typed: "\u{1B}") == .cancelled)
        #expect(capture.keyDown(keyCode: kVK_ANSI_A, modifiers: 0, typed: "a") == .captured(combo(kVK_ANSI_A, 0, "A")))
        _ = capture.flagsChanged(keyCode: kVK_Command, flags: 0x8)
        #expect(capture.flagsChanged(keyCode: kVK_Command, flags: 0) == .captured(DictationHotkey(keyCode: kVK_Command)))
        guard case .rejected = capture.keyDown(keyCode: kVK_ANSI_V, modifiers: cmdKey, typed: "v") else {
            Issue.record("⌘V must be rejected"); return
        }
    }
}
