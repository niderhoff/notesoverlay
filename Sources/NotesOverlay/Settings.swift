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

/// Highlight colour used for list markers, checkboxes and the text cursor.
enum AccentChoice: String, CaseIterable {
    case red, blue, system

    var title: String {
        switch self {
        case .red: return "Red"
        case .blue: return "Blue"
        case .system: return "System Accent"
        }
    }

    /// Coral that reads well on both appearances.
    private static let coral = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.93, green: 0.36, blue: 0.33, alpha: 1)
            : NSColor(srgbRed: 0.85, green: 0.27, blue: 0.24, alpha: 1)
    }

    var color: NSColor {
        switch self {
        case .red: return Self.coral
        case .blue: return .systemBlue
        case .system: return .controlAccentColor
        }
    }
}

/// How much of what is behind the window shows through.
enum Translucency: String, CaseIterable {
    case full, reduced, off

    var title: String {
        switch self {
        case .full: return "Full"
        case .reduced: return "Reduced"
        case .off: return "Off"
        }
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
        static let fontSize = "fontSize"
        static let accent = "accentColor"
        static let translucent = "translucentBackground" // pre-1.2 on/off
        static let translucency = "translucency"
        static let notePath = "notePath" // 1.0: the single note file
        static let notesDirectory = "notesDirectory"
        static let didMigrateLegacyNote = "didMigrateLegacyNote"
        static let currentNote = "currentNote"
        static let pinnedNotes = "pinnedNotes"
        static let lastOpened = "lastOpened"
    }

    // MARK: Hotkey

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

    // MARK: Editor

    static var fontSize: CGFloat {
        get {
            let stored = defaults.double(forKey: Key.fontSize)
            return stored > 0 ? CGFloat(stored) : 16
        }
        set { defaults.set(Double(newValue), forKey: Key.fontSize) }
    }

    // MARK: Appearance

    static var accent: AccentChoice {
        get { AccentChoice(rawValue: defaults.string(forKey: Key.accent) ?? "") ?? .red }
        set { defaults.set(newValue.rawValue, forKey: Key.accent) }
    }

    static var translucency: Translucency {
        get {
            if let raw = defaults.string(forKey: Key.translucency), let level = Translucency(rawValue: raw) { return level }
            if defaults.object(forKey: Key.translucent) != nil, !defaults.bool(forKey: Key.translucent) { return .off }
            return .reduced
        }
        set { defaults.set(newValue.rawValue, forKey: Key.translucency) }
    }

    // MARK: Notes location

    /// Folder holding one .txt file per note. Set from the menu ("Choose Notes Folder…")
    /// or with:  defaults write com.niid.NotesOverlay notesDirectory ~/somewhere
    static var notesDirectory: URL {
        get {
            if let custom = defaults.string(forKey: Key.notesDirectory), !custom.isEmpty {
                return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
            }
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Notes/NotesOverlay", isDirectory: true)
        }
        set { defaults.set(newValue.standardizedFileURL.path, forKey: Key.notesDirectory) }
    }

    /// Where 1.0 kept its single note. Moved into `notesDirectory` on first launch.
    static var legacyNotePath: String {
        if let custom = defaults.string(forKey: Key.notePath), !custom.isEmpty {
            return (custom as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent("Notes/scratchpad.txt")
    }

    static var didMigrateLegacyNote: Bool {
        get { defaults.bool(forKey: Key.didMigrateLegacyNote) }
        set { defaults.set(newValue, forKey: Key.didMigrateLegacyNote) }
    }

    // MARK: Per-note metadata, keyed by file name

    /// The note to reopen at launch.
    static var currentNote: String? {
        get { defaults.string(forKey: Key.currentNote) }
        set { defaults.set(newValue, forKey: Key.currentNote) }
    }

    static var pinnedNotes: [String] {
        get { defaults.stringArray(forKey: Key.pinnedNotes) ?? [] }
        set { defaults.set(newValue, forKey: Key.pinnedNotes) }
    }

    static var lastOpened: [String: Date] {
        get {
            let raw = defaults.dictionary(forKey: Key.lastOpened) as? [String: Double] ?? [:]
            return raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
        set { defaults.set(newValue.mapValues { $0.timeIntervalSince1970 }, forKey: Key.lastOpened) }
    }

    static func markOpened(_ filename: String) {
        var opened = lastOpened
        opened[filename] = Date()
        lastOpened = opened
    }

    static func togglePin(_ filename: String) {
        var pinned = pinnedNotes
        if let index = pinned.firstIndex(of: filename) {
            pinned.remove(at: index)
        } else {
            pinned.append(filename)
        }
        pinnedNotes = pinned
    }

    static func renameMetadata(from old: String, to new: String) {
        pinnedNotes = pinnedNotes.map { $0 == old ? new : $0 }
        var opened = lastOpened
        if let date = opened.removeValue(forKey: old) { opened[new] = date }
        lastOpened = opened
        if currentNote == old { currentNote = new }
    }

    static func removeMetadata(for filename: String) {
        pinnedNotes = pinnedNotes.filter { $0 != filename }
        var opened = lastOpened
        opened.removeValue(forKey: filename)
        lastOpened = opened
        if currentNote == filename { currentNote = nil }
    }
}
