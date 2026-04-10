import Foundation

/// Manages markdown notes stored in a worktree's `.clearway/` directory.
///
/// Notes are plain `.md` files with timestamp-based filenames (e.g., `20260315-142129.md`).
/// The manager watches the directory for external changes and reloads automatically.
@MainActor
class NotesManager: ObservableObject {
    @Published var notes: [Note] = []
    var dismissedImportPaths: Set<String> = []
    var lastClipboardChangeCount: Int = 0

    private(set) var worktreePath: String?
    private var watcherSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    nonisolated static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    nonisolated deinit {
        pendingReload?.cancel()
        watcherSource?.cancel()
    }

    private var clearwayDir: String? {
        worktreePath.map { ($0 as NSString).appendingPathComponent(".clearway") }
    }

    func setWorktreePath(_ path: String?) {
        guard path != worktreePath else { return }
        stopWatching()
        worktreePath = path
        dismissedImportPaths.removeAll()
        reload()
        watchDirectory()
    }

    func stopWatching() {
        pendingReload?.cancel()
        pendingReload = nil
        watcherSource?.cancel()
        watcherSource = nil
    }

    func reload() {
        guard let clearwayDir else {
            notes = []
            return
        }

        Task.detached {
            let loaded = Self.loadNotes(from: clearwayDir)
            await MainActor.run {
                if loaded != self.notes { self.notes = loaded }
            }
        }
    }

    // MARK: - CRUD

    /// Creates a new empty note and returns its filename, or `nil` on failure.
    @discardableResult
    func createNote() -> String? {
        guard let clearwayDir else { return nil }
        let filename = Self.timestampFormatter.string(from: Date()) + ".md"
        let filePath = (clearwayDir as NSString).appendingPathComponent(filename)

        let fm = FileManager.default
        try? fm.createDirectory(atPath: clearwayDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard fm.createFile(atPath: filePath, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            return nil
        }

        // Optimistically insert so the UI updates immediately
        let note = Note(id: filename, content: "", modificationDate: Date())
        notes.insert(note, at: 0)
        return filename
    }

    func deleteNote(_ note: Note) {
        guard let clearwayDir else { return }
        let filePath = (clearwayDir as NSString).appendingPathComponent(note.id)
        try? FileManager.default.removeItem(atPath: filePath)

        // Optimistically remove so the UI updates immediately
        notes.removeAll { $0.id == note.id }
    }

    @discardableResult
    func importNote(from sourcePath: String) -> String? {
        guard let clearwayDir else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: clearwayDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Read source content and write as a new timestamped note
        guard let data = fm.contents(atPath: sourcePath),
              let content = String(data: data, encoding: .utf8) else { return nil }

        let filename = Self.timestampFormatter.string(from: Date()) + ".md"
        let filePath = (clearwayDir as NSString).appendingPathComponent(filename)
        guard fm.createFile(atPath: filePath, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return nil
        }

        // Optimistic insert
        let note = Note(id: filename, content: content, modificationDate: Date())
        notes.insert(note, at: 0)
        return filename
    }

    // MARK: - Loading

    private nonisolated static func loadNotes(from clearwayDir: String) -> [Note] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: clearwayDir) else { return [] }

        let mdFiles = contents.filter { $0.hasSuffix(".md") }
        var loaded: [Note] = []

        for file in mdFiles {
            let filePath = (clearwayDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: filePath),
                  let content = String(data: data, encoding: .utf8),
                  let attrs = try? fm.attributesOfItem(atPath: filePath),
                  let modDate = attrs[.modificationDate] as? Date else {
                continue
            }
            loaded.append(Note(id: file, content: content, modificationDate: modDate))
        }

        loaded.sort { $0.id > $1.id }
        return loaded
    }

    // MARK: - File Watching

    private func watchDirectory() {
        guard let clearwayDir else { return }

        // Ensure directory exists so we can watch it
        try? FileManager.default.createDirectory(atPath: clearwayDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        if let source = Self.makeWatcher(path: clearwayDir, handler: { [weak self] in
            self?.scheduleReload()
        }) {
            watcherSource = source
        }
    }

    private nonisolated func scheduleReload() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.reload()
            }
            self.pendingReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private nonisolated static func makeWatcher(
        path: String,
        handler: @escaping () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
