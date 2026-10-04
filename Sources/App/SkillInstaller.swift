import Foundation
import os

/// The Clearway skill's install: a `~/.clearway/cway` link to the bundle's CLI and a `clearway`
/// link in each present agent's skills directory to the bundle's skill folder.
///
/// The state is read from the links on disk every time and never stored, so a moved app, a Debug
/// build's links or a hand-deleted entry all show as they are.
enum SkillInstaller {

    enum Target: CaseIterable {
        case cli, claudeCode, codex
    }

    enum EntryState: Equatable {
        case agentAbsent, missing, current, stale, foreign
    }

    struct Entry: Equatable {
        let target: Target
        let displayPath: String
        let state: EntryState
    }

    static func status(home: String, bundlePath: String) -> SkillInstallStatus {
        SkillInstallStatus(entries: Target.allCases.map { target in
            let location = Location(target, home: home, bundlePath: bundlePath)
            return Entry(target: target, displayPath: location.displayPath, state: location.state())
        })
    }

    static func install(home: String, bundlePath: String) {
        for target in Target.allCases {
            let location = Location(target, home: home, bundlePath: bundlePath)
            do {
                switch location.state() {
                case .missing:
                    try location.createContainer()
                case .stale:
                    try FileManager.default.removeItem(atPath: location.path)
                case .agentAbsent, .current, .foreign:
                    continue
                }
                try FileManager.default.createSymbolicLink(atPath: location.path, withDestinationPath: location.destination)
                Ghostty.logger.info("Linked \(location.path, privacy: .public) to \(location.destination, privacy: .public)")
            } catch {
                Ghostty.logger.error("\(location.path, privacy: .public) could not be linked: \(error)")
            }
        }
    }

    /// Removes no directory, including a `skills` directory Install created: knowing that Install
    /// created it would take a stored record, and an empty directory costs nothing.
    static func uninstall(home: String, bundlePath: String) {
        for target in Target.allCases {
            let location = Location(target, home: home, bundlePath: bundlePath)
            guard [.current, .stale].contains(location.state()) else { continue }
            do {
                try FileManager.default.removeItem(atPath: location.path)
                Ghostty.logger.info("Removed \(location.path, privacy: .public)")
            } catch {
                Ghostty.logger.error("\(location.path, privacy: .public) could not be removed: \(error)")
            }
        }
    }

    private struct Location {
        /// The agent's own config directory, which Clearway never creates; `nil` for the CLI.
        let gate: String?
        let container: String
        let path: String
        let destination: String
        /// What makes a link Clearway's from any bundle path, including one that no longer exists.
        let destinationSuffix: String
        let displayPath: String

        init(_ target: Target, home: String, bundlePath: String) {
            let cliSuffix = "Contents/MacOS/cway"
            let skillSuffix = "Contents/Resources/Skills/clearway"
            let (gateName, containerName, linkName, suffix): (String?, String, String, String) = switch target {
            case .cli: (nil, ".clearway", "cway", cliSuffix)
            case .claudeCode: (".claude", ".claude/skills", "clearway", skillSuffix)
            case .codex: (".codex", ".agents/skills", "clearway", skillSuffix)
            }
            let home = home as NSString
            gate = gateName.map(home.appendingPathComponent)
            container = home.appendingPathComponent(containerName)
            path = (container as NSString).appendingPathComponent(linkName)
            destination = (bundlePath as NSString).appendingPathComponent(suffix)
            destinationSuffix = ".app/" + suffix
            // Built from the names rather than abbreviated from `path`: `abbreviatingWithTildeInPath`
            // reads the real home, so under a temp root the displayed line would differ.
            displayPath = "~/\(containerName)/\(linkName)"
        }

        /// Never `fileExists` on the entry itself: it follows the link and reports a dangling one
        /// as missing, which Install would then fail to create over.
        func state() -> EntryState {
            let fileManager = FileManager.default
            if let gate, !isDirectory(gate) { return .agentAbsent }
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return .missing }
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                  let linked = try? fileManager.destinationOfSymbolicLink(atPath: path) else { return .foreign }
            if linked == destination { return .current }
            return linked.hasSuffix(destinationSuffix) ? .stale : .foreign
        }

        func createContainer() throws {
            guard !isDirectory(container) else { return }
            let attributes: [FileAttributeKey: Any]? = gate == nil ? [.posixPermissions: AgentHookScript.dirMode] : nil
            try FileManager.default.createDirectory(atPath: container, withIntermediateDirectories: true, attributes: attributes)
        }

        private func isDirectory(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}

struct SkillInstallStatus: Equatable {
    let entries: [SkillInstaller.Entry]

    /// A foreign or agent-absent entry does not block it, or a foreign entry would keep the button
    /// on Install forever with Clearway's own links on disk and Uninstall unreachable.
    var isInstalled: Bool {
        !entries.contains { [.missing, .stale].contains($0.state) } && entries.contains { $0.state == .current }
    }

    /// The cases where the button does less than its label says.
    var messages: [String] {
        let foreign = entries.filter { $0.state == .foreign }.map { "\($0.displayPath) already exists and was left alone." }
        let noAgent = entries.filter { $0.target != .cli }.allSatisfy { $0.state == .agentAbsent }
        return foreign + (noAgent ? ["No ~/.claude or ~/.codex directory was found, so the skill was not installed."] : [])
    }
}
