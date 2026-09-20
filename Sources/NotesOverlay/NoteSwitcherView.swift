import AppKit
import Carbon

protocol NoteSwitcherDelegate: AnyObject {
    func switcher(_ switcher: NoteSwitcherView, open note: NoteInfo)
    func switcher(_ switcher: NoteSwitcherView, createNoteTitled title: String?)
    func switcher(_ switcher: NoteSwitcherView, trash note: NoteInfo)
    func switcher(_ switcher: NoteSwitcherView, togglePin note: NoteInfo)
    func switcherDidRequestClose(_ switcher: NoteSwitcherView)
    func switcherDidRequestHidePanel(_ switcher: NoteSwitcherView)
}

/// ⌘P overlay drawn over the editor: fuzzy search over all notes, ↑↓ + ↩ to switch,
/// ↩ on an unmatched query creates that note.
final class NoteSwitcherView: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: NoteSwitcherDelegate?

    static let rowHeight: CGFloat = 56
    static let maxVisibleRows = 6

    private enum Row {
        case note(NoteInfo)
        case create(String)
    }

    let card = NSVisualEffectView()
    private let searchField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No notes yet. Type a title and press ↩.")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var tableHeight: NSLayoutConstraint!

    private var allNotes: [NoteInfo] = []
    private var currentURL: URL?
    private var rows: [Row] = []
    private var selectedIndex = 0
    /// Index of the highlighted row (read-only, for tests and debugging).
    var selectedRowIndex: Int { selectedIndex }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: API

    /// Fresh session: empty query, focus in the search field, and the previously used
    /// note preselected so ⌘P ↩ toggles between two notes.
    func beginSession(notes: [NoteInfo], current: URL?) {
        allNotes = notes
        currentURL = current
        searchField.stringValue = ""
        applyFilter(preferredSelection: nil)
        window?.makeFirstResponder(searchField)
    }

    /// Re-lists after the library changed; keeps the query and selection.
    func update(notes: [NoteInfo], current: URL?) {
        allNotes = notes
        currentURL = current
        applyFilter(preferredSelection: selectedIndex)
    }

    // MARK: UI

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor

        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        updateBorderColor()

        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 17)
        searchField.placeholderString = "Search for notes…"
        searchField.lineBreakMode = .byTruncatingTail
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Notes")
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let info = NSButton(
            image: NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Shortcuts")!,
            target: nil,
            action: nil
        )
        info.isBordered = false
        info.contentTintColor = .labelColor
        info.toolTip = "↑ ↓ select    ↩ open or create    ⌘N new note    ⌘⇧P pin    ⌘⌫ move to Trash    esc close"
        info.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.refusesFirstResponder = true
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [searchField, separator, header, countLabel, info, scrollView, emptyLabel] {
            card.addSubview(view)
        }

        tableHeight = scrollView.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        tableHeight.priority = .defaultHigh // yields when the window is too small

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),

            searchField.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            header.centerYAnchor.constraint(equalTo: separator.bottomAnchor, constant: 24),

            info.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            info.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            info.widthAnchor.constraint(equalToConstant: 22),
            info.heightAnchor.constraint(equalToConstant: 22),

            countLabel.trailingAnchor.constraint(equalTo: info.leadingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            tableHeight,

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// Click on the dimmed area outside the card closes the switcher.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(point) {
            delegate?.switcherDidRequestClose(self)
        }
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if mods == [.command], Int(event.keyCode) == kVK_Delete {
            if case .note(let note)? = selectedRow { delegate?.switcher(self, trash: note) }
            return true
        }
        switch (key, mods) {
        case ("p", [.command]):
            delegate?.switcherDidRequestClose(self)
        case ("p", [.command, .shift]):
            if case .note(let note)? = selectedRow { delegate?.switcher(self, togglePin: note) }
        case ("n", [.command]):
            delegate?.switcher(self, createNoteTitled: query.isEmpty ? nil : query)
        case ("w", [.command]):
            delegate?.switcherDidRequestHidePanel(self)
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    // NSTextFieldDelegate
    func controlTextDidChange(_ obj: Notification) {
        applyFilter(preferredSelection: 0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            select(selectedIndex - 1)
        case #selector(NSResponder.moveDown(_:)):
            select(selectedIndex + 1)
        case #selector(NSResponder.insertNewline(_:)):
            activateSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            delegate?.switcherDidRequestClose(self)
        default:
            return false
        }
        return true
    }

    // MARK: Filtering & selection

    private var query: String {
        searchField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private var selectedRow: Row? {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }

    /// `preferredSelection` nil = the previously opened note (see `previousNoteIndex`).
    private func applyFilter(preferredSelection: Int?) {
        let q = query
        let matches: [NoteInfo]
        if q.isEmpty {
            matches = allNotes
        } else {
            matches = allNotes
                .compactMap { note in
                    Fuzzy.score(query: q, title: note.title, content: note.searchText).map { (note, $0) }
                }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : NoteLibrary.defaultOrder($0.0, $1.0) }
                .map { $0.0 }
        }

        rows = matches.map(Row.note)
        if !q.isEmpty, !matches.contains(where: { $0.title.caseInsensitiveCompare(q) == .orderedSame }) {
            rows.append(.create(q))
        }

        countLabel.stringValue = q.isEmpty
            ? "\(allNotes.count) \(allNotes.count == 1 ? "Note" : "Notes")"
            : "\(matches.count)/\(allNotes.count) Notes"
        emptyLabel.isHidden = !rows.isEmpty
        tableHeight.constant = CGFloat(max(1, min(rows.count, Self.maxVisibleRows))) * Self.rowHeight
        tableView.reloadData()

        select(preferredSelection ?? previousNoteIndex())
    }

    /// The most recently opened note other than the current one, so ⌘P ↩ goes back.
    private func previousNoteIndex() -> Int {
        var best: (index: Int, date: Date)?
        for (index, row) in rows.enumerated() {
            guard case .note(let note) = row, note.url != currentURL else { continue }
            let date = note.lastOpened ?? .distantPast
            if best == nil || date > best!.date { best = (index, date) }
        }
        return best?.index ?? 0
    }

    private func select(_ index: Int) {
        guard !rows.isEmpty else {
            selectedIndex = 0
            tableView.deselectAll(nil)
            return
        }
        selectedIndex = min(max(index, 0), rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
    }

    private func activateSelected() {
        guard let row = selectedRow else {
            if !query.isEmpty { delegate?.switcher(self, createNoteTitled: query) }
            return
        }
        switch row {
        case .note(let note): delegate?.switcher(self, open: note)
        case .create(let title): delegate?.switcher(self, createNoteTitled: title)
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        selectedIndex = row
        activateSelected()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SwitcherRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SwitcherCellView ?? {
            let cell = SwitcherCellView()
            cell.identifier = id
            return cell
        }()
        switch rows[row] {
        case .note(let note):
            cell.configure(note: note, isCurrent: note.url == currentURL)
            cell.onPin = { [weak self] in
                guard let self else { return }
                self.delegate?.switcher(self, togglePin: note)
            }
            cell.onTrash = { [weak self] in
                guard let self else { return }
                self.delegate?.switcher(self, trash: note)
            }
        case .create(let title):
            cell.configureCreate(title: title)
        }
        cell.setSelected(row == selectedIndex)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if tableView.selectedRow >= 0 { selectedIndex = tableView.selectedRow }
        tableView.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? SwitcherCellView)?.setSelected(row == self.selectedIndex)
        }
    }
}

/// Rounded selection highlight instead of the full-width system one.
final class SwitcherRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 10, yRadius: 10).fill()
    }
}

/// Title, metadata line, and pin/trash buttons that show on the selected row.
final class SwitcherCellView: NSTableCellView {
    var onPin: (() -> Void)?
    var onTrash: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let pinButton = NSButton()
    private let trashButton = NSButton()
    private var isPinned = false
    private var isCreateRow = false

    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

    init() {
        super.init(frame: .zero)

        titleLabel.font = .systemFont(ofSize: 15)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        for button in [pinButton, trashButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.target = self
        }
        pinButton.action = #selector(pinTapped)
        trashButton.action = #selector(trashTapped)
        trashButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Move to Trash")?
            .withSymbolConfiguration(Self.symbolConfiguration)
        trashButton.toolTip = "Move to Trash (⌘⌫)"

        for view in [titleLabel, subtitleLabel, pinButton, trashButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -8),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -8),

            trashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trashButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            trashButton.widthAnchor.constraint(equalToConstant: 24),
            trashButton.heightAnchor.constraint(equalToConstant: 24),

            pinButton.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -8),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 24),
            pinButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    func configure(note: NoteInfo, isCurrent: Bool) {
        isCreateRow = false
        isPinned = note.pinned
        titleLabel.stringValue = note.title
        subtitleLabel.attributedStringValue = Self.subtitle(for: note, isCurrent: isCurrent)
        pinButton.image = NSImage(systemSymbolName: note.pinned ? "pin.fill" : "pin", accessibilityDescription: nil)?
            .withSymbolConfiguration(Self.symbolConfiguration)
        pinButton.toolTip = note.pinned ? "Unpin (⌘⇧P)" : "Pin (⌘⇧P)"
    }

    func configureCreate(title: String) {
        isCreateRow = true
        isPinned = false
        titleLabel.stringValue = "Create “\(title)”"
        subtitleLabel.attributedStringValue = NSAttributedString(string: "New note", attributes: Self.subtitleAttributes)
    }

    func setSelected(_ selected: Bool) {
        trashButton.isHidden = isCreateRow || !selected
        pinButton.isHidden = isCreateRow || !(selected || isPinned)
    }

    @objc private func pinTapped() { onPin?() }
    @objc private func trashTapped() { onTrash?() }

    // MARK: Subtitle

    private static let subtitleAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.secondaryLabelColor,
        .font: NSFont.systemFont(ofSize: 13),
    ]

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    private static func relative(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? "just now" : relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static func subtitle(for note: NoteInfo, isCurrent: Bool) -> NSAttributedString {
        let count = "\(note.characterCount) \(note.characterCount == 1 ? "character" : "characters")"
        let result = NSMutableAttributedString()
        if isCurrent {
            result.append(NSAttributedString(string: "● ", attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: NSFont.systemFont(ofSize: 9),
                .baselineOffset: 1.5,
            ]))
            result.append(NSAttributedString(string: "Current • \(count)", attributes: subtitleAttributes))
        } else if let opened = note.lastOpened {
            result.append(NSAttributedString(string: "Opened \(relative(opened)) • \(count)", attributes: subtitleAttributes))
        } else {
            result.append(NSAttributedString(string: "Edited \(relative(note.modified)) • \(count)", attributes: subtitleAttributes))
        }
        return result
    }
}
