import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSMenuDelegate, NoteSwitcherDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NotePanel!
    private var library: NoteLibrary!
    /// The note currently in the editor.
    private var store: NoteStore?
    private let hotKey = HotKey()
    private let recorder = HotKeyRecorder()

    private var toggleItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        library = NoteLibrary(directoryURL: Settings.notesDirectory)
        library.prepare(legacyNotePath: Settings.legacyNotePath)
        library.onChange = { [weak self] in self?.refreshSwitcher() }
        library.startWatching()

        panel = NotePanel(fontSize: Settings.fontSize)
        panel.delegate = self
        panel.textView.delegate = self
        panel.textView.onDismiss = { [weak self] in self?.hidePanel() }
        panel.textView.onFontSizeChange = { Settings.fontSize = $0 }
        panel.textView.onSwitcher = { [weak self] in self?.toggleSwitcher() }
        panel.textView.onNewNote = { [weak self] in self?.createNote(titled: nil) }

        openInitialNote()

        installMainMenu()
        setupStatusItem()

        hotKey.onPressed = { [weak self] in self?.togglePanel() }
        registerHotKey(Settings.hotKey)

        // First run: nothing written yet, so show the empty note.
        if panel.textView.string.isEmpty, library.notes().count <= 1 { showPanel() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        commitCurrentNote()
    }

    // MARK: Notes

    private func openInitialNote() {
        let notes = library.notes()
        if let name = Settings.currentNote, let note = notes.first(where: { $0.filename == name }) {
            open(note.url)
        } else if let note = notes.first {
            open(note.url)
        } else {
            createNote(titled: nil)
        }
    }

    /// Loads `url` into the editor. Does not touch the switcher; callers decide.
    private func open(_ url: URL) {
        if let store, store.fileURL == url { return }
        commitCurrentNote()
        store?.discard()

        let newStore = NoteStore(url: url)
        let text = newStore.load()
        newStore.onExternalChange = { [weak self] text in self?.applyExternalText(text) }
        newStore.startWatching()
        store = newStore

        let textView = panel.textView
        textView.string = text
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        panel.updateChrome()

        Settings.currentNote = url.lastPathComponent
        Settings.markOpened(url.lastPathComponent)
    }

    private func createNote(titled title: String?) {
        do {
            let url = try library.create(title: title)
            open(url)
            panel.dismissSwitcher()
            showPanel()
        } catch {
            presentError("Could not create a note in \(library.directoryURL.path).", error)
        }
    }

    private func trash(_ note: NoteInfo) {
        let wasCurrent = store?.fileURL == note.url
        if wasCurrent {
            store?.discard()
            store = nil
        }
        do {
            try library.trash(note.url)
        } catch {
            presentError("Could not move “\(note.title)” to the Trash.", error)
            if wasCurrent { open(note.url) }
            return
        }
        if wasCurrent {
            if let next = library.notes().first {
                open(next.url)
            } else {
                createNote(titled: nil)
            }
        }
        refreshSwitcher()
    }

    /// Saves pending text and renames the file to match the note's first line.
    private func commitCurrentNote() {
        guard let store else { return }
        store.flush()
        let title = NoteLibrary.title(of: panel.textView.string)
        guard let target = library.urlMatchingTitle(for: store.fileURL, title: title) else { return }
        let old = store.fileURL.lastPathComponent
        do {
            try store.moveFile(to: target)
            Settings.renameMetadata(from: old, to: target.lastPathComponent)
        } catch {
            NSLog("NotesOverlay: could not rename \(old) to \(target.lastPathComponent): \(error)")
        }
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
        store?.scheduleSave(panel.textView.string)
    }

    // MARK: Switcher

    private func toggleSwitcher() {
        if panel.isSwitcherVisible {
            panel.dismissSwitcher()
        } else {
            panel.presentSwitcher(notes: library.notes(), current: store?.fileURL, delegate: self)
        }
    }

    private func refreshSwitcher() {
        guard panel.isSwitcherVisible else { return }
        panel.refreshSwitcher(notes: library.notes(), current: store?.fileURL)
    }

    func switcher(_ switcher: NoteSwitcherView, open note: NoteInfo) {
        open(note.url)
        panel.dismissSwitcher()
    }

    func switcher(_ switcher: NoteSwitcherView, createNoteTitled title: String?) {
        createNote(titled: title)
    }

    func switcher(_ switcher: NoteSwitcherView, trash note: NoteInfo) {
        trash(note)
    }

    func switcher(_ switcher: NoteSwitcherView, togglePin note: NoteInfo) {
        Settings.togglePin(note.filename)
        refreshSwitcher()
    }

    func switcherDidRequestClose(_ switcher: NoteSwitcherView) {
        panel.dismissSwitcher()
    }

    func switcherDidRequestHidePanel(_ switcher: NoteSwitcherView) {
        hidePanel()
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
        panel.dismissSwitcher()
        commitCurrentNote()
        panel.hide()
    }

    // NSWindowDelegate (panel only)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hidePanel()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        commitCurrentNote()
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

    /// Never shown (accessory app) but gives text fields a path for ⌘Z/⌘X/⌘C/⌘V/⌘A.
    /// Deliberately no ⌘Q: while the panel is key, ⌘Q would quit NotesOverlay even
    /// though another app looks frontmost.
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

        let switchItem = NSMenuItem(title: "Switch Note…", action: #selector(switchNoteFromMenu), keyEquivalent: "p")
        switchItem.target = self
        menu.addItem(switchItem)

        let newItem = NSMenuItem(title: "New Note", action: #selector(newNoteFromMenu), keyEquivalent: "n")
        newItem.target = self
        menu.addItem(newItem)

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

    @objc private func switchNoteFromMenu() {
        showPanel()
        if !panel.isSwitcherVisible { toggleSwitcher() }
    }

    @objc private func newNoteFromMenu() {
        createNote(titled: nil)
    }

    @objc private func revealNote() {
        commitCurrentNote()
        if let url = store?.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(library.directoryURL)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.toggle()
        } catch {
            presentError("Could not change Launch at Login.", error)
        }
        updateLaunchAtLoginItem()
    }

    private func presentError(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}
