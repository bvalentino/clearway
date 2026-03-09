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
            guard let cfg = ghostty_config_new() else {
                logger.critical("ghostty_config_new failed")
                self.config = nil
                return
            }

            // Load default config files (~/.config/ghostty/config,
            // ~/Library/Application Support/com.mitchellh.ghostty/config)
            ghostty_config_load_default_files(cfg)
            ghostty_config_load_recursive_files(cfg)

            // Finalize to fill in defaults
            ghostty_config_finalize(cfg)

            self.config = cfg
        }

        /// Wraps an already-loaded config (used during reload).
        init(existing: ghostty_config_t) {
            self.config = existing
        }

        deinit {
            self.config = nil
        }
    }
}
