import Foundation

/// Manages reusable prompt files stored in a configurable directory (default `~/.wtpad/prompts/`).
///
/// Prompts are `.md` files with YAML frontmatter for the title and plain text body.
/// The manager watches the directory for external changes and reloads automatically.
@MainActor
class PromptManager: ObservableObject {
    @Published var prompts: [Prompt] = []

    private(set) var directory: String
    private var watcherSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    init(directory: String) {
        self.directory = (directory as NSString).expandingTildeInPath
    }

    nonisolated deinit {
        pendingReload?.cancel()
        watcherSource?.cancel()
    }

    /// Updates the prompts directory path and re-establishes watching.
    func setDirectory(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded != directory else { return }
        stopWatching()
        directory = expanded
        startWatching()
    }

    func startWatching() {
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
        let dir = directory
        Task.detached {
            let loaded = Self.loadPrompts(from: dir)
            await MainActor.run {
                if loaded != self.prompts { self.prompts = loaded }
            }
        }
    }

    // MARK: - CRUD

    /// Creates a new prompt and returns it, or `nil` on failure.
    @discardableResult
    func createPrompt(title: String = "", content: String = "") -> Prompt? {
        let filename = UUID().uuidString.lowercased() + ".md"
        let filePath = (directory as NSString).appendingPathComponent(filename)

        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let prompt = Prompt(id: filename, title: title, content: content, modificationDate: Date())
        guard let data = prompt.serialized().data(using: .utf8),
              fm.createFile(atPath: filePath, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return nil
        }

        prompts.insert(prompt, at: 0)
        return prompt
    }

    /// Updates an existing prompt on disk.
    func updatePrompt(_ prompt: Prompt) {
        let filePath = (directory as NSString).appendingPathComponent(prompt.id)
        guard let data = prompt.serialized().data(using: .utf8) else { return }
        FileManager.default.createFile(atPath: filePath, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Deletes a prompt from disk.
    func deletePrompt(_ prompt: Prompt) {
        let filePath = (directory as NSString).appendingPathComponent(prompt.id)
        try? FileManager.default.removeItem(atPath: filePath)

        prompts.removeAll { $0.id == prompt.id }
    }

    // MARK: - Loading

    private nonisolated static func loadPrompts(from directory: String) -> [Prompt] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        let mdFiles = contents.filter { $0.hasSuffix(".md") && !$0.contains("/") && !$0.contains("..") }
        var loaded: [Prompt] = []

        for file in mdFiles {
            let filePath = (directory as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: filePath),
                  let content = String(data: data, encoding: .utf8),
                  let attrs = try? fm.attributesOfItem(atPath: filePath),
                  let modDate = attrs[.modificationDate] as? Date,
                  let prompt = Prompt.parse(from: content, filename: file, modificationDate: modDate) else {
                continue
            }
            loaded.append(prompt)
        }

        loaded.sort { $0.modificationDate > $1.modificationDate }
        return loaded
    }

    // MARK: - File Watching

    private func watchDirectory() {
        let dir = directory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcherSource = source
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
}
