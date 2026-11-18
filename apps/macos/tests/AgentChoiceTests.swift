import Foundation

@main
enum AgentChoiceTestMain {
    static func main() {
        do {
            try AgentChoiceTests.runAll()
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

private enum AgentChoiceTests {
    static let candidates = ["claude", "codex", "cursor", "gemini", "opencode", "shell", "custom"]

    static func runAll() throws {
        try aMachineWithoutClaudeOpensOnAnInstalledAgent()
        try theLastUsedAgentWinsWhileItIsInstalled()
        try lastUsedFallsBackToTheFirstInstalledAgent()
        try customIsNeverChosenAsTheLastUsedAgent()
        try nothingInstalledOpensOnCustom()
        try withoutACustomTileTheFirstCandidateStandsIn()
        try noCandidatesMeansNoChoice()
        print("ok")
    }

    /// The acceptance case: Claude is absent, Shell is available.
    static func aMachineWithoutClaudeOpensOnAnInstalledAgent() throws {
        try expectEqual(
            AgentChoice.initialPresetID(
                candidates: candidates,
                available: ["shell", "custom"],
                lastUsed: nil,
                customID: "custom"
            ),
            "shell",
            "minimal PATH"
        )
        try expectEqual(
            AgentChoice.initialPresetID(
                candidates: candidates,
                available: ["codex", "shell", "custom"],
                lastUsed: nil,
                customID: "custom"
            ),
            "codex",
            "first installed in sheet order"
        )
    }

    static func theLastUsedAgentWinsWhileItIsInstalled() throws {
        try expectEqual(
            AgentChoice.initialPresetID(
                candidates: candidates,
                available: ["claude", "shell", "custom"],
                lastUsed: "shell",
                customID: "custom"
            ),
            "shell",
            "last used, still installed"
        )
    }

    static func lastUsedFallsBackToTheFirstInstalledAgent() throws {
        try expectEqual(
            AgentChoice.initialPresetID(
                candidates: candidates,
                available: ["gemini", "custom"],
                lastUsed: "claude",
                customID: "custom"
            ),
            "gemini",
            "last used, since uninstalled"
        )
    }

    /// Custom has no program until the user types one, so opening on it would
    /// leave Create disabled.
    static func customIsNeverChosenAsTheLastUsedAgent() throws {
        try expectEqual(
            AgentChoice.initialPresetID(
                candidates: candidates,
                available: ["claude", "custom"],
                lastUsed: "custom",
                customID: "custom"
            ),
            "claude",
            "custom as last used"
        )
    }

    static func nothingInstalledOpensOnCustom() throws {
        try expectEqual(
            AgentChoice.initialPresetID(
                candidates: candidates,
                available: ["custom"],
                lastUsed: nil,
                customID: "custom"
            ),
            "custom",
            "nothing installed"
        )
    }

    static func withoutACustomTileTheFirstCandidateStandsIn() throws {
        try expectEqual(
            AgentChoice.initialPresetID(
                candidates: ["claude", "shell"],
                available: ["shell"],
                lastUsed: nil,
                customID: "custom"
            ),
            "shell",
            "no custom tile, installed agent"
        )
        try expectEqual(
            AgentChoice.initialPresetID(
                candidates: ["claude", "shell"],
                available: [],
                lastUsed: nil,
                customID: "custom"
            ),
            "claude",
            "no custom tile, nothing installed"
        )
    }

    static func noCandidatesMeansNoChoice() throws {
        try expectEqual(
            AgentChoice.initialPresetID(
                candidates: [],
                available: ["claude"],
                lastUsed: "claude",
                customID: "custom"
            ),
            nil,
            "empty candidate list"
        )
    }
}
