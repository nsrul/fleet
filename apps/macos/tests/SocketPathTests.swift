import Foundation

@main
enum SocketPathTestMain {
    static func main() {
        do {
            try SocketPathTests.runAll()
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

/// Connection phase plus the stored socket. `submit` matches
/// `AppModel.connectUsingPath`: a rejected draft returns before reconnect.
private struct ConnectionSnapshot: Equatable {
    var phase: String
    var socketPath: String
}

private func submit(_ draft: String, connection: inout ConnectionSnapshot) {
    guard case .accept(let path) = SocketPath.decide(draft) else { return }
    connection.socketPath = path
    connection.phase = "idle"
}

private enum SocketPathTests {
    static func runAll() throws {
        try invalidSubmissionLeavesConnectionUnchanged()
        try blankDraftsShareOneMessage()
        try usablePathReconnectsAndExpandsTilde()
        print("ok")
    }

    static func invalidSubmissionLeavesConnectionUnchanged() throws {
        let before = ConnectionSnapshot(phase: "connected", socketPath: "/tmp/live.sock")
        for draft in ["", " ", "   ", "\n", "\t", " \n\t "] {
            var connection = before
            submit(draft, connection: &connection)
            try expectEqual(connection, before, "draft \(draft.debugDescription)")
            try expectEqual(SocketPath.decide(draft), .reject, "decide \(draft.debugDescription)")
        }
    }

    static func blankDraftsShareOneMessage() throws {
        for draft in ["", " ", "\n"] {
            try expectEqual(
                SocketPath.validationMessage(for: draft),
                SocketPath.blankMessage,
                "message \(draft.debugDescription)"
            )
            try expectEqual(SocketPath.canSubmit(draft), false, "submit \(draft.debugDescription)")
        }
    }

    static func usablePathReconnectsAndExpandsTilde() throws {
        var connection = ConnectionSnapshot(phase: "connected", socketPath: "/tmp/live.sock")
        submit("  /tmp/other.sock  ", connection: &connection)
        try expectEqual(
            connection,
            ConnectionSnapshot(phase: "idle", socketPath: "/tmp/other.sock"),
            "trimmed path"
        )
        try expectEqual(SocketPath.validationMessage(for: "/tmp/other.sock"), nil, "valid message")

        var homeConnection = ConnectionSnapshot(phase: "connected", socketPath: "/tmp/live.sock")
        submit("~/fleet.sock", connection: &homeConnection)
        try expectEqual(
            homeConnection,
            ConnectionSnapshot(phase: "idle", socketPath: "\(NSHomeDirectory())/fleet.sock"),
            "tilde"
        )
    }
}
