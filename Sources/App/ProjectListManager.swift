import SwiftUI

private enum DefaultsKey {
    static let projectPaths = "clearway.projectPaths"
    static let lastActiveProjectPath = "clearway.activeProjectPath"
    static let legacyProjectPath = "clearway.projectPath"
}

/// Manages the global list of projects across all windows.
///
/// Each project opens in its own window. This manager tracks which projects
/// have been added and which was last active (for restoring on launch).
@MainActor
class ProjectListManager: ObservableObject {
    // Assigned before @Published properties so didSet observers can use it.
    // didSet does not fire during the designated initializer's own assignments.
    private let defaults: UserDefaults

    @Published var projectPaths: [String] = [] {
        didSet {
            defaults.set(projectPaths, forKey: DefaultsKey.projectPaths)
        }
    }

    @Published var lastActiveProjectPath: String? {
        didSet {
            if let path = lastActiveProjectPath {
                defaults.set(path, forKey: DefaultsKey.lastActiveProjectPath)
            } else {
                defaults.removeObject(forKey: DefaultsKey.lastActiveProjectPath)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Migrate from single project path
        if let single = defaults.string(forKey: DefaultsKey.legacyProjectPath) {
            self.projectPaths = [single]
            self.lastActiveProjectPath = single
            defaults.removeObject(forKey: DefaultsKey.legacyProjectPath)
        } else {
            self.projectPaths = defaults.stringArray(forKey: DefaultsKey.projectPaths) ?? []
            self.lastActiveProjectPath = defaults.string(forKey: DefaultsKey.lastActiveProjectPath)
        }
    }

    func addProject(_ path: String) {
        if !projectPaths.contains(path) {
            projectPaths.append(path)
        }
        lastActiveProjectPath = path
    }

    func removeProject(_ path: String) {
        projectPaths.removeAll { $0 == path }
        if lastActiveProjectPath == path {
            lastActiveProjectPath = projectPaths.first
        }
    }

    /// Show an open panel to pick a git project directory and add it.
    /// Returns the path if a project was added, or `nil` if the user cancelled.
    @discardableResult
    func pickAndAddProject() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a git project directory"
        panel.prompt = "Add Project"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        addProject(url.path)
        return url.path
    }
}
