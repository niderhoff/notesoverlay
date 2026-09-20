import AppKit

extension NSAttributedString.Key {
    /// Marker characters that are drawn as nothing (zero-width) on inactive lines.
    static let markdownHidden = NSAttributedString.Key("NotesOverlay.markdownHidden")
    /// A one-character String to draw instead of the character (e.g. "•" for "-").
    static let markdownGlyph = NSAttributedString.Key("NotesOverlay.markdownGlyph")
    /// Paragraph belongs to a fenced code block: MarkdownLayoutManager draws a full-width band.
    static let markdownCodeBlock = NSAttributedString.Key("NotesOverlay.markdownCodeBlock")
}

/// Draws a full-width background band behind fenced code blocks.
final class MarkdownLayoutManager: NSLayoutManager {
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

    private func headingFont(level: Int) -> NSFont {
        let scale: CGFloat = [1.5, 1.3, 1.15, 1.0, 1.0, 1.0][min(max(level, 1), 6) - 1]
        return .boldSystemFont(ofSize: (baseFontSize * scale).rounded())
    }

    private func adding(_ trait: NSFontTraitMask, to font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: trait)
    }

    /// A font that has the glyphs for ☐/☑, or nil to leave checkboxes raw.
    private lazy var checkboxFont: NSFont? = {
        for candidate in [NSFont.systemFont(ofSize: 10), NSFont(name: "Apple Symbols", size: 10), NSFont(name: "Menlo", size: 10)] {
            if let f = candidate, Self.glyph(for: "☐", in: f) != nil, Self.glyph(for: "☑", in: f) != nil { return f }
        }
        return nil
    }()

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: NSParagraphStyle.default]
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

        textView.typingAttributes = baseAttributes()
        // Hidden/substituted glyphs are decided at glyph generation, so when the
        // raw/rendered split moves (selection change, zoom) the glyphs must be rebuilt.
        // Inside the storage's own edit processing TextKit does that itself.
        if !insideProcessEditing, let layoutManager = textView.layoutManager {
            layoutManager.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
            layoutManager.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
        }
    }

    private static func isNewline(_ c: unichar) -> Bool {
        c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029
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
        let paragraphStyle = NSMutableParagraphStyle()

        func absolute(_ r: NSRange) -> NSRange { NSRange(location: r.location + offset, length: r.length) }
        func marker(_ r: NSRange, font: NSFont? = nil) {
            guard r.length > 0 else { return }
            var attrs: [NSAttributedString.Key: Any] = active ? [.foregroundColor: markerColor] : [.markdownHidden: true]
            if let font { attrs[.font] = font }
            storage.addAttributes(attrs, range: absolute(r))
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
            contentStart = m.range.length
        } else if let m = Self.task.firstMatch(in: line, range: lineRange), let boxFont = checkboxFont {
            let indent = line.prefix(m.range(at: 1).length)
            let checked = line[Range(m.range(at: 4), in: line)!].lowercased() == "x"
            // "- [ ] " → hide "- ", draw "[" as a checkbox, hide " " / "x" and "]".
            marker(NSRange(location: m.range(at: 2).location, length: 2))
            if active {
                marker(NSRange(location: m.range(at: 3).location, length: 3))
            } else {
                let box = boxFont.withSize(baseFontSize)
                storage.addAttributes([.markdownGlyph: checked ? "☑" : "☐", .font: box], range: absolute(m.range(at: 3)))
                storage.addAttribute(.markdownHidden, value: true, range: absolute(NSRange(location: m.range(at: 4).location, length: 2)))
                if checked {
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: absolute(NSRange(location: m.range.length, length: content.length - m.range.length)))
                }
            }
            let hang = width(String(indent), baseFont) + width("☐ ", boxFont.withSize(baseFontSize))
            paragraphStyle.headIndent = hang
            contentStart = m.range.length
        } else if let m = Self.bullet.firstMatch(in: line, range: lineRange) {
            let indent = line.prefix(m.range(at: 1).length)
            if active {
                marker(m.range(at: 2))
            } else {
                storage.addAttributes([.markdownGlyph: "•", .font: bulletFont], range: absolute(m.range(at: 2)))
            }
            paragraphStyle.headIndent = width(String(indent), baseFont) + width("• ", bulletFont)
            contentStart = m.range.length
        } else if let m = Self.ordered.firstMatch(in: line, range: lineRange) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: absolute(m.range(at: 2)))
            paragraphStyle.headIndent = width(line.prefix(m.range.length).description, baseFont)
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
        applyInline(line: line, from: contentStart, offset: offset, storage: storage, active: active)
    }

    // MARK: Inline

    private static let codeSpan = try! NSRegularExpression(pattern: #"(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)"#)
    private static let link = try! NSRegularExpression(pattern: #"!?\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    private static let boldItalic = try! NSRegularExpression(pattern: #"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
    private static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = try! NSRegularExpression(pattern: #"(?<![*\w])(\*|_)(?=\S)(.+?)(?<=\S)\1(?![*\w])"#)
    private static let strike = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)

    private func applyInline(line: String, from start: Int, offset: Int, storage: NSTextStorage, active: Bool) {
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
            storage.addAttributes(active ? [.foregroundColor: markerColor] : [.markdownHidden: true], range: absolute(r))
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
        var newProperties = Array(UnsafeBufferPointer(start: properties, count: count))
        var changed = false
        for i in 0..<count {
            let index = characterIndexes[i]
            guard index < storage.length else { continue }
            let attrs = storage.attributes(at: index, effectiveRange: nil)
            if attrs[.markdownHidden] != nil {
                newProperties[i] = .null
                changed = true
            } else if let replacement = attrs[.markdownGlyph] as? String, let glyph = Self.glyph(for: replacement, in: font) {
                newGlyphs[i] = glyph
                changed = true
            }
        }
        guard changed else { return 0 }
        layoutManager.setGlyphs(newGlyphs, properties: newProperties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return count
    }
}
