import AppKit

/// The floating note window. Non-activating, so it takes keyboard input without
/// making NotesOverlay the active app; hiding it hands focus straight back.
final class NotePanel: NSPanel {
    static let frameAutosaveName = "NotePanel"

    let textView: NoteTextView
    private let scrollView: NSScrollView
    private let footerLabel = NSTextField(labelWithString: "")

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

        center()
        _ = setFrameAutosaveName(Self.frameAutosaveName) // restores a saved frame immediately
        updateChrome()
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
    }

    func hide() {
        orderOut(nil)
    }

    /// Title = first non-empty line, footer = character count.
    func updateChrome() {
        let text = textView.string
        let noteTitle = NoteLibrary.title(of: text)
        title = noteTitle.count > 40 ? String(noteTitle.prefix(40)) + "…" : noteTitle

        let count = text.count
        footerLabel.stringValue = count == 1 ? "1 character" : "\(count) characters"
    }
}
