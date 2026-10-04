import Foundation
import os

enum SkillInstaller {

    enum Target: CaseIterable {
        case cli, claudeCode, codex
    }

    enum EntryState: Equatable {
        case agentAbsent, missing, current, stale, foreign
        case unreadable(reason: String)
    }

    struct Failure: Equatable {
        enum Action { case link, remove }

        let displayPath: String
        let action: Action
        let reason: String

        var message: String {
            switch action {
            case .link: "\(displayPath) could not be linked: \(reason)."
            case .remove: "\(displayPath) could not be removed: \(reason)."
            }
        }
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

    static func install(home: String, bundlePath: String) -> [Failure] {
        var failures: [Failure] = []
        for target in Target.allCases {
            let location = Location(target, home: home, bundlePath: bundlePath)
            do {
                switch location.state() {
                case .missing:
                    try location.createContainer()
                case .stale:
                    try FileManager.default.removeItem(atPath: location.path)
                case .agentAbsent, .current, .foreign, .unreadable:
                    continue
                }
                try FileManager.default.createSymbolicLink(atPath: location.path, withDestinationPath: location.destination)
                Ghostty.logger.info("Linked \(location.path, privacy: .public) to \(location.destination, privacy: .public)")
            } catch {
                Ghostty.logger.error("\(location.path, privacy: .public) could not be linked: \(error, privacy: .public)")
                failures.append(Failure(displayPath: location.displayPath, action: .link, reason: reason(for: error)))
            }
        }
        return failures
    }

    static func uninstall(home: String, bundlePath: String) -> [Failure] {
        var failures: [Failure] = []
        for target in Target.allCases {
            let location = Location(target, home: home, bundlePath: bundlePath)
            guard [.current, .stale].contains(location.state()) else { continue }
            do {
                try FileManager.default.removeItem(atPath: location.path)
                Ghostty.logger.info("Removed \(location.path, privacy: .public)")
            } catch {
                Ghostty.logger.error("\(location.path, privacy: .public) could not be removed: \(error, privacy: .public)")
                failures.append(Failure(displayPath: location.displayPath, action: .remove, reason: reason(for: error)))
            }
        }
        return failures
    }

    private static func posixError(in error: Error) -> NSError? {
        guard let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError,
              underlying.domain == NSPOSIXErrorDomain else { return nil }
        return underlying
    }

    private static func reason(for error: Error) -> String {
        guard let posix = posixError(in: error) else { return error.localizedDescription }
        return String(cString: strerror(Int32(posix.code)))
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
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: path)
            } catch {
                if SkillInstaller.posixError(in: error)?.code == Int(ENOENT) { return .missing }
                return .unreadable(reason: SkillInstaller.reason(for: error))
            }
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

    var isInstalled: Bool {
        !entries.contains { [.missing, .stale].contains($0.state) } && entries.contains { $0.state == .current }
    }

    var messages: [String] {
        let entryLines = entries.compactMap { entry -> String? in
            switch entry.state {
            case .foreign: "\(entry.displayPath) already exists and was left alone."
            case .unreadable(let reason): "\(entry.displayPath) could not be read: \(reason)."
            case .agentAbsent, .missing, .current, .stale: nil
            }
        }
        let noAgent = entries.filter { $0.target != .cli }.allSatisfy { $0.state == .agentAbsent }
        return entryLines + (noAgent ? ["No ~/.claude or ~/.codex directory was found, so the skill was not installed."] : [])
    }
}
