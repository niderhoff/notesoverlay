import AppKit

/// Plain-text editor for the note. Handles Esc and the ⌘ shortcuts itself because
/// the app is never the active app, so main-menu key equivalents may not be dispatched.
final class NoteTextView: NSTextView {
    /// Esc, ⌘W, or anything else that should hide the panel.
    var onDismiss: (() -> Void)?
    var onFontSizeChange: ((CGFloat) -> Void)?

    private static let minFontSize: CGFloat = 9
    private static let maxFontSize: CGFloat = 48

    /// Builds the scroll view + text view pair with the standard wrapping setup.
    static func makeScrollable(fontSize: CGFloat) -> (scrollView: NSScrollView, textView: NoteTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        // Strictly plain text, no "smart" rewriting of what was typed.
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.applyFontSize(fontSize)

        scrollView.documentView = textView
        return (scrollView, textView)
    }

    // MARK: Keys

    /// Esc. Bound by the standard key bindings to `cancelOperation:`; NSTextView
    /// only turns an *unhandled* one into autocompletion.
    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch (key, mods) {
        case ("c", [.command]): copy(nil)
        case ("v", [.command]): paste(nil)
        case ("x", [.command]): cut(nil)
        case ("a", [.command]): selectAll(nil)
        case ("z", [.command]): undoManager?.undo()
        case ("z", [.command, .shift]): undoManager?.redo()
        case ("w", [.command]): onDismiss?()
        case ("f", [.command]): performFind(.showFindPanel)
        case ("g", [.command]): performFind(.next)
        case ("g", [.command, .shift]): performFind(.previous)
        // "+" is its own key on e.g. German layouts, "=" on US layouts.
        case ("+", _), ("=", _): adjustFontSize(by: 1)
        case ("-", [.command]): adjustFontSize(by: -1)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func performFind(_ action: NSFindPanelAction) {
        let sender = NSMenuItem()
        sender.tag = Int(action.rawValue)
        performFindPanelAction(sender)
    }

    // MARK: Font size

    func applyFontSize(_ size: CGFloat) {
        let newFont = NSFont.systemFont(ofSize: size)
        font = newFont // plain-text mode: applies to all text
        typingAttributes[.font] = newFont
    }

    private func adjustFontSize(by delta: CGFloat) {
        let current = font?.pointSize ?? 16
        let size = min(Self.maxFontSize, max(Self.minFontSize, current + delta))
        guard size != current else { return }
        applyFontSize(size)
        onFontSizeChange?(size)
    }
}
