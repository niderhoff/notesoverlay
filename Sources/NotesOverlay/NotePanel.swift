import AppKit

/// The floating note window. Non-activating, so it takes keyboard input without
/// making NotesOverlay the active app; hiding it hands focus straight back.
final class NotePanel: NSPanel {
    static let frameAutosaveName = "NotePanel"

    let textView: NoteTextView
    private let scrollView: NSScrollView
    private let footerLabel = NSTextField(labelWithString: "")

    /// Title-bar buttons (mouse controls, shown only while hovering).
    var onNewNoteButton: (() -> Void)?
    var onSwitcherButton: (() -> Void)?
    private let titlebarButtons = NSTitlebarAccessoryViewController()
    private var noteTitle = "Untitled"
    private(set) var isChromeVisible = false
    private var hoverTimer: Timer?

    init(fontSize: CGFloat) {
        let pair = NoteTextView.makeScrollable(fontSize: fontSize)
        scrollView = pair.scrollView
        textView = pair.textView

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isFloatingPanel = true
        hidesOnDeactivate = false // NSPanel default is true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        animationBehavior = .none // no fade/scale on show or hide
        minSize = NSSize(width: 320, height: 240)
        title = "Untitled"
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active // default follows "window active", which we never are
        contentView = background

        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.alignment = .center
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(scrollView)
        background.addSubview(footerLabel)

        // contentLayoutGuide excludes the (transparent) title bar.
        let guide = contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: guide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -4),
            footerLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            footerLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            footerLabel.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
        ])

        installTitlebarButtons()
        // .activeAlways: this app is never the active app, yet hover must still work.
        background.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))

        center()
        _ = setFrameAutosaveName(Self.frameAutosaveName) // restores a saved frame immediately
        updateChrome()
        applyChrome()
    }

    // MARK: Hover chrome

    private func installTitlebarButtons() {
        let newButton = makeTitlebarButton("square.and.pencil", tip: "New Note (⌘N)", action: #selector(newNoteTapped))
        let switchButton = makeTitlebarButton("list.bullet", tip: "Switch Note (⌘P)", action: #selector(switcherTapped))
        let stack = NSStackView(views: [newButton, switchButton])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        stack.frame = NSRect(x: 0, y: 0, width: 68, height: 28)
        titlebarButtons.view = stack
        titlebarButtons.layoutAttribute = .trailing
        addTitlebarAccessoryViewController(titlebarButtons)
    }

    private func makeTitlebarButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))!
        let button = FirstMouseButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    @objc private func newNoteTapped() { onNewNoteButton?() }
    @objc private func switcherTapped() { onSwitcherButton?() }

    /// Close button, title, and the ⌘N/⌘P buttons are mouse controls: visible only
    /// while the pointer is over the window. The strip stays draggable either way.
    func setChrome(visible: Bool) {
        guard visible != isChromeVisible else { return }
        isChromeVisible = visible
        applyChrome()
    }

    private func applyChrome() {
        let visible = isChromeVisible
        standardWindowButton(.closeButton)?.isHidden = !visible
        titlebarButtons.isHidden = !visible
        titlebarButtons.view.isHidden = !visible // the controller flag alone is not reliable
        title = visible ? noteTitle : ""
    }

    private func syncChromeWithMouse() {
        setChrome(visible: frame.contains(NSEvent.mouseLocation))
    }

    // Tracking-area events give instant response; the timer in show() is the
    // fallback in case AppKit withholds enter/exit events from a never-active app.
    override func mouseEntered(with event: NSEvent) {
        setChrome(visible: true)
    }

    override func mouseExited(with event: NSEvent) {
        setChrome(visible: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: Note switcher overlay

    private(set) var switcher: NoteSwitcherView?
    var isSwitcherVisible: Bool { switcher != nil }

    func presentSwitcher(notes: [NoteInfo], current: URL?, delegate: NoteSwitcherDelegate) {
        if let switcher {
            switcher.beginSession(notes: notes, current: current)
            return
        }
        guard let background = contentView else { return }
        let view = NoteSwitcherView(frame: background.bounds)
        view.delegate = delegate
        view.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(view)
        let guide = contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: background.topAnchor),
            view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            view.card.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
        ])
        switcher = view
        background.layoutSubtreeIfNeeded()
        view.beginSession(notes: notes, current: current)
    }

    func refreshSwitcher(notes: [NoteInfo], current: URL?) {
        switcher?.update(notes: notes, current: current)
    }

    func dismissSwitcher() {
        guard let switcher else { return }
        switcher.removeFromSuperview()
        self.switcher = nil
        makeFirstResponder(textView)
    }

    func show() {
        makeKeyAndOrderFront(nil)
        makeFirstResponder(textView)
        // No mouseEntered fires if the pointer is already inside when we appear.
        syncChromeWithMouse()
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.syncChromeWithMouse()
        }
    }

    func hide() {
        orderOut(nil)
        hoverTimer?.invalidate()
        hoverTimer = nil
        setChrome(visible: false)
    }

    /// Title = first non-empty line, footer = character count.
    func updateChrome() {
        let text = textView.string
        let full = NoteLibrary.title(of: text)
        noteTitle = full.count > 40 ? String(full.prefix(40)) + "…" : full
        if isChromeVisible { title = noteTitle }

        let count = text.count
        footerLabel.stringValue = count == 1 ? "1 character" : "\(count) characters"
    }
}

/// Reacts to the first click even when the panel is not the key window.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
