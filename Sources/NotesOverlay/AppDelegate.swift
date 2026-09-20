import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NotePanel!
    private var store: NoteStore!
    private let hotKey = HotKey()
    private let recorder = HotKeyRecorder()

    private var toggleItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = NoteStore(path: Settings.notePath)
        let initialText = store.load()

        panel = NotePanel(fontSize: Settings.fontSize)
        panel.delegate = self
        panel.textView.delegate = self
        panel.textView.string = initialText
        panel.updateChrome()
        panel.textView.onDismiss = { [weak self] in self?.hidePanel() }
        panel.textView.onFontSizeChange = { Settings.fontSize = $0 }

        store.onExternalChange = { [weak self] text in self?.applyExternalText(text) }
        store.startWatching()

        installMainMenu()
        setupStatusItem()

        hotKey.onPressed = { [weak self] in self?.togglePanel() }
        registerHotKey(Settings.hotKey)

        // First run: show the empty note so there is something to see.
        if initialText.isEmpty { showPanel() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
    }

    // MARK: Panel

    @objc private func togglePanel() {
        // Visible but unfocused (user clicked elsewhere) → focus it; focused → hide.
        if panel.isVisible && panel.isKeyWindow {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        panel.show()
    }

    private func hidePanel() {
        store.flush()
        panel.hide()
    }

    private func applyExternalText(_ text: String) {
        let textView = panel.textView
        let caret = textView.selectedRange().location
        textView.string = text // does not post textDidChange → no save loop
        textView.setSelectedRange(NSRange(location: min(caret, (text as NSString).length), length: 0))
        textView.undoManager?.removeAllActions() // stale ranges would crash on undo
        panel.updateChrome()
    }

    // NSTextViewDelegate
    func textDidChange(_ notification: Notification) {
        panel.updateChrome()
        store.scheduleSave(panel.textView.string)
    }

    // NSWindowDelegate (panel only)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hidePanel()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        store.flush()
    }

    func windowDidMove(_ notification: Notification) {
        panel.saveFrame(usingName: NotePanel.frameAutosaveName)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        panel.saveFrame(usingName: NotePanel.frameAutosaveName)
    }

    // MARK: Hotkey

    private func registerHotKey(_ combo: HotKeyCombo) {
        let status = hotKey.register(combo)
        if status == noErr {
            Settings.hotKey = combo
            updateToggleItem()
            return
        }

        // Keep whatever worked before, then tell the user.
        let saved = Settings.hotKey
        if saved != combo { hotKey.register(saved) }

        let alert = NSAlert()
        alert.messageText = "Could not register \(combo.label)"
        alert.informativeText = status == OSStatus(eventHotKeyExistsErr)
            ? "That shortcut is already taken by another app or by macOS. Choose a different one."
            : "macOS returned error \(status)."
        alert.addButton(withTitle: "Change Hotkey…")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            changeHotKey()
        }
    }

    @objc private func changeHotKey() {
        hotKey.unregister()
        recorder.present(current: Settings.hotKey) { [weak self] combo in
            guard let self else { return }
            self.registerHotKey(combo ?? Settings.hotKey)
        }
    }

    // MARK: Menus

    /// Never shown (accessory app) but gives the text view a second path for
    /// ⌘Z/⌘X/⌘C/⌘V/⌘A. Deliberately no ⌘Q: while the panel is key, ⌘Q would quit
    /// NotesOverlay even though another app looks frontmost.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "NotesOverlay")
        mainMenu.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "NotesOverlay")
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        toggleItem = NSMenuItem(title: "Show Note", action: #selector(togglePanel), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let reveal = NSMenuItem(title: "Reveal Note in Finder", action: #selector(revealNote), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())

        let change = NSMenuItem(title: "Change Hotkey…", action: #selector(changeHotKey), keyEquivalent: "")
        change.target = self
        menu.addItem(change)

        launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit NotesOverlay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)

        statusItem.menu = menu
        updateToggleItem()
        updateLaunchAtLoginItem()
    }

    // NSMenuDelegate: refresh state each time the status menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateToggleItem()
        updateLaunchAtLoginItem()
    }

    private func updateToggleItem() {
        guard let toggleItem else { return }
        toggleItem.title = (panel?.isVisible ?? false) ? "Hide Note" : "Show Note"
        let combo = Settings.hotKey
        toggleItem.keyEquivalent = combo.keyEquivalent
        toggleItem.keyEquivalentModifierMask = combo.modifiers
    }

    private func updateLaunchAtLoginItem() {
        guard let launchAtLoginItem else { return }
        launchAtLoginItem.isEnabled = LaunchAtLogin.isAvailable
        launchAtLoginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        launchAtLoginItem.toolTip = LaunchAtLogin.isAvailable ? nil : "Install to /Applications first (make install)"
    }

    @objc private func revealNote() {
        store.flush()
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.toggle()
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
        updateLaunchAtLoginItem()
    }
}
