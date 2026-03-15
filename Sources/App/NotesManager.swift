import Foundation

/// Manages markdown notes stored in a worktree's `.wtpad/` directory.
///
/// Notes are plain `.md` files with timestamp-based filenames (e.g., `20260315-142129.md`).
/// The manager watches the directory for external changes and reloads automatically.
@MainActor
class NotesManager: ObservableObject {
    @Published var notes: [Note] = []

    private(set) var worktreePath: String?
    private var watcherSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    nonisolated deinit {
        pendingReload?.cancel()
        watcherSource?.cancel()
    }

    private var wtpadDir: String? {
        worktreePath.map { ($0 as NSString).appendingPathComponent(".wtpad") }
    }

    func setWorktreePath(_ path: String?) {
        guard path != worktreePath else { return }
        stopWatching()
        worktreePath = path
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
        guard let wtpadDir else {
            notes = []
            return
        }

        Task.detached {
            let loaded = Self.loadNotes(from: wtpadDir)
            await MainActor.run {
                if loaded != self.notes { self.notes = loaded }
            }
        }
    }

    // MARK: - CRUD

    /// Creates a new empty note and returns its filename, or `nil` on failure.
    @discardableResult
    func createNote() -> String? {
        guard let wtpadDir else { return nil }
        let filename = Self.timestampFormatter.string(from: Date()) + ".md"
        let filePath = (wtpadDir as NSString).appendingPathComponent(filename)

        let fm = FileManager.default
        try? fm.createDirectory(atPath: wtpadDir, withIntermediateDirectories: true)
        guard fm.createFile(atPath: filePath, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            return nil
        }

        // Optimistically insert so the UI updates immediately
        let note = Note(id: filename, content: "", modificationDate: Date())
        notes.insert(note, at: 0)
        return filename
    }

    func updateNote(_ note: Note, content: String) {
        guard let wtpadDir else { return }
        let filePath = (wtpadDir as NSString).appendingPathComponent(note.id)
        let data = content.data(using: .utf8) ?? Data()
        FileManager.default.createFile(atPath: filePath, contents: data, attributes: [.posixPermissions: 0o600])
    }

    func deleteNote(_ note: Note) {
        guard let wtpadDir else { return }
        let filePath = (wtpadDir as NSString).appendingPathComponent(note.id)
        try? FileManager.default.removeItem(atPath: filePath)

        // Optimistically remove so the UI updates immediately
        notes.removeAll { $0.id == note.id }
    }

    // MARK: - Loading

    private nonisolated static func loadNotes(from wtpadDir: String) -> [Note] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: wtpadDir) else { return [] }

        let mdFiles = contents.filter { $0.hasSuffix(".md") }
        var loaded: [Note] = []

        for file in mdFiles {
            let filePath = (wtpadDir as NSString).appendingPathComponent(file)
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
        guard let wtpadDir else { return }

        // Ensure directory exists so we can watch it
        try? FileManager.default.createDirectory(atPath: wtpadDir, withIntermediateDirectories: true)

        if let source = Self.makeWatcher(path: wtpadDir, handler: { [weak self] in
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
