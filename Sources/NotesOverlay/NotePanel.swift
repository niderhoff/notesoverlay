import AppKit

/// The floating note window. Non-activating, so it takes keyboard input without
/// making NotesOverlay the active app; hiding it hands focus straight back.
final class NotePanel: NSPanel {
    static let frameAutosaveName = "NotePanel"

    let textView: NoteTextView
    private let scrollView: NSScrollView

    /// Title-bar buttons (mouse controls, shown only while hovering).
    var onNewNoteButton: (() -> Void)?
    var onSwitcherButton: (() -> Void)?
    private let titlebarButtons = NSTitlebarAccessoryViewController()
    /// Our own title: regular weight, centred, always visible (the native one is bold and
    /// would be hidden with the rest of the chrome).
    private let titleLabel = PassThroughLabel(labelWithString: "Untitled")
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
        titleVisibility = .hidden // replaced by titleLabel below
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

        background.addSubview(scrollView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(titleLabel)

        // contentLayoutGuide excludes the (transparent) title bar.
        let guide = contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: guide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            // Centred in the title bar band, clear of the close button and the ⌘N/⌘P buttons.
            titleLabel.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: guide.topAnchor, constant: -14),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 72),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -72),
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
        // 24pt buttons, 2pt apart. Top/bottom insets make the row exactly the 28pt
        // title-bar height so the buttons (and their hover highlight) sit centred, with
        // the same breathing room above as to the right edge.
        let stack = NSStackView(views: [newButton, switchButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 3)
        stack.frame = NSRect(x: 0, y: 0, width: 53, height: 28)
        titlebarButtons.view = stack
        titlebarButtons.layoutAttribute = .trailing
        addTitlebarAccessoryViewController(titlebarButtons)
    }

    private func makeTitlebarButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))!
        let button = TitlebarButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    @objc private func newNoteTapped() { onNewNoteButton?() }
    @objc private func switcherTapped() { onSwitcherButton?() }

    /// Close button and the ⌘N/⌘P buttons are mouse controls: visible only while the
    /// pointer is over the window. The title stays; the strip stays draggable either way.
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

    /// Title = first non-empty line of the note.
    func updateChrome() {
        let full = NoteLibrary.title(of: textView.string)
        noteTitle = full.count > 40 ? String(full.prefix(40)) + "…" : full
        title = noteTitle // not drawn (titleVisibility = .hidden) but used by the system
        titleLabel.stringValue = noteTitle
    }
}

/// Borderless icon button for the title bar: reacts to the first click even when the
/// panel is not the key window, and shows a rounded highlight while hovered.
final class TitlebarButton: NSButton {
    private var hovered = false {
        didSet {
            contentTintColor = hovered ? .labelColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    /// No mouseExited arrives when the whole bar hides under the pointer.
    override func viewDidHide() {
        super.viewDidHide()
        hovered = false
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// A label that never intercepts the mouse, so the title bar stays draggable through it.
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
