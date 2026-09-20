import AppKit
import Carbon

/// Display strings for a recorded key event.
enum KeyLabel {
    static func modifierSymbols(_ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s
    }

    private static let specialNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Characters NSMenuItem.keyEquivalent understands for non-printing keys.
    private static let specialEquivalents: [Int: Int] = [
        kVK_Space: 0x20, kVK_Return: 0x0D, kVK_ANSI_KeypadEnter: 0x03, kVK_Tab: 0x09,
        kVK_Delete: 0x08, kVK_ForwardDelete: NSDeleteFunctionKey, kVK_Escape: 0x1B,
        kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
        kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
        kVK_Home: NSHomeFunctionKey, kVK_End: NSEndFunctionKey,
        kVK_PageUp: NSPageUpFunctionKey, kVK_PageDown: NSPageDownFunctionKey,
        kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey,
        kVK_F4: NSF4FunctionKey, kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey,
        kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey, kVK_F9: NSF9FunctionKey,
        kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
    ]

    static func keyName(for event: NSEvent) -> String {
        if let name = specialNames[Int(event.keyCode)] { return name }
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty { return chars.uppercased() }
        return "Key \(event.keyCode)"
    }

    static func keyEquivalent(for event: NSEvent) -> String {
        if let code = specialEquivalents[Int(event.keyCode)], let scalar = Unicode.Scalar(UInt32(code)) {
            return String(Character(scalar))
        }
        return event.charactersIgnoringModifiers?.lowercased() ?? ""
    }

    static func combo(for event: NSEvent, modifiers: NSEvent.ModifierFlags) -> HotKeyCombo {
        HotKeyCombo(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            label: modifierSymbols(modifiers) + keyName(for: event),
            keyEquivalent: keyEquivalent(for: event)
        )
    }
}

/// Small window that captures the next key combination.
final class HotKeyRecorder: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var completion: ((HotKeyCombo?) -> Void)?

    /// `completion(nil)` means cancelled. The caller must unregister the live
    /// hotkey before presenting, otherwise the current combo can't be re-recorded.
    func present(current: HotKeyCombo, completion: @escaping (HotKeyCombo?) -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        self.completion = completion

        let recorder = RecorderView(current: current)
        recorder.onResult = { [weak self] combo in self?.finish(with: combo) }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Change Hotkey"
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.delegate = self
        w.contentView = recorder
        w.center()
        window = w

        // A regular window needs the app active to receive keyboard focus.
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        w.makeFirstResponder(recorder)
    }

    private func finish(with combo: HotKeyCombo?) {
        guard let w = window else { return }
        let done = completion
        completion = nil
        window = nil
        w.delegate = nil
        w.orderOut(nil)
        done?(combo)
    }

    /// Red close button → cancel.
    func windowWillClose(_ notification: Notification) {
        let done = completion
        completion = nil
        window = nil
        done?(nil)
    }
}

final class RecorderView: NSView {
    var onResult: ((HotKeyCombo?) -> Void)?

    private let current: HotKeyCombo
    private let comboLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")

    init(current: HotKeyCombo) {
        self.current = current
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 180))

        let prompt = NSTextField(labelWithString: "Press the new shortcut")
        prompt.font = .systemFont(ofSize: 13, weight: .semibold)
        prompt.alignment = .center

        comboLabel.font = .systemFont(ofSize: 26, weight: .medium)
        comboLabel.alignment = .center
        comboLabel.textColor = .secondaryLabelColor
        comboLabel.stringValue = current.label

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.stringValue = "Include ⌃, ⌥ or ⌘.  Esc cancels, ⌫ restores \(HotKeyCombo.default.label)."

        let stack = NSStackView(views: [prompt, comboLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }

    /// Runs before the hidden main menu gets a chance at ⌘-combos, so every key
    /// reaches the recorder.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        handle(event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(HotKeyCombo.relevantModifiers)
        comboLabel.stringValue = mods.isEmpty ? current.label : KeyLabel.modifierSymbols(mods)
        comboLabel.textColor = mods.isEmpty ? .secondaryLabelColor : .labelColor
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(HotKeyCombo.relevantModifiers)
        let code = Int(event.keyCode)

        if mods.isEmpty, code == kVK_Escape {
            onResult?(nil)
            return
        }
        if mods.isEmpty, code == kVK_Delete || code == kVK_ForwardDelete {
            onResult?(.default)
            return
        }
        guard !mods.intersection([.control, .option, .command]).isEmpty else {
            NSSound.beep()
            hintLabel.stringValue = "A global shortcut needs ⌃, ⌥ or ⌘. Try again."
            hintLabel.textColor = .systemOrange
            return
        }
        onResult?(KeyLabel.combo(for: event, modifiers: mods))
    }
}
