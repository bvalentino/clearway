import Foundation
import os
import GhosttyKit

/// Root namespace for all Ghostty wrapper types.
enum Ghostty {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.getclearway.mac", category: "ghostty")
}

