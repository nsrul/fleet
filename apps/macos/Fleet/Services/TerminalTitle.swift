import Foundation

/// The title an agent reports through OSC 0/2, as pane and sidebar headers
/// show it.
///
/// Agents use the sequence for the task they are working on. Shells report
/// their own name, which says less than the session ID, so those are ignored.
enum TerminalTitle {
    /// Longest title the headers show. A reported title can be arbitrarily
    /// long, and the headers have one line.
    static let maxLength = 80

    private static let shellNames = ["zsh", "bash", "sh", "fish", "login", "tmux"]

    static func useful(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }

        let lowered = collapsed.lowercased()
        if shellNames.contains(where: {
            lowered == $0 || lowered.hasPrefix("\($0) ") || lowered.hasPrefix("\($0):")
        }) {
            return nil
        }
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength - 1)) + "…"
    }
}
