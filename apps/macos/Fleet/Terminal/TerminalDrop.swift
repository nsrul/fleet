import AppKit

/// Quotes one value for a POSIX shell.
enum ShellEscape {
    /// Wraps `value` in single quotes so spaces, `$`, `~`, and quotes stay
    /// literal. An embedded single quote becomes `'\''`.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Resolves a drag payload into text for a terminal prompt.
enum TerminalDrop {
    /// Text to insert for a drag. File URLs win over the text Finder also puts
    /// on the pasteboard, so dropping a file inserts its path, not its name.
    static func text(from pasteboard: NSPasteboard) -> String? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []
        let paths = urls.filter(\.isFileURL).compactMap(\.path).filter { !$0.isEmpty }
        if !paths.isEmpty {
            return paths.map(ShellEscape.quote).joined(separator: " ")
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            return nil
        }
        return text
    }
}
