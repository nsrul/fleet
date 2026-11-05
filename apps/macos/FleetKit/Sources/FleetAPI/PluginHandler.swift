import Foundation

public struct FleetPluginEndpoint: Equatable, Sendable {
    public var url: String
    public var claudeConfigPath: String

    public init(url: String, claudeConfigPath: String) {
        self.url = url
        self.claudeConfigPath = claudeConfigPath
    }
}

public struct PluginPreset: Equatable, Sendable {
    public var id: String
    public var binary: String
    public var arguments: [String]

    public init(id: String, binary: String, arguments: [String]) {
        self.id = id
        self.binary = binary
        self.arguments = arguments
    }
}

/// Claude and Codex accept one MCP server for a single launch.
/// Cursor Agent, Gemini CLI, and OpenCode can only add a server by writing
/// their own config files, so those presets are left unwired.
public enum FleetPluginLaunch {
    public static func arguments(presetID: String, endpoint: FleetPluginEndpoint) -> [String] {
        switch presetID {
        case "claude":
            return ["--mcp-config", endpoint.claudeConfigPath]
        case "codex":
            return ["-c", "mcp_servers.fleet.url=\"\(endpoint.url)\""]
        default:
            return []
        }
    }
}

public enum FleetPluginFiles {
    public static func writeClaudeConfig(url: String, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let file = directory.appendingPathComponent("claude-mcp.json")
        let body: [String: Any] = [
            "mcpServers": [
                "fleet": [
                    "type": "http",
                    "url": url,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
        return file
    }

    public static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        let directory = url.deletingLastPathComponent()
        if let children = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
           children.isEmpty {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

public protocol PluginDaemon: Sendable {
    func createSession(_ spec: CreateSession) async throws -> SessionInfo
    func stopSession(id: String) async throws -> SessionExit
    func listTasks(parentID: String?) async throws -> [TaskInfo]
    func putPlan(_ plan: PutPlan) async throws -> PlanInfo
    func getPlan(id: String) async throws -> PlanInfo
}

extension FleetClient: PluginDaemon {}

public struct PluginToolResult: Equatable, Sendable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

public struct PluginHandler: Sendable {
    public var daemon: any PluginDaemon
    public var presets: [PluginPreset]
    public var resolve: @Sendable (String) -> String?
    public var directoryExists: @Sendable (String) -> Bool
    public var endpoint: FleetPluginEndpoint?
    public var uniqueSuffix: @Sendable () -> String

    public init(
        daemon: any PluginDaemon,
        presets: [PluginPreset],
        resolve: @escaping @Sendable (String) -> String?,
        directoryExists: @escaping @Sendable (String) -> Bool,
        endpoint: FleetPluginEndpoint?,
        uniqueSuffix: @escaping @Sendable () -> String
    ) {
        self.daemon = daemon
        self.presets = presets
        self.resolve = resolve
        self.directoryExists = directoryExists
        self.endpoint = endpoint
        self.uniqueSuffix = uniqueSuffix
    }

    public func call(tool: String, arguments: Data) async -> PluginToolResult {
        guard let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            return PluginToolResult(text: "Tool arguments must be a JSON object.", isError: true)
        }
        switch tool {
        case "orchestrate":
            return await orchestrate(object)
        case "watch":
            return await watch(object)
        case "plan":
            return await plan(object)
        default:
            return PluginToolResult(text: "Unknown tool \(tool).", isError: true)
        }
    }

    private func orchestrate(_ object: [String: Any]) async -> PluginToolResult {
        guard let action = string(object, "action") else {
            return fail("action must be create or stop.")
        }
        switch action {
        case "create":
            return await create(object)
        case "stop":
            guard let id = string(object, "session_id") else {
                return fail("stop requires session_id.")
            }
            do {
                let exit = try await daemon.stopSession(id: id)
                return ok([
                    "session_id": id,
                    "success": exit.success,
                    "code": exit.code,
                ])
            } catch {
                return fail(error.localizedDescription)
            }
        default:
            return fail("action must be create or stop.")
        }
    }

    private func create(_ object: [String: Any]) async -> PluginToolResult {
        guard let parentID = string(object, "parent_id") else {
            return fail("Pass FLEET_SESSION_ID as parent_id.")
        }
        let launch: ResolvedLaunch
        do {
            launch = try resolveLaunch(object)
        } catch let error as LaunchFailure {
            return fail(error.message)
        } catch {
            return fail(error.localizedDescription)
        }
        let cwd = launch.cwd
        let sessionID = makeSessionID(hint: string(object, "brief") ?? launch.program)
        let spec = CreateSession(
            id: sessionID,
            program: launch.program,
            args: launch.arguments,
            cwd: cwd,
            env: sessionEnvironment(sessionID: sessionID),
            size: TerminalSize(rows: 24, cols: 80),
            parentID: parentID,
            brief: string(object, "brief")
        )
        do {
            let session = try await daemon.createSession(spec)
            var body: [String: Any] = [
                "session_id": session.id,
                "program": session.program,
                "parent_id": parentID,
            ]
            if let brief = spec.brief { body["brief"] = brief }
            return ok(body)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private func watch(_ object: [String: Any]) async -> PluginToolResult {
        guard let parentID = string(object, "parent_id") else {
            return fail("Pass FLEET_SESSION_ID as parent_id.")
        }
        do {
            let tasks = try await daemon.listTasks(parentID: parentID)
            let data = try JSONEncoder().encode(tasks)
            let text = String(decoding: data, as: UTF8.self)
            return PluginToolResult(text: text, isError: false)
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private func plan(_ object: [String: Any]) async -> PluginToolResult {
        guard let action = string(object, "action") else {
            return fail("action must be put or get.")
        }
        switch action {
        case "get":
            guard let id = string(object, "plan_id") else {
                return fail("get requires plan_id.")
            }
            do {
                let info = try await daemon.getPlan(id: id)
                let data = try JSONEncoder().encode(info)
                return PluginToolResult(text: String(decoding: data, as: UTF8.self), isError: false)
            } catch {
                return fail(error.localizedDescription)
            }
        case "put":
            guard let parentID = string(object, "parent_id") else {
                return fail("Pass FLEET_SESSION_ID as parent_id.")
            }
            guard let rawSteps = object["steps"] as? [[String: Any]], !rawSteps.isEmpty else {
                return fail("put requires at least one step.")
            }
            var steps: [PlanStepSpec] = []
            for raw in rawSteps {
                let launch: ResolvedLaunch
                do {
                    launch = try resolveLaunch(raw)
                } catch let error as LaunchFailure {
                    return fail(error.message)
                } catch {
                    return fail(error.localizedDescription)
                }
                steps.append(PlanStepSpec(
                    program: launch.program,
                    args: launch.arguments,
                    cwd: launch.cwd,
                    env: planStepEnvironment(),
                    brief: string(raw, "brief")
                ))
            }
            do {
                let info = try await daemon.putPlan(PutPlan(parentID: parentID, steps: steps))
                var body: [String: Any] = [
                    "plan_id": info.id,
                    "state": info.state.rawValue,
                ]
                if let sessionID = info.steps.first?.sessionID {
                    body["session_id"] = sessionID
                }
                return ok(body)
            } catch {
                return fail(error.localizedDescription)
            }
        default:
            return fail("action must be put or get.")
        }
    }

    private struct ResolvedLaunch {
        var program: String
        var arguments: [String]
        var cwd: String
    }

    private struct LaunchFailure: Error {
        var message: String
    }

    private func resolveLaunch(_ object: [String: Any]) throws -> ResolvedLaunch {
        let presetName = string(object, "preset")
        let programName = string(object, "program")
        if presetName != nil && programName != nil {
            throw LaunchFailure(message: "Pass a preset or a program, not both.")
        }
        guard let extra = strings(object, "args") else {
            throw LaunchFailure(message: "args must be an array of strings.")
        }
        guard let cwd = string(object, "cwd") else {
            throw LaunchFailure(message: "cwd is required.")
        }
        let expanded = NSString(string: cwd).expandingTildeInPath
        guard directoryExists(expanded) else {
            throw LaunchFailure(message: "The working directory was not found.")
        }

        let preset: PluginPreset?
        let binary: String
        if let presetName {
            guard let found = presets.first(where: { $0.id == presetName }) else {
                throw LaunchFailure(message: "Unknown preset \(presetName).")
            }
            preset = found
            binary = found.binary
        } else if let programName {
            preset = presetID(forProgram: programName).flatMap { id in
                presets.first { $0.id == id }
            }
            binary = programName
        } else {
            throw LaunchFailure(message: "Pass a preset or a program.")
        }

        guard let program = resolve(binary) else {
            let name = (binary as NSString).lastPathComponent
            throw LaunchFailure(message: "\(name) was not found.")
        }
        var arguments = preset?.arguments ?? []
        arguments.append(contentsOf: extra)
        if let endpoint, let id = preset?.id ?? presetID(forProgram: program) {
            arguments.append(contentsOf: FleetPluginLaunch.arguments(presetID: id, endpoint: endpoint))
        }
        return ResolvedLaunch(program: program, arguments: arguments, cwd: expanded)
    }

    private func presetID(forProgram program: String) -> String? {
        let name = (program as NSString).lastPathComponent
        return presets.first { preset in
            preset.binary == name || (preset.binary as NSString).lastPathComponent == name
        }?.id
    }

    private func makeSessionID(hint: String) -> String {
        let slug = Self.slug(hint)
        let suffix = uniqueSuffix().filter { !$0.isWhitespace && !$0.isNewline }
        let raw = "task-\(slug)-\(suffix.isEmpty ? "1" : suffix)"
        if raw.count <= 128 { return raw }
        return String(raw.prefix(128))
    }

    private static func slug(_ raw: String) -> String {
        let mapped = raw.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }
        var base = String(mapped)
        while base.contains("--") {
            base = base.replacingOccurrences(of: "--", with: "-")
        }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "agent" }
        if base.count > 40 { base = String(base.prefix(40)) }
        return base
    }

    private func string(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func strings(_ object: [String: Any], _ key: String) -> [String]? {
        if object[key] == nil { return [] }
        guard let values = object[key] as? [Any] else { return nil }
        var result: [String] = []
        for value in values {
            guard let string = value as? String else { return nil }
            result.append(string)
        }
        return result
    }

    private func ok(_ body: [String: Any]) -> PluginToolResult {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return fail("Could not encode the tool result.")
        }
        return PluginToolResult(text: text, isError: false)
    }

    private func fail(_ message: String) -> PluginToolResult {
        PluginToolResult(text: message, isError: true)
    }
}

public enum PluginRPC {
    public static func respond(to body: Data, handler: PluginHandler) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return error(id: nil, code: -32700, message: "Parse error")
        }
        let id = object["id"]
        let hasID = object.keys.contains("id") && !(id is NSNull)
        guard let method = object["method"] as? String else {
            return hasID ? error(id: id, code: -32600, message: "Invalid request") : nil
        }
        if !hasID {
            return nil
        }
        switch method {
        case "initialize":
            return result(id: id, value: initializeResult(object["params"]))
        case "ping":
            return result(id: id, value: [String: Any]())
        case "tools/list":
            return result(id: id, value: ["tools": toolDefinitions()])
        case "tools/call":
            guard let params = object["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return error(id: id, code: -32602, message: "Invalid params")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let argumentData = try? JSONSerialization.data(withJSONObject: arguments) else {
                return error(id: id, code: -32602, message: "Invalid params")
            }
            let tool = await handler.call(tool: name, arguments: argumentData)
            return result(id: id, value: [
                "content": [["type": "text", "text": tool.text]],
                "isError": tool.isError,
            ])
        default:
            return error(id: id, code: -32601, message: "Method not found")
        }
    }

    private static func initializeResult(_ params: Any?) -> [String: Any] {
        let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
        var version = "2025-03-26"
        if let params = params as? [String: Any],
           let requested = params["protocolVersion"] as? String,
           supported.contains(requested) {
            version = requested
        }
        return [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "fleet", "version": "0.1.0"],
        ]
    }

    private static func toolDefinitions() -> [[String: Any]] { [
        tool(
            name: "orchestrate",
            description: "Create or stop a child session. Pass FLEET_SESSION_ID as parent_id. Use preset or program, not both. A missing program creates no session.",
            properties: [
                "action": ["type": "string", "enum": ["create", "stop"]],
                "preset": ["type": "string"],
                "program": ["type": "string"],
                "args": ["type": "array", "items": ["type": "string"]],
                "cwd": ["type": "string"],
                "brief": ["type": "string"],
                "parent_id": ["type": "string"],
                "session_id": ["type": "string"],
            ],
            required: ["action"]
        ),
        tool(
            name: "watch",
            description: "List child tasks for a parent session. Pass FLEET_SESSION_ID as parent_id. Each task includes daemon status and the sidebar class running, idle, or needs_you.",
            properties: [
                "parent_id": ["type": "string"],
            ],
            required: ["parent_id"]
        ),
        tool(
            name: "plan",
            description: "Store a plan and run its steps in order, or read a plan. Pass FLEET_SESSION_ID as parent_id. Exit 0 marks a step done and starts the next. Any other exit stops the plan.",
            properties: [
                "action": ["type": "string", "enum": ["put", "get"]],
                "parent_id": ["type": "string"],
                "plan_id": ["type": "string"],
                "steps": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "preset": ["type": "string"],
                            "program": ["type": "string"],
                            "args": ["type": "array", "items": ["type": "string"]],
                            "cwd": ["type": "string"],
                            "brief": ["type": "string"],
                        ],
                    ],
                ],
            ],
            required: ["action"]
        ),
    ] }

    private static func tool(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
            ],
        ]
    }

    private static func result(id: Any?, value: Any) -> Data? {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value])
    }

    private static func error(id: Any?, code: Int, message: String) -> Data? {
        encode([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message],
        ])
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }
}
