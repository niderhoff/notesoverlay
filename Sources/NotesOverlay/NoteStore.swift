import Foundation

/// Owns the single plain-text note file: load, debounced atomic save, and reload
/// when something else edits the file.
final class NoteStore {
    let fileURL: URL
    private let directoryURL: URL

    /// Last text we loaded, wrote, or reloaded. Used to ignore our own writes.
    private(set) var lastKnownText = ""
    /// Called on the main queue with the new contents when the file changed externally.
    var onExternalChange: ((String) -> Void)?

    private var pendingText: String?
    private var saveTimer: Timer?
    private var watchSource: DispatchSourceFileSystemObject?
    private var reloadWorkItem: DispatchWorkItem?

    init(path: String) {
        fileURL = URL(fileURLWithPath: path)
        directoryURL = fileURL.deletingLastPathComponent()
    }

    /// Creates the folder and an empty file on first run, then returns the contents.
    func load() -> String {
        let fm = FileManager.default
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            try? Data().write(to: fileURL, options: .atomic)
        }
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        lastKnownText = text
        return text
    }

    /// Debounced: writes 0.5 s after the last call unless `flush()` comes first.
    func scheduleSave(_ text: String) {
        pendingText = text
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.flush()
        }
    }

    /// Writes any pending text now.
    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let text = pendingText else { return }
        pendingText = nil

        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        guard text != lastKnownText || !fileExists else { return }

        // Set before writing so the directory watcher recognises the write as ours.
        lastKnownText = text
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("NotesOverlay: failed to save \(fileURL.path): \(error)")
        }
    }

    // MARK: External changes

    /// Watches the *directory*, not the file: atomic saves (ours and other editors')
    /// replace the inode, which would invalidate a file descriptor on the file itself.
    func startWatching() {
        stopWatching()
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("NotesOverlay: cannot watch \(directoryURL.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.directoryChanged() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchSource = source
    }

    func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
    }

    private func directoryChanged() {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reloadIfChanged() }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func reloadIfChanged() {
        // Unsaved local edits win; they will be written shortly.
        guard pendingText == nil else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let text = try? String(contentsOf: fileURL, encoding: .utf8),
              text != lastKnownText
        else { return }
        lastKnownText = text
        onExternalChange?(text)
    }
}
