import Foundation

@main
enum TerminalTitleTestMain {
    static func main() {
        do {
            try TerminalTitleTests.runAll()
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }
}

private struct CheckFailure: Error, CustomStringConvertible, LocalizedError {
    var description: String
    var errorDescription: String? { description }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    if actual != expected {
        throw CheckFailure(description: "\(label): expected \(expected), got \(actual)")
    }
}

private enum TerminalTitleTests {
    static func runAll() throws {
        try reportedTitlesAreShown()
        try shellNamesFallBack()
        try shellPrefixIsNotAShellName()
        try whitespaceIsCollapsed()
        try longTitlesAreShortened()
        print("ok")
    }

    static func reportedTitlesAreShown() throws {
        try expectEqual(
            TerminalTitle.useful("Review the diff"),
            "Review the diff",
            "plain title"
        )
    }

    /// Shells report their own name. That is less useful than the session ID,
    /// so the header falls back to the ID.
    static func shellNamesFallBack() throws {
        for raw in ["zsh", "BASH", "sh", "fish", "login", "tmux", "zsh: something", "  sh  "] {
            try expectEqual(TerminalTitle.useful(raw), nil, "shell \(raw.debugDescription)")
        }
        try expectEqual(TerminalTitle.useful(""), nil, "empty")
        try expectEqual(TerminalTitle.useful(" \n\t "), nil, "blank")
    }

    static func shellPrefixIsNotAShellName() throws {
        try expectEqual(
            TerminalTitle.useful("shipping the fix"),
            "shipping the fix",
            "task that starts with a shell name"
        )
        try expectEqual(
            TerminalTitle.useful("zsh-completion cleanup"),
            "zsh-completion cleanup",
            "hyphenated task"
        )
    }

    /// OSC titles can carry newlines, which a one-line header cannot show.
    static func whitespaceIsCollapsed() throws {
        try expectEqual(
            TerminalTitle.useful("  fix\n\tthe\ttests  "),
            "fix the tests",
            "collapsed whitespace"
        )
    }

    static func longTitlesAreShortened() throws {
        let raw = String(repeating: "a", count: TerminalTitle.maxLength + 20)
        let shortened = try unwrap(TerminalTitle.useful(raw))
        try expectEqual(shortened.count, TerminalTitle.maxLength, "length")
        try expectEqual(shortened.hasSuffix("…"), true, "ellipsis")
    }
}

private func unwrap(_ value: String?) throws -> String {
    guard let value else { throw CheckFailure(description: "expected a title, got nil") }
    return value
}
