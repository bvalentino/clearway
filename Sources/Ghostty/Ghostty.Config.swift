import SwiftUI
import GhosttyKit

extension Ghostty {
    /// Wraps a `ghostty_config_t` pointer.
    class Config: ObservableObject {
        private(set) var config: ghostty_config_t? {
            didSet {
                guard let old = oldValue else { return }
                ghostty_config_free(old)
            }
        }

        var loaded: Bool { config != nil }

        init() {
            self.config = Self.loadFromDisk()
        }

        /// Wraps an already-loaded config (used during reload).
        init(existing: ghostty_config_t) {
            self.config = existing
        }

        deinit {
            self.config = nil
        }

        // MARK: - Shell integration features

        private static let shellIntegrationFeaturesKey = "shell-integration-features"

        /// The fields of `ShellIntegrationFeatures` in `ghostty/src/config/Config.zig`, in declaration
        /// order: `ghostty_config_get` hands the packed struct back as its bits, least significant first.
        static let shellIntegrationFeatureNames = ["cursor", "sudo", "title", "ssh-env", "ssh-terminfo", "path"]

        static func enabledShellIntegrationFeatures(_ cfg: ghostty_config_t) -> Set<String>? {
            var bits: UInt32 = 0
            let key = shellIntegrationFeaturesKey
            guard ghostty_config_get(cfg, &bits, key, UInt(key.utf8.count)) else { return nil }
            let enabled = shellIntegrationFeatureNames.enumerated().filter { bits & (1 << $0.offset) != 0 }
            return Set(enabled.map(\.element))
        }

        /// The user's Ghostty config files, finalized, with Clearway's overrides applied on top.
        static func loadFromDisk() -> ghostty_config_t? {
            guard let cfg = ghostty_config_new() else {
                logger.critical("ghostty_config_new failed")
                return nil
            }
            ghostty_config_load_default_files(cfg)
            ghostty_config_load_recursive_files(cfg)
            disableShellPathFeature(cfg)
            ghostty_config_finalize(cfg)
            return cfg
        }

        /// The `path` feature appends `Contents/MacOS` to `PATH`, where `clearway` resolves to the app
        /// executable `Clearway` on a case-insensitive volume and opens a second instance.
        ///
        /// libghostty takes config only from files, and its parser resets every feature a line leaves
        /// out to its default, so the line names each of the user's resolved features explicitly.
        static func disableShellPathFeature(_ cfg: ghostty_config_t) {
            let value: String
            if let enabled = enabledShellIntegrationFeatures(cfg) {
                value = shellIntegrationFeatureNames
                    .map { $0 != "path" && enabled.contains($0) ? $0 : "no-\($0)" }
                    .joined(separator: ",")
            } else {
                logger.error("Could not read shell-integration-features; the user's other features fall back to their defaults")
                value = "no-path"
            }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("clearway-ghostty-\(UUID().uuidString).conf")
            do {
                try "\(shellIntegrationFeaturesKey) = \(value)\n".write(to: file, atomically: true, encoding: .utf8)
            } catch {
                logger.error("Could not write the shell-integration override: \(error.localizedDescription, privacy: .public)")
                return
            }
            defer { try? FileManager.default.removeItem(at: file) }
            ghostty_config_load_file(cfg, file.path)
        }
    }
}
