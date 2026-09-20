import AppKit

extension NSAttributedString.Key {
    /// Marker characters hidden on rendered lines (transparent, collapsed to zero width).
    static let markdownHidden = NSAttributedString.Key("NotesOverlay.markdownHidden")
    /// A one-character String to draw instead of the character (e.g. "•" for "-").
    static let markdownGlyph = NSAttributedString.Key("NotesOverlay.markdownGlyph")
    /// Paragraph belongs to a fenced code block: MarkdownLayoutManager draws a full-width band.
    static let markdownCodeBlock = NSAttributedString.Key("NotesOverlay.markdownCodeBlock")
    /// The "[" of a task item, drawn as a checkbox (value: Bool, checked). The character is
    /// made transparent and widened with kerning; the box is painted over its cell.
    static let markdownCheckbox = NSAttributedString.Key("NotesOverlay.markdownCheckbox")
}

/// Draws a full-width background band behind fenced code blocks and paints task checkboxes.
final class MarkdownLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.markdownCheckbox, in: charRange, options: []) { value, range, _ in
            guard let checked = value as? Bool else { return }
            let glyphIndex = glyphIndexForCharacter(at: range.location)
            guard glyphIndex < numberOfGlyphs else { return }
            let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 16)
            let side = MarkdownStyler.checkboxSide(for: font.pointSize)
            let fragment = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let glyphOrigin = location(forGlyphAt: glyphIndex)
            let x = origin.x + fragment.minX + glyphOrigin.x
            let baseline = origin.y + fragment.minY + glyphOrigin.y
            let box = NSRect(x: x, y: baseline - font.capHeight - (side - font.capHeight) / 2, width: side, height: side)
            Self.drawCheckbox(in: box, checked: checked, color: .controlAccentColor)
        }
    }

    private static func drawCheckbox(in box: NSRect, checked: Bool, color: NSColor) {
        let stroke: CGFloat = max(1.5, box.width * 0.12)
        let outline = NSBezierPath(roundedRect: box.insetBy(dx: stroke / 2, dy: stroke / 2),
                                   xRadius: box.width * 0.28, yRadius: box.width * 0.28)
        outline.lineWidth = stroke
        color.setStroke()
        outline.stroke()
        if checked {
            // Same outline, plus a smaller filled rounded square inside.
            let inset = box.width * 0.3
            let inner = box.insetBy(dx: inset, dy: inset)
            color.setFill()
            NSBezierPath(roundedRect: inner, xRadius: inner.width * 0.25, yRadius: inner.width * 0.25).fill()
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let container = textContainers.first {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            var glyphIndex = glyphsToShow.location
            while glyphIndex < NSMaxRange(glyphsToShow) {
                var fragmentRange = NSRange()
                let fragment = lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragmentRange)
                let charIndex = characterIndexForGlyph(at: glyphIndex)
                if charIndex < storage.length,
                   storage.attribute(.markdownCodeBlock, at: charIndex, effectiveRange: nil) != nil {
                    NSRect(x: origin.x, y: fragment.minY + origin.y, width: container.size.width, height: fragment.height).fill()
                }
                if fragmentRange.length == 0 { break }
                glyphIndex = NSMaxRange(fragmentRange)
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

/// Live Markdown rendering that never touches the characters: the text storage stays
/// raw Markdown (so saving, copying and pasting are raw), and this object only applies
/// attributes. Syntax markers are hidden through the layout manager's glyph generation
/// except on the paragraphs the selection touches, which show the raw source.
final class MarkdownStyler: NSObject, NSTextStorageDelegate, NSLayoutManagerDelegate {
    private weak var textView: NSTextView?
    var baseFontSize: CGFloat {
        didSet { if baseFontSize != oldValue { restyleAll() } }
    }

    private var lastActiveParagraphs = NSRange(location: NSNotFound, length: 0)
    private var isRestyling = false
    private var insideProcessEditing = false

    init(textView: NSTextView, fontSize: CGFloat) {
        self.textView = textView
        baseFontSize = fontSize
        super.init()
    }

    func attach() {
        textView?.textStorage?.delegate = self
        textView?.layoutManager?.delegate = self
    }

    // MARK: Triggers

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        insideProcessEditing = true
        restyleAll()
        insideProcessEditing = false
    }

    /// Call whenever the selection settles; re-renders when the raw paragraph changes.
    func selectionDidChange() {
        guard let textView, let storage = textView.textStorage else { return }
        if activeParagraph(in: storage.string as NSString, of: textView) != lastActiveParagraphs { restyleAll() }
    }

    /// The paragraph holding the caret (the moving end of a selection) is shown raw.
    /// Only that one: a multi-line selection keeps its rendering, so nothing shifts
    /// while dragging or pressing ⇧↓, and Select All + copy still yields raw Markdown.
    private func activeParagraph(in text: NSString, of textView: NSTextView) -> NSRange {
        let selection = textView.selectedRange()
        let caret = textView.selectionAffinity == .upstream ? selection.location : NSMaxRange(selection)
        return text.paragraphRange(for: NSRange(location: min(max(caret, 0), text.length), length: 0))
    }

    // MARK: Fonts & colours

    private var baseFont: NSFont { .systemFont(ofSize: baseFontSize) }
    private var codeFont: NSFont { .monospacedSystemFont(ofSize: baseFontSize * 0.9, weight: .regular) }
    private var codeBackground: NSColor { .labelColor.withAlphaComponent(0.08) }
    /// Markers on the raw (caret) line: readable, but clearly not content.
    private var markerColor: NSColor { .secondaryLabelColor }
    private var bulletFont: NSFont { .boldSystemFont(ofSize: baseFontSize) }
    /// List markers (bullets, checkboxes, numbers) follow the system accent colour.
    private var listColor: NSColor { .controlAccentColor }

    private func headingFont(level: Int) -> NSFont {
        let scale: CGFloat = [1.5, 1.3, 1.15, 1.0, 1.0, 1.0][min(max(level, 1), 6) - 1]
        return .boldSystemFont(ofSize: (baseFontSize * scale).rounded())
    }

    private func adding(_ trait: NSFontTraitMask, to font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: trait)
    }

    /// Width of the column that holds a list marker (bullet, checkbox, number); the item's
    /// text starts right after it, so all list kinds align.
    private var listMarkerArea: CGFloat { (baseFontSize * 1.6).rounded() }
    static func checkboxSide(for fontSize: CGFloat) -> CGFloat { (fontSize * 0.95).rounded() }
    /// Extra space after each list item (also on the raw line, so nothing jumps).
    private var listParagraphSpacing: CGFloat { (baseFontSize * 0.6).rounded() }
    /// Horizontal step per nesting level (2 spaces or 1 tab in the source).
    private var listIndentStep: CGFloat { (baseFontSize * 1.4).rounded() }

    /// Bullets cycle by depth: • ○ ▪, skipping glyphs the system font lacks.
    private lazy var bulletGlyphs: [String] = {
        let probe = NSFont.boldSystemFont(ofSize: 16)
        let available = ["•", "◦", "▪"].filter { Self.glyph(for: $0, in: probe) != nil }
        return available.isEmpty ? ["•"] : available
    }()

    private func bulletGlyph(level: Int) -> String { bulletGlyphs[level % bulletGlyphs.count] }

    private static func listLevel(of indent: Substring) -> Int {
        var tabs = 0, spaces = 0
        for ch in indent { if ch == "\t" { tabs += 1 } else { spaces += 1 } }
        return tabs + spaces / 2
    }

    /// Body text breathes a little: extra space between lines, and a blank line
    /// separates blocks by a full extra font size.
    private var lineSpacing: CGFloat { (baseFontSize * 0.3).rounded() }
    private var blankLineSpacing: CGFloat { baseFontSize.rounded() }

    private func baseParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return style
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: baseParagraphStyle()]
    }

    // MARK: Restyle

    func restyleAll() {
        guard !isRestyling, let textView, let storage = textView.textStorage else { return }
        isRestyling = true
        defer { isRestyling = false }

        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        let active = activeParagraph(in: text, of: textView)
        lastActiveParagraphs = active

        let batch = !insideProcessEditing
        if batch { storage.beginEditing() }
        storage.setAttributes(baseAttributes(), range: full)

        var inCodeBlock = false
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            var content = paragraph
            while content.length > 0, Self.isNewline(text.character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            let isActive = active.location >= paragraph.location && active.location <= NSMaxRange(content)
            style(paragraph: paragraph, content: content, text: text, storage: storage, active: isActive, inCodeBlock: &inCodeBlock)
            if paragraph.length == 0 { break }
            location = NSMaxRange(paragraph)
        }
        if batch { storage.endEditing() }

        // Not during the storage's own edit processing: NSTextView's setter consults the
        // selection, which may still point into text that was just deleted → NSRangeException
        // (caught by AppKit, leaving the view frozen). The selection-change path runs
        // right after every edit and sets them then.
        if !insideProcessEditing { textView.typingAttributes = baseAttributes() }
        // Hidden/substituted glyphs are decided at glyph generation, so when the
        // raw/rendered split moves (selection change, zoom) the glyphs must be rebuilt.
        // Inside the storage's own edit processing TextKit does that itself.
        if !insideProcessEditing, let layoutManager = textView.layoutManager {
            layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        }
        textView.window?.invalidateCursorRects(for: textView) // checkbox hand cursors moved
    }

    private static func isNewline(_ c: unichar) -> Bool {
        c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029
    }

    /// Hides `range`: each glyph is drawn transparent and given a kern of minus its own
    /// advance, so it takes no width. Per character, because a single large negative kern
    /// would give one glyph a negative advance that the typesetter clamps to zero. (Null
    /// glyphs would be cleaner, but at a paragraph start followed by a kerned glyph the
    /// typesetter absorbs them into the previous line and lays the rest out as a
    /// continuation line.)
    private func hide(_ range: NSRange, storage: NSTextStorage, text: NSString) {
        guard range.length > 0 else { return }
        let font = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? baseFont
        storage.addAttributes([.markdownHidden: true, .foregroundColor: NSColor.clear], range: range)
        for index in range.location..<NSMaxRange(range) {
            let one = NSRange(location: index, length: 1)
            let advance = text.substring(with: one).size(withAttributes: [.font: font]).width
            storage.addAttribute(.kern, value: -advance, range: one)
        }
    }

    // MARK: Block level

    /// A line that is only a fence (2+ backticks or 3+ tildes) plus an optional language.
    private static let fence = try! NSRegularExpression(pattern: #"^[ \t]*(`{2,}|~{3,})[ \t]*([A-Za-z0-9_+#.-]*)[ \t]*$"#)
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+"#)
    private static let task = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t](\[)([ xX])(\])[ \t]+"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+])[ \t]+"#)
    private static let ordered = try! NSRegularExpression(pattern: #"^([ \t]*)(\d{1,3}[.)])[ \t]+"#)
    private static let quote = try! NSRegularExpression(pattern: #"^[ \t]*>[ \t]?"#)
    private static let rule = try! NSRegularExpression(pattern: #"^[ \t]*([-*_])[ \t]*(\1[ \t]*){2,}$"#)

    private func style(paragraph: NSRange, content: NSRange, text: NSString, storage: NSTextStorage,
                       active: Bool, inCodeBlock: inout Bool) {
        let line = text.substring(with: content)
        let lineRange = NSRange(location: 0, length: content.length)
        let offset = content.location
        var contentStart = 0
        var contentFont = baseFont
        let paragraphStyle = baseParagraphStyle()
        if content.length == 0 { paragraphStyle.paragraphSpacing = blankLineSpacing }

        func absolute(_ r: NSRange) -> NSRange { NSRange(location: r.location + offset, length: r.length) }
        func marker(_ r: NSRange, font: NSFont? = nil) {
            guard r.length > 0 else { return }
            let abs = absolute(r)
            if let font { storage.addAttribute(.font, value: font, range: abs) }
            if active {
                storage.addAttribute(.foregroundColor, value: markerColor, range: abs)
            } else {
                hide(abs, storage: storage, text: text)
            }
        }
        func width(_ s: String, _ font: NSFont) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }

        if let m = Self.fence.firstMatch(in: line, range: lineRange) {
            inCodeBlock.toggle()
            storage.addAttributes([.font: codeFont, .foregroundColor: markerColor, .markdownCodeBlock: true], range: paragraph)
            marker(m.range(at: 1), font: codeFont) // rendered: only the language label stays
            return
        }
        if inCodeBlock {
            storage.addAttributes([.font: codeFont, .markdownCodeBlock: true], range: paragraph)
            return
        }

        if let m = Self.heading.firstMatch(in: line, range: lineRange) {
            let level = m.range(at: 1).length
            contentFont = headingFont(level: level)
            storage.addAttribute(.font, value: contentFont, range: absolute(lineRange))
            marker(m.range, font: contentFont)
            paragraphStyle.paragraphSpacingBefore = baseFontSize * (level <= 2 ? 0.6 : 0.3)
            paragraphStyle.paragraphSpacing = baseFontSize * 0.35
            contentStart = m.range.length
        } else if let m = Self.task.firstMatch(in: line, range: lineRange) {
            let indentText = line.prefix(m.range(at: 1).length)
            let rawIndentWidth = width(String(indentText), baseFont)
            let levelIndent = CGFloat(Self.listLevel(of: indentText)) * listIndentStep
            let spaceWidth = width(" ", baseFont)
            let checked = line[Range(m.range(at: 4), in: line)!].lowercased() == "x"
            let bracket = m.range(at: 3)
            paragraphStyle.paragraphSpacing = listParagraphSpacing
            marker(NSRange(location: m.range(at: 2).location, length: 2)) // "- "
            if active {
                let raw = NSRange(location: bracket.location, length: 3) // "[ ]"
                marker(raw)
                storage.addAttribute(.foregroundColor, value: listColor, range: absolute(raw))
                paragraphStyle.headIndent = width(String(line.prefix(m.range.length)), baseFont)
            } else {
                // "[" becomes a transparent cell as wide as the box; " ]" vanish.
                let side = Self.checkboxSide(for: baseFontSize)
                storage.addAttributes([.markdownCheckbox: checked, .foregroundColor: NSColor.clear,
                                       .kern: side - width("[", baseFont)], range: absolute(bracket))
                hide(absolute(NSRange(location: m.range(at: 4).location, length: 2)), storage: storage, text: text)
                let firstIndent = max(0, levelIndent + (listMarkerArea - side) / 2 - rawIndentWidth)
                paragraphStyle.firstLineHeadIndent = firstIndent
                paragraphStyle.headIndent = levelIndent + listMarkerArea
                storage.addAttribute(.kern, value: levelIndent + listMarkerArea - firstIndent - rawIndentWidth - side - spaceWidth,
                                     range: absolute(NSRange(location: NSMaxRange(m.range(at: 5)), length: 1)))
                if checked {
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                         range: absolute(NSRange(location: m.range.length, length: content.length - m.range.length)))
                }
            }
            contentStart = m.range.length
        } else if let m = Self.bullet.firstMatch(in: line, range: lineRange) {
            let indentText = line.prefix(m.range(at: 1).length)
            let rawIndentWidth = width(String(indentText), baseFont)
            let level = Self.listLevel(of: indentText)
            let levelIndent = CGFloat(level) * listIndentStep
            let spaceWidth = width(" ", baseFont)
            let dash = m.range(at: 2)
            paragraphStyle.paragraphSpacing = listParagraphSpacing
            if active {
                storage.addAttribute(.foregroundColor, value: listColor, range: absolute(dash))
                paragraphStyle.headIndent = width(String(line.prefix(m.range.length)), baseFont)
            } else {
                let glyph = bulletGlyph(level: level)
                let dotWidth = width(glyph, bulletFont)
                storage.addAttributes([.markdownGlyph: glyph, .font: bulletFont, .foregroundColor: listColor], range: absolute(dash))
                let firstIndent = max(0, levelIndent + (listMarkerArea - dotWidth) / 2 - rawIndentWidth)
                paragraphStyle.firstLineHeadIndent = firstIndent
                paragraphStyle.headIndent = levelIndent + listMarkerArea
                storage.addAttribute(.kern, value: levelIndent + listMarkerArea - firstIndent - rawIndentWidth - dotWidth - spaceWidth,
                                     range: absolute(NSRange(location: NSMaxRange(dash), length: 1)))
            }
            contentStart = m.range.length
        } else if let m = Self.ordered.firstMatch(in: line, range: lineRange) {
            let indentText = line.prefix(m.range(at: 1).length)
            let rawIndentWidth = width(String(indentText), baseFont)
            let levelIndent = CGFloat(Self.listLevel(of: indentText)) * listIndentStep
            let spaceWidth = width(" ", baseFont)
            let number = m.range(at: 2)
            let numberWidth = width(String(line[Range(number, in: line)!]), baseFont)
            paragraphStyle.paragraphSpacing = listParagraphSpacing
            storage.addAttribute(.foregroundColor, value: listColor, range: absolute(number))
            // Numbers end a small gap before the text column, so they right-align.
            let firstIndent = max(0, levelIndent + listMarkerArea - baseFontSize * 0.4 - numberWidth - rawIndentWidth)
            paragraphStyle.firstLineHeadIndent = firstIndent
            paragraphStyle.headIndent = levelIndent + listMarkerArea
            storage.addAttribute(.kern, value: max(0, levelIndent + listMarkerArea - firstIndent - rawIndentWidth - numberWidth - spaceWidth),
                                 range: absolute(NSRange(location: NSMaxRange(number), length: 1)))
            contentStart = m.range.length
        } else if let m = Self.quote.firstMatch(in: line, range: lineRange) {
            marker(m.range)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: absolute(lineRange))
            paragraphStyle.firstLineHeadIndent = baseFontSize * 0.8
            paragraphStyle.headIndent = baseFontSize * 0.8
            contentStart = m.range.length
        } else if Self.rule.firstMatch(in: line, range: lineRange) != nil {
            storage.addAttribute(.foregroundColor, value: markerColor, range: absolute(lineRange))
            storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: paragraph)
            return
        }

        storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: paragraph)
        applyInline(line: line, from: contentStart, offset: offset, storage: storage, text: text, active: active)
    }

    // MARK: Inline

    private static let codeSpan = try! NSRegularExpression(pattern: #"(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)"#)
    private static let link = try! NSRegularExpression(pattern: #"!?\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    private static let boldItalic = try! NSRegularExpression(pattern: #"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
    private static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = try! NSRegularExpression(pattern: #"(?<![*\w])(\*|_)(?=\S)(.+?)(?<=\S)\1(?![*\w])"#)
    private static let strike = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)

    private func applyInline(line: String, from start: Int, offset: Int, storage: NSTextStorage, text: NSString, active: Bool) {
        let ns = line as NSString
        guard start < ns.length else { return }
        let masked = NSMutableString(string: line)
        let searchRange = NSRange(location: start, length: ns.length - start)

        func absolute(_ r: NSRange) -> NSRange { NSRange(location: r.location + offset, length: r.length) }
        func mask(_ r: NSRange) {
            masked.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
        }
        func marker(_ r: NSRange) {
            guard r.length > 0 else { return }
            if active {
                storage.addAttribute(.foregroundColor, value: markerColor, range: absolute(r))
            } else {
                hide(absolute(r), storage: storage, text: text)
            }
            mask(r)
        }
        func addTrait(_ trait: NSFontTraitMask, in r: NSRange) {
            let abs = absolute(r)
            storage.enumerateAttribute(.font, in: abs, options: []) { value, run, _ in
                let font = (value as? NSFont) ?? baseFont
                let converted = adding(trait, to: font)
                storage.addAttribute(.font, value: converted, range: run)
                if trait == .italicFontMask, converted == font {
                    storage.addAttribute(.obliqueness, value: 0.2, range: run) // font has no italic face
                }
            }
        }

        // Code spans first; nothing inside them is Markdown.
        for m in Self.codeSpan.matches(in: masked as String, range: searchRange) {
            let ticks = m.range(at: 1).length
            let inner = NSRange(location: m.range.location + ticks, length: m.range.length - 2 * ticks)
            storage.addAttributes([.font: codeFont, .backgroundColor: codeBackground], range: absolute(inner))
            marker(NSRange(location: m.range.location, length: ticks))
            marker(NSRange(location: NSMaxRange(m.range) - ticks, length: ticks))
            mask(m.range)
        }
        for m in Self.link.matches(in: masked as String, range: searchRange) {
            let label = m.range(at: 1)
            let target = m.range(at: 2)
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
            if let url = URL(string: ns.substring(with: target)) { attrs[.link] = url }
            storage.addAttributes(attrs, range: absolute(label))
            marker(NSRange(location: m.range.location, length: label.location - m.range.location))
            marker(NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label)))
            mask(m.range)
        }
        for (regex, traits) in [(Self.boldItalic, [NSFontTraitMask.boldFontMask, .italicFontMask]),
                                (Self.bold, [.boldFontMask]),
                                (Self.italic, [.italicFontMask])] {
            for m in regex.matches(in: masked as String, range: searchRange) {
                let markerLength = m.range(at: 1).length
                for trait in traits { addTrait(trait, in: m.range(at: 2)) }
                marker(NSRange(location: m.range.location, length: markerLength))
                marker(NSRange(location: NSMaxRange(m.range) - markerLength, length: markerLength))
            }
        }
        for m in Self.strike.matches(in: masked as String, range: searchRange) {
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .foregroundColor: NSColor.secondaryLabelColor], range: absolute(m.range(at: 1)))
            marker(NSRange(location: m.range.location, length: 2))
            marker(NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
    }

    // MARK: Plain text

    private static let titleBlockMarkers = try! NSRegularExpression(
        pattern: #"^(#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+(\[[ xX]\][ \t]+)?|\d{1,3}[.)][ \t]+)"#)
    private static let titleLinks = try! NSRegularExpression(pattern: #"!?\[([^\]]+)\]\([^)]*\)"#)
    private static let titleInlineMarkers = try! NSRegularExpression(pattern: #"(\*{1,3}|_{2,3}|~~|`+)"#)

    /// `line` without its Markdown syntax, for titles and file names ("# Foo" → "Foo").
    static func plainText(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        func strip(_ regex: NSRegularExpression, with template: String) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
        }
        strip(titleBlockMarkers, with: "")
        strip(titleLinks, with: "$1")
        strip(titleInlineMarkers, with: "")
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? line.trimmingCharacters(in: .whitespaces) : s
    }

    // MARK: Glyph generation (TextKit 1)

    static func glyph(for character: String, in font: NSFont) -> CGGlyph? {
        let utf16 = Array(character.utf16)
        guard utf16.count == 1 else { return nil }
        var glyph: CGGlyph = 0
        let found = CTFontGetGlyphsForCharacters(font as CTFont, utf16, &glyph, 1)
        return found && glyph != 0 ? glyph : nil
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        let count = glyphRange.length
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        let newProperties = Array(UnsafeBufferPointer(start: properties, count: count))
        var changed = false
        for i in 0..<count {
            let index = characterIndexes[i]
            guard index < storage.length else { continue }
            if let replacement = storage.attribute(.markdownGlyph, at: index, effectiveRange: nil) as? String,
               let glyph = Self.glyph(for: replacement, in: font) {
                newGlyphs[i] = glyph
                changed = true
            }
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(newGlyphs, properties: newProperties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return count
    }
}
