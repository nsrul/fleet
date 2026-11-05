import Foundation

@main
enum CodexControlSocketTestMain {
    static func main() async {
        do {
            try await CodexControlSocketTests.runAll()
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

private final class FailureBox: @unchecked Sendable {
    var message: String?
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    if actual != expected {
        throw CheckFailure(description: "\(label): expected \(expected), got \(actual)")
    }
}

private enum CodexControlSocketTests {
    static func runAll() async throws {
        try socketPathUsesCodexHome()
        try socketPathExpandsTildeInCodexHome()
        try socketPathIgnoresEmptyCodexHome()
        try stateOfMissingPathIsMissing()
        try stateOfRegularFileIsReady()
        try stateOfLiveSymlinkIsReady()
        try stateOfDanglingSymlinkIsDangling()
        try await leavesOtherProgramsAlone()
        try await leavesAMissingSocketAlone()
        try await leavesAReadySocketAlone()
        try await skipsRecoveryWhenNoDaemonWasRequested()
        try await restartKeepsTheOriginalArguments()
        try await failedRestartStartsWithoutTheDaemon()
        try await restartThatLeavesTheSocketDanglingStartsWithoutTheDaemon()
        try await managedRestartRepairsTheSocket()
        try await managedRestartFailureStartsWithoutTheDaemon()
        print("ok")
    }

    static func socketPathUsesCodexHome() throws {
        let path = CodexControlSocket.socketPath(
            environment: ["CODEX_HOME": "/tmp/codex-home"],
            homeDirectory: "/Users/someone"
        )
        try expectEqual(
            path,
            "/tmp/codex-home/app-server-control/app-server-control.sock",
            "CODEX_HOME"
        )
    }

    static func socketPathExpandsTildeInCodexHome() throws {
        let path = CodexControlSocket.socketPath(
            environment: ["CODEX_HOME": "~/codex-alt"],
            homeDirectory: "/Users/someone"
        )
        let home = NSHomeDirectory()
        try expectEqual(
            path,
            "\(home)/codex-alt/app-server-control/app-server-control.sock",
            "tilde CODEX_HOME"
        )
    }

    static func socketPathIgnoresEmptyCodexHome() throws {
        let path = CodexControlSocket.socketPath(
            environment: ["CODEX_HOME": "   "],
            homeDirectory: "/Users/someone"
        )
        try expectEqual(
            path,
            "/Users/someone/.codex/app-server-control/app-server-control.sock",
            "blank CODEX_HOME"
        )
    }

    static func stateOfMissingPathIsMissing() throws {
        let path = try temporaryDirectory().appendingPathComponent("absent.sock").path
        try expectEqual(CodexControlSocket.state(at: path), .missing, "missing")
    }

    static func stateOfRegularFileIsReady() throws {
        let url = try temporaryDirectory()
        let path = url.appendingPathComponent("plain.sock").path
        FileManager.default.createFile(atPath: path, contents: Data())
        try expectEqual(CodexControlSocket.state(at: path), .ready, "regular file")
    }

    static func stateOfLiveSymlinkIsReady() throws {
        let url = try temporaryDirectory()
        let target = url.appendingPathComponent("target").path
        let link = url.appendingPathComponent("sock").path
        FileManager.default.createFile(atPath: target, contents: Data())
        try makeLink(from: link, to: target)
        try expectEqual(CodexControlSocket.state(at: link), .ready, "live symlink")
    }

    static func stateOfDanglingSymlinkIsDangling() throws {
        let url = try temporaryDirectory()
        let link = url.appendingPathComponent("sock").path
        try makeLink(from: link, to: url.appendingPathComponent("gone").path)
        try expectEqual(CodexControlSocket.state(at: link), .dangling, "dangling symlink")
    }

    static func leavesOtherProgramsAlone() async throws {
        let fixture = try danglingHome()
        let launch = try await adjust(program: "/usr/local/bin/claude", home: fixture.home, restart: { _ in
            throw CheckFailure(description: "claude must not restart Codex")
        })
        try expectEqual(launch.arguments, ["resume"], "claude arguments")
        try expectEqual(launch.notice, nil, "claude notice")
    }

    static func leavesAMissingSocketAlone() async throws {
        let home = try temporaryDirectory()
        let launch = try await adjust(program: "/usr/local/bin/codex", home: home.path, restart: { _ in
            throw CheckFailure(description: "a missing socket is Codex's first launch")
        })
        try expectEqual(launch, CodexLaunch(arguments: ["resume"], notice: nil), "missing socket")
    }

    static func leavesAReadySocketAlone() async throws {
        let fixture = try danglingHome()
        FileManager.default.createFile(atPath: fixture.target, contents: Data())
        let launch = try await adjust(program: "/usr/local/bin/codex", home: fixture.home, restart: { _ in
            throw CheckFailure(description: "a live socket must not be restarted")
        })
        try expectEqual(launch, CodexLaunch(arguments: ["resume"], notice: nil), "ready socket")
    }

    static func skipsRecoveryWhenNoDaemonWasRequested() async throws {
        let fixture = try danglingHome()
        let launch = await CodexControlSocket.adjust(
            program: "/usr/local/bin/codex",
            arguments: ["--no-daemon", "resume"],
            environment: ["CODEX_HOME": fixture.home],
            homeDirectory: "/unused",
            readyTimeout: 0,
            restart: { _ in
                preconditionFailure("--no-daemon must not restart Codex")
            }
        )
        try expectEqual(
            launch,
            CodexLaunch(arguments: ["--no-daemon", "resume"], notice: nil),
            "--no-daemon"
        )
    }

    static func restartKeepsTheOriginalArguments() async throws {
        let fixture = try danglingHome()
        let launch = try await adjust(program: "/Users/someone/.local/bin/codex", home: fixture.home) { program in
            try expectEqual(program, "/Users/someone/.local/bin/codex", "restart program")
            FileManager.default.createFile(atPath: fixture.target, contents: Data())
            return true
        }
        try expectEqual(launch.arguments, ["resume"], "arguments after restart")
        try expectEqual(launch.notice, CodexControlSocket.restartedNotice, "restart notice")
    }

    static func failedRestartStartsWithoutTheDaemon() async throws {
        let fixture = try danglingHome()
        let launch = try await adjust(program: "/usr/local/bin/codex", home: fixture.home) { _ in
            false
        }
        try expectEqual(launch.arguments, ["--no-daemon", "resume"], "fallback arguments")
        try expectEqual(launch.notice, CodexControlSocket.fallbackNotice, "fallback notice")
    }

    static func restartThatLeavesTheSocketDanglingStartsWithoutTheDaemon() async throws {
        let fixture = try danglingHome()
        let launch = try await adjust(
            program: "/usr/local/bin/codex",
            home: fixture.home,
            readyTimeout: 0
        ) { _ in
            true
        }
        try expectEqual(launch.arguments, ["--no-daemon", "resume"], "still dangling")
        try expectEqual(launch.notice, CodexControlSocket.fallbackNotice, "still dangling notice")
    }

    static func managedRestartRepairsTheSocket() async throws {
        let fixture = try danglingHome()
        let program = try executable(named: "codex", body: """
        #!/bin/sh
        if [ "$1" = app-server ] && [ "$2" = daemon ] && [ "$3" = restart ]; then
          : > '\(fixture.target)'
          exit 0
        fi
        exit 2
        """)
        let launch = await CodexControlSocket.adjust(
            program: program,
            arguments: ["resume"],
            environment: ["CODEX_HOME": fixture.home],
            homeDirectory: "/unused",
            readyTimeout: 2,
            restart: nil
        )
        try expectEqual(launch.arguments, ["resume"], "managed restart arguments")
        try expectEqual(launch.notice, CodexControlSocket.restartedNotice, "managed restart notice")
    }

    static func managedRestartFailureStartsWithoutTheDaemon() async throws {
        let fixture = try danglingHome()
        let program = try executable(named: "codex", body: """
        #!/bin/sh
        exit 1
        """)
        let launch = await CodexControlSocket.adjust(
            program: program,
            arguments: ["resume"],
            environment: ["CODEX_HOME": fixture.home],
            homeDirectory: "/unused",
            readyTimeout: 0,
            restart: nil
        )
        try expectEqual(launch.arguments, ["--no-daemon", "resume"], "failed managed restart")
        try expectEqual(launch.notice, CodexControlSocket.fallbackNotice, "failed managed restart notice")
    }

    private static func executable(named name: String, body: String) throws -> String {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private struct Home {
        var home: String
        var target: String
    }

    private static func danglingHome() throws -> Home {
        let home = try temporaryDirectory()
        let directory = home.appendingPathComponent("app-server-control", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = home.appendingPathComponent("missing-socket").path
        let link = directory.appendingPathComponent("app-server-control.sock").path
        try makeLink(from: link, to: target)
        return Home(home: home.path, target: target)
    }

    private static func adjust(
        program: String,
        home: String,
        readyTimeout: TimeInterval = 1,
        restart: @escaping @Sendable (String) async throws -> Bool
    ) async throws -> CodexLaunch {
        let failure = FailureBox()
        let launch = await CodexControlSocket.adjust(
            program: program,
            arguments: ["resume"],
            environment: ["CODEX_HOME": home],
            homeDirectory: "/unused",
            readyTimeout: readyTimeout,
            restart: { program in
                do {
                    return try await restart(program)
                } catch {
                    failure.message = error.localizedDescription
                    return false
                }
            }
        )
        if let message = failure.message {
            throw CheckFailure(description: message)
        }
        return launch
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-codex-socket-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeLink(from path: String, to target: String) throws {
        if symlink(target, path) != 0 {
            throw CheckFailure(description: "symlink: \(String(cString: strerror(errno)))")
        }
    }
}
