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

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var watchedInode: ino_t = 0
    private var syncWorkItem: DispatchWorkItem?

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

        // Set before writing so the watchers recognise the write as ours.
        lastKnownText = text
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("NotesOverlay: failed to save \(fileURL.path): \(error)")
        }
    }

    // MARK: External changes

    /// Two watchers. The directory catches atomic saves (a new inode renamed over the
    /// file, which is what editors and our own `.atomic` writes do). The file itself
    /// catches in-place writes such as `echo >> scratchpad.txt`. After any event the
    /// file watcher is re-armed if the inode changed, then the contents are compared.
    func startWatching() {
        stopWatching()
        directorySource = makeSource(path: directoryURL.path, mask: .write)
        if directorySource == nil {
            NSLog("NotesOverlay: cannot watch \(directoryURL.path)")
        }
        armFileWatcher()
    }

    func stopWatching() {
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
        watchedInode = 0
    }

    private func makeSource(path: String, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleSync() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func armFileWatcher() {
        fileSource?.cancel()
        fileSource = makeSource(
            path: fileURL.path,
            mask: [.write, .extend, .attrib, .delete, .rename, .revoke]
        )
        watchedInode = fileSource == nil ? 0 : (currentInode() ?? 0)
    }

    private func currentInode() -> ino_t? {
        var info = stat()
        guard stat(fileURL.path, &info) == 0 else { return nil }
        return info.st_ino
    }

    private func scheduleSync() {
        syncWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.sync() }
        syncWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func sync() {
        if currentInode() != watchedInode {
            armFileWatcher() // file was replaced, recreated, or deleted
        }
        reloadIfChanged()
    }

    private func reloadIfChanged() {
        // Unsaved local edits win; they will be written shortly.
        guard pendingText == nil else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let text = try? String(contentsOf: fileURL, encoding: .utf8),
              text != lastKnownText
        else { return }
        lastKnownText = text
        NSLog("NotesOverlay: reloaded note after external change (\(text.count) characters)")
        onExternalChange?(text)
    }
}
