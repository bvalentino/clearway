import Foundation

extension Ghostty {
    /// Utilities for shell-safe string handling.
    enum Shell {
        // Newline is intentionally excluded: `\<newline>` is a line-continuation
        // sequence in POSIX shells (the newline is removed during parsing), so
        // escaping it would silently corrupt paths rather than preserve them.
        // Matches the upstream Ghostty.app set.
        private static let escapeCharacters: [Character] = [
            "\\", " ", "\t",
            "(", ")", "[", "]", "{", "}", "<", ">",
            "\"", "'", "`",
            "!", "#", "$", "&", ";", "|", "*", "?"
        ]

        /// Backslash-escape shell metacharacters for injection into a live terminal
        /// (typing-at-the-cursor semantics). Use this for drag-drop / paste into a
        /// `SurfaceView`. For building shell commands in Swift, prefer
        /// ``shellEscape(_:)`` (single-quote wrapping).
        static func escape(_ s: String) -> String {
            var result = s
            for ch in escapeCharacters {
                result = result.replacingOccurrences(of: String(ch), with: "\\\(ch)")
            }
            return result
        }
    }
}
