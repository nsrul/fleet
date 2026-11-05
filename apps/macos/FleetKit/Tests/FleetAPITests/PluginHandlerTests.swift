import Foundation
import XCTest

@testable import FleetAPI

final class PluginHandlerTests: XCTestCase {
    func testToolsCallTheDaemon() async throws {
        let stub = StubDaemon()
        let endpoint = FleetPluginEndpoint(
            url: "http://127.0.0.1:9/mcp/token",
            claudeConfigPath: "/tmp/fleet-plugin-test/claude-mcp.json"
        )
        let handler = PluginHandler(
            daemon: stub,
            presets: [
                PluginPreset(id: "claude", binary: "claude", arguments: []),
                PluginPreset(id: "codex", binary: "codex", arguments: []),
                PluginPreset(id: "cursor", binary: "cursor-agent", arguments: []),
                PluginPreset(id: "gemini", binary: "gemini", arguments: []),
                PluginPreset(id: "opencode", binary: "opencode", arguments: []),
                PluginPreset(id: "shell", binary: "/bin/zsh", arguments: ["-l"]),
            ],
            resolve: { name in
                switch (name as NSString).lastPathComponent {
                case "claude": return "/opt/homebrew/bin/claude"
                case "codex": return "/opt/homebrew/bin/codex"
                default: return nil
                }
            },
            directoryExists: { _ in true },
            endpoint: endpoint,
            uniqueSuffix: { "1" }
        )

        let created = await handler.call(tool: "orchestrate", arguments: json("""
        {"action":"create","preset":"claude","cwd":"/tmp/work","parent_id":"parent","brief":"watch this"}
        """))
        XCTAssertFalse(created.isError)
        let session = try XCTUnwrap(stub.created.first)
        XCTAssertEqual(session.program, "/opt/homebrew/bin/claude")
        XCTAssertEqual(session.args, ["--mcp-config", endpoint.claudeConfigPath])
        XCTAssertFalse(session.args.contains("--strict-mcp-config"))
        XCTAssertFalse(endpoint.claudeConfigPath.hasPrefix("/tmp/work/"))
        XCTAssertNotEqual(endpoint.claudeConfigPath, "/tmp/work")
        XCTAssertEqual(session.cwd, "/tmp/work")
        XCTAssertEqual(session.parentID, "parent")
        XCTAssertEqual(session.brief, "watch this")
        XCTAssertEqual(session.env["FLEET_SESSION_ID"], session.id)
        XCTAssertEqual(session.env["TERM"], "xterm-256color")
        XCTAssertEqual(session.env["COLORTERM"], "truecolor")
        XCTAssertEqual(session.size.rows, 24)
        XCTAssertEqual(session.size.cols, 80)

        let rejected = await handler.call(tool: "orchestrate", arguments: json("""
        {"action":"create","preset":"claude","program":"codex","cwd":"/tmp/work","parent_id":"parent"}
        """))
        XCTAssertTrue(rejected.isError)
        XCTAssertEqual(stub.created.count, 1)

        let watched = await handler.call(tool: "watch", arguments: json("""
        {"parent_id":"parent"}
        """))
        XCTAssertFalse(watched.isError)
        XCTAssertEqual(stub.listed, ["parent"])

        let planned = await handler.call(tool: "plan", arguments: json("""
        {"action":"put","parent_id":"parent","steps":[{"preset":"claude","cwd":"/tmp/work","brief":"first"},{"program":"codex","cwd":"/tmp/work","brief":"second"}]}
        """))
        XCTAssertFalse(planned.isError)
        let plan = try XCTUnwrap(stub.plans.first)
        XCTAssertEqual(plan.parentID, "parent")
        XCTAssertEqual(plan.steps.map(\.program), ["/opt/homebrew/bin/claude", "/opt/homebrew/bin/codex"])
        XCTAssertEqual(plan.steps[0].args, ["--mcp-config", endpoint.claudeConfigPath])
        XCTAssertFalse(plan.steps[0].args.contains("--strict-mcp-config"))
        XCTAssertEqual(plan.steps[1].args, ["-c", "mcp_servers.fleet.url=\"\(endpoint.url)\""])
        XCTAssertEqual(plan.steps[0].env["TERM"], "xterm-256color")
        XCTAssertNil(plan.steps[0].env["FLEET_SESSION_ID"])
        XCTAssertEqual(plan.steps[0].brief, "first")
        XCTAssertEqual(stub.plans.count, 1)

        let text = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(planned.text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(text["plan_id"] as? String, "plan-1")
        XCTAssertEqual(text["session_id"] as? String, "plan-1-1")
    }

    func testClaudeLaunchArgumentsStayOutOfTheWorkingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-plugin-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try FleetPluginFiles.writeClaudeConfig(
            url: "http://127.0.0.1:9/mcp/token",
            directory: directory
        )
        let cwd = "/tmp/work"
        XCTAssertFalse(file.path.hasPrefix(cwd + "/"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let servers = object?["mcpServers"] as? [String: Any]
        XCTAssertEqual(servers?.keys.sorted(), ["fleet"])
        let endpoint = FleetPluginEndpoint(url: "http://127.0.0.1:9/mcp/token", claudeConfigPath: file.path)
        let args = FleetPluginLaunch.arguments(presetID: "claude", endpoint: endpoint)
        XCTAssertEqual(args, ["--mcp-config", file.path])
        XCTAssertFalse(args.contains("--strict-mcp-config"))
        XCTAssertEqual(FleetPluginLaunch.arguments(presetID: "cursor", endpoint: endpoint), [])
        XCTAssertEqual(FleetPluginLaunch.arguments(presetID: "gemini", endpoint: endpoint), [])
        XCTAssertEqual(FleetPluginLaunch.arguments(presetID: "opencode", endpoint: endpoint), [])
        XCTAssertEqual(FleetPluginLaunch.arguments(presetID: "shell", endpoint: endpoint), [])
    }

    private func json(_ text: String) -> Data {
        Data(text.utf8)
    }
}

private final class StubDaemon: PluginDaemon, @unchecked Sendable {
    private let lock = NSLock()
    private var createdStorage: [CreateSession] = []
    private var listedStorage: [String] = []
    private var plansStorage: [PutPlan] = []

    var created: [CreateSession] {
        lock.lock()
        defer { lock.unlock() }
        return createdStorage
    }

    var listed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return listedStorage
    }

    var plans: [PutPlan] {
        lock.lock()
        defer { lock.unlock() }
        return plansStorage
    }

    func createSession(_ spec: CreateSession) async throws -> SessionInfo {
        record(spec)
        return SessionInfo(
            id: spec.id,
            pid: 1,
            program: spec.program,
            cwd: spec.cwd,
            size: spec.size,
            status: .running
        )
    }

    func stopSession(id: String) async throws -> SessionExit {
        SessionExit(success: true, code: 0)
    }

    func listTasks(parentID: String?) async throws -> [TaskInfo] {
        recordList(parentID)
        return [
            TaskInfo(
                sessionID: "child",
                parentID: parentID,
                brief: "watch this",
                status: .running,
                sidebar: .idle
            ),
        ]
    }

    func putPlan(_ plan: PutPlan) async throws -> PlanInfo {
        recordPlan(plan)
        return PlanInfo(
            id: "plan-1",
            parentID: plan.parentID,
            state: .running,
            steps: [
                PlanStepInfo(index: 0, state: .running, sessionID: "plan-1-1", brief: plan.steps.first?.brief),
            ]
        )
    }

    func getPlan(id: String) async throws -> PlanInfo {
        PlanInfo(id: id, parentID: "parent", state: .running, steps: [])
    }

    private func record(_ spec: CreateSession) {
        lock.lock()
        createdStorage.append(spec)
        lock.unlock()
    }

    private func recordList(_ parentID: String?) {
        lock.lock()
        if let parentID { listedStorage.append(parentID) }
        lock.unlock()
    }

    private func recordPlan(_ plan: PutPlan) {
        lock.lock()
        plansStorage.append(plan)
        lock.unlock()
    }
}
