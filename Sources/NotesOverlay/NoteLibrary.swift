import Foundation

struct NoteInfo: Equatable {
    let url: URL
    let title: String
    let characterCount: Int
    let modified: Date
    let lastOpened: Date?
    let pinned: Bool
    /// Nothing but whitespace in the file.
    let isEmpty: Bool
    /// Lowercased title + beginning of the content, for fuzzy search.
    let searchText: String

    var filename: String { url.lastPathComponent }

    static func == (lhs: NoteInfo, rhs: NoteInfo) -> Bool { lhs.url == rhs.url }
}

/// The folder of .txt notes: listing, creating, renaming to match titles, trashing,
/// plus a watcher that reports any change in the folder.
final class NoteLibrary {
    let directoryURL: URL
    /// Called on the main queue after the folder's contents changed.
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var refreshWorkItem: DispatchWorkItem?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// Creates the folder and, once, moves the 1.0 single note into it.
    func prepare(legacyNotePath: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        guard !Settings.didMigrateLegacyNote else { return }
        Settings.didMigrateLegacyNote = true

        let legacy = URL(fileURLWithPath: legacyNotePath)
        guard fm.fileExists(atPath: legacy.path),
              legacy.deletingLastPathComponent().standardizedFileURL != directoryURL.standardizedFileURL
        else { return }

        let content = (try? String(contentsOf: legacy, encoding: .utf8)) ?? ""
        let target = uniqueURL(forTitle: Self.title(of: content))
        do {
            try fm.moveItem(at: legacy, to: target)
            Settings.currentNote = target.lastPathComponent
            NSLog("NotesOverlay: moved \(legacy.path) to \(target.path)")
        } catch {
            NSLog("NotesOverlay: could not migrate \(legacy.path): \(error)")
        }
    }

    /// All notes, pinned first, then most recently opened (or edited) first.
    func notes() -> [NoteInfo] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let pinned = Set(Settings.pinnedNotes)
        let opened = Settings.lastOpened
        var result: [NoteInfo] = []
        for url in urls where url.pathExtension.lowercased() == "txt" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let title = Self.title(of: content)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            result.append(NoteInfo(
                url: url,
                title: title,
                characterCount: content.count,
                modified: modified,
                lastOpened: opened[url.lastPathComponent],
                pinned: pinned.contains(url.lastPathComponent),
                isEmpty: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                searchText: (title + "\n" + content.prefix(2000)).lowercased()
            ))
        }
        return result.sorted(by: Self.defaultOrder)
    }

    static func defaultOrder(_ a: NoteInfo, _ b: NoteInfo) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        let da = a.lastOpened ?? a.modified
        let db = b.lastOpened ?? b.modified
        if da != db { return da > db }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    /// New note, optionally with its first line already set. Returns the file URL.
    func create(title: String?) throws -> URL {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = uniqueURL(forTitle: title ?? "Untitled")
        let text = title.map { $0 + "\n" } ?? ""
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Moves the note to the macOS Trash (recoverable).
    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        Settings.removeMetadata(for: url.lastPathComponent)
    }

    /// Where `url` should live for its file name to match `title`, or nil if it already does.
    func urlMatchingTitle(for url: URL, title: String) -> URL? {
        let desired = Self.sanitizedFilename(title)
        let current = url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        if current.caseInsensitiveCompare(desired) == .orderedSame { return nil }
        // "Title 2", "Title 3" … from an earlier name collision also count as matching.
        let pattern = "^" + NSRegularExpression.escapedPattern(for: desired) + " \\d+$"
        if current.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        // The file system may already consider the desired name to be this very file
        // (case- and normalisation-insensitive volume); then there is nothing to do.
        let candidate = directoryURL.appendingPathComponent(desired).appendingPathExtension("txt")
        if Self.sameFile(candidate, url) { return nil }
        return uniqueURL(forTitle: title)
    }

    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard let ida = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let idb = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return ida.isEqual(idb)
    }

    func uniqueURL(forTitle title: String) -> URL {
        let base = Self.sanitizedFilename(title)
        var candidate = directoryURL.appendingPathComponent(base).appendingPathExtension("txt")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directoryURL.appendingPathComponent("\(base) \(n)").appendingPathExtension("txt")
            n += 1
        }
        return candidate
    }

    /// First non-empty line without its Markdown syntax; "Untitled" for an empty note.
    static func title(of content: String) -> String {
        let line = content
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return line.map(MarkdownStyler.plainText) ?? "Untitled"
    }

    private static let windowsReservedNames: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for n in 1...9 { names.insert("COM\(n)"); names.insert("LPT\(n)") }
        return names
    }()

    /// A readable file name for a title that is safe on macOS *and* on volumes or sync
    /// services with Windows rules: unsafe characters replaced, control characters
    /// dropped, whitespace collapsed, no leading dot, no trailing dots/spaces, reserved
    /// device names escaped, composed Unicode, capped at 60 characters.
    static func sanitizedFilename(_ title: String) -> String {
        var s = title.precomposedStringWithCanonicalMapping
        s = s.replacingOccurrences(of: #"[/\\:*?"<>|]"#, with: "-", options: .regularExpression)
        s = s.components(separatedBy: .controlCharacters).joined()
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 60 { s = String(s.prefix(60)) }
        s = s.replacingOccurrences(of: #"[. ]+$"#, with: "", options: .regularExpression)
        if s.hasPrefix(".") { s = "_" + s.dropFirst() }
        if windowsReservedNames.contains(s.uppercased()) { s += "_" }
        return s.isEmpty ? "Untitled" : s
    }

    // MARK: Watching

    func startWatching() {
        stopWatching()
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("NotesOverlay: cannot watch \(directoryURL.path)")
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in self?.scheduleRefresh() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    func stopWatching() {
        source?.cancel()
        source = nil
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange?() }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }
}
