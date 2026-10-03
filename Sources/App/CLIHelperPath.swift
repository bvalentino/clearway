import Foundation

/// Puts the running bundle's `clearway` helper on every terminal's `PATH`.
enum CLIHelperPath {
    static let directory = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path

    /// First, so the running bundle's helper wins over any other `clearway` an inherited `PATH`
    /// carries — a parent Clearway's, say, when this build was launched from one of its terminals.
    static func prepended(to searchPath: String, directory: String = directory) -> String {
        let others = searchPath.split(separator: ":").map(String.init).filter { $0 != directory }
        return ([directory] + others).joined(separator: ":")
    }

    /// The `PATH` a plain shell surface starts with. libghostty applies it after appending its own
    /// `Contents/MacOS`, so that directory is dropped along with the rest of libghostty's value.
    static var surfaceEnvironment: (key: String, value: String) {
        (key: "PATH", value: prepended(to: ProcessInfo.processInfo.environment["PATH"] ?? ""))
    }
}
