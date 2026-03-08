import SwiftUI

enum SettingsKey {
    static let mainTerminalCommand = "wtpad.mainTerminalCommand"
}

/// Manages user preferences, persisted via UserDefaults.
@MainActor
class SettingsManager: ObservableObject {
    @Published var mainTerminalCommand: String {
        didSet {
            if mainTerminalCommand.count > 256 {
                mainTerminalCommand = String(mainTerminalCommand.prefix(256))
                return
            }
            if mainTerminalCommand.isEmpty {
                UserDefaults.standard.removeObject(forKey: SettingsKey.mainTerminalCommand)
            } else {
                UserDefaults.standard.set(mainTerminalCommand, forKey: SettingsKey.mainTerminalCommand)
            }
        }
    }

    init() {
        self.mainTerminalCommand = UserDefaults.standard.string(forKey: SettingsKey.mainTerminalCommand) ?? ""
    }
}
