import XCTest

@testable import FleetAPI

final class SessionForkTests: XCTestCase {
    func testShellLoginFlagIsKept() {
        XCTAssertEqual(SessionFork.arguments(["-l"], presetID: "shell"), ["-l"])
    }

    func testForkKeepsUserArgumentsAndDropsTheTrailingPluginFlags() {
        XCTAssertEqual(
            SessionFork.arguments(
                ["--resume", "--mcp-config", "/tmp/fleet/claude.json"],
                presetID: "claude"
            ),
            ["--resume"]
        )
        XCTAssertEqual(
            SessionFork.arguments(
                ["-c", "mcp_servers.fleet.url=\"http://127.0.0.1:1/\""],
                presetID: "codex"
            ),
            []
        )
        XCTAssertEqual(
            SessionFork.arguments(
                ["--no-daemon", "-c", "mcp_servers.fleet.url=\"http://127.0.0.1:1/\""],
                presetID: "codex"
            ),
            [],
            "the daemon fallback is decided again at launch"
        )
        XCTAssertEqual(
            SessionFork.arguments(["--standalone"], presetID: "opencode"),
            []
        )
    }

    func testAnArgumentThatLooksLikeThePluginFlagStays() {
        // Only the pair Fleet appends is removed, so a user's own config
        // survives.
        XCTAssertEqual(
            SessionFork.arguments(
                ["--mcp-config", "/mine", "--mcp-config", "/fleet"],
                presetID: "claude"
            ),
            ["--mcp-config", "/mine"]
        )
    }

    func testAnUnknownProgramKeepsEveryArgument() {
        XCTAssertEqual(
            SessionFork.arguments(["--standalone", "-l"], presetID: nil),
            ["--standalone", "-l"]
        )
    }

    func testForkRebuildsTheSessionEnvironment() {
        let env = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "FLEET_SESSION_ID": "one",
            "GEMINI_CLI_SYSTEM_SETTINGS_PATH": "/tmp/one.json",
            "OPENCODE_CONFIG_CONTENT": "{}",
            "PATH": "/usr/bin",
            "HTTPS_PROXY": "http://proxy",
        ]
        XCTAssertEqual(
            SessionFork.environment(env),
            ["PATH": "/usr/bin", "HTTPS_PROXY": "http://proxy"]
        )
    }
}
