import AppKit
import Carbon

/// A global hotkey: virtual key code plus ⌃⌥⇧⌘ modifiers, with strings for display.
struct HotKeyCombo: Equatable {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags
    /// Human readable, e.g. "⌃⌥Space" (recorder, alerts).
    var label: String
    /// `NSMenuItem.keyEquivalent` string so the combo renders natively in menus.
    var keyEquivalent: String

    static let `default` = HotKeyCombo(
        keyCode: UInt32(kVK_Space),
        modifiers: [.control, .option],
        label: "⌃⌥Space",
        keyEquivalent: " "
    )

    /// The only modifiers a global hotkey can carry. Arrow and function keys also set
    /// `.function` / `.numericPad`, which must be masked out before mapping to Carbon.
    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
}

/// UserDefaults-backed settings. Domain is the bundle identifier (com.niid.NotesOverlay)
/// when running from the .app bundle.
enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyLabel = "hotKeyLabel"
        static let hotKeyEquivalent = "hotKeyEquivalent"
        static let notePath = "notePath"
        static let fontSize = "fontSize"
    }

    static var hotKey: HotKeyCombo {
        get {
            guard defaults.object(forKey: Key.hotKeyCode) != nil else { return .default }
            let rawModifiers = UInt(clamping: defaults.integer(forKey: Key.hotKeyModifiers))
            return HotKeyCombo(
                keyCode: UInt32(clamping: defaults.integer(forKey: Key.hotKeyCode)),
                modifiers: NSEvent.ModifierFlags(rawValue: rawModifiers)
                    .intersection(HotKeyCombo.relevantModifiers),
                label: defaults.string(forKey: Key.hotKeyLabel) ?? "?",
                keyEquivalent: defaults.string(forKey: Key.hotKeyEquivalent) ?? ""
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.hotKeyCode)
            defaults.set(Int(newValue.modifiers.rawValue), forKey: Key.hotKeyModifiers)
            defaults.set(newValue.label, forKey: Key.hotKeyLabel)
            defaults.set(newValue.keyEquivalent, forKey: Key.hotKeyEquivalent)
        }
    }

    /// Absolute path of the note file. Override with:
    ///   defaults write com.niid.NotesOverlay notePath ~/somewhere/else.txt
    static var notePath: String {
        if let custom = defaults.string(forKey: Key.notePath), !custom.isEmpty {
            return (custom as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent("Notes/scratchpad.txt")
    }

    static var fontSize: CGFloat {
        get {
            let stored = defaults.double(forKey: Key.fontSize)
            return stored > 0 ? CGFloat(stored) : 16
        }
        set { defaults.set(Double(newValue), forKey: Key.fontSize) }
    }
}
