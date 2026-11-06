import Foundation

public struct FleetPluginEndpoint: Equatable, Sendable {
    public var url: String
    /// File passed to Claude Code through `--mcp-config`.
    public var claudeConfigPath: String
    /// File passed to Gemini CLI through `GEMINI_CLI_SYSTEM_SETTINGS_PATH`.
    public var geminiSettingsPath: String?
    /// Inline JSON passed to OpenCode through `OPENCODE_CONFIG_CONTENT`.
    public var opencodeConfig: String?

    public init(
        url: String,
        claudeConfigPath: String,
        geminiSettingsPath: String? = nil,
        opencodeConfig: String? = nil
    ) {
        self.url = url
        self.claudeConfigPath = claudeConfigPath
        self.geminiSettingsPath = geminiSettingsPath
        self.opencodeConfig = opencodeConfig
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

/// Launch-time arguments and environment that point one agent CLI at the
/// plugin. `FleetPluginLaunch.spec` is the only place that knows how a preset
/// accepts an MCP server, so UI launches and agent-spawned sessions stay equal.
public struct FleetPluginSpec: Equatable, Sendable {
    public var arguments: [String]
    public var environment: [String: String]

    public init(arguments: [String] = [], environment: [String: String] = [:]) {
        self.arguments = arguments
        self.environment = environment
    }

    public var isEmpty: Bool {
        arguments.isEmpty && environment.isEmpty
    }

    /// Layers the plugin environment over a session environment.
    public func applying(to base: [String: String]) -> [String: String] {
        base.merging(environment) { _, plugin in plugin }
    }
}

/// How each preset receives the plugin.
///
/// Claude Code and Codex take a server for one launch on the command line.
/// Gemini CLI and OpenCode read their servers from configuration, so Fleet
/// points a process-scoped environment variable at a temporary file or inline
/// JSON instead of editing the user's own configuration.
public enum FleetPluginLaunch {
    public static func spec(presetID: String, endpoint: FleetPluginEndpoint) -> FleetPluginSpec {
        switch presetID {
        case "claude":
            return FleetPluginSpec(arguments: ["--mcp-config", endpoint.claudeConfigPath])
        case "codex":
            return FleetPluginSpec(arguments: ["-c", "mcp_servers.fleet.url=\"\(endpoint.url)\""])
        case "gemini":
            guard let path = endpoint.geminiSettingsPath else { return FleetPluginSpec() }
            return FleetPluginSpec(
                environment: [FleetPluginFiles.geminiSystemSettingsEnvironmentKey: path]
            )
        case "opencode":
            guard let config = endpoint.opencodeConfig else { return FleetPluginSpec() }
            // A shared OpenCode background service ignores the environment of
            // the client that attaches to it. `--standalone` starts a private
            // server in this process, which reads OPENCODE_CONFIG_CONTENT.
            return FleetPluginSpec(
                arguments: ["--standalone"],
                environment: ["OPENCODE_CONFIG_CONTENT": config]
            )
        default:
            return FleetPluginSpec()
        }
    }
}

public enum FleetPluginFiles {
    public static let geminiSystemSettingsEnvironmentKey = "GEMINI_CLI_SYSTEM_SETTINGS_PATH"

    /// The system settings file Gemini CLI would read, honoring a path the
    /// app itself inherited.
    public static func geminiSystemSettingsPath(environment: [String: String]) -> URL {
        if let path = environment[geminiSystemSettingsEnvironmentKey], !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
        return URL(fileURLWithPath: "/Library/Application Support/GeminiCli/settings.json")
    }

    public static func writeClaudeConfig(url: String, directory: URL) throws -> URL {
        try prepareDirectory(directory)
        let file = directory.appendingPathComponent("claude-mcp.json")
        try write(
            [
                "mcpServers": [
                    "fleet": [
                        "type": "http",
                        "url": url,
                    ],
                ],
            ],
            to: file
        )
        return file
    }

    /// Adds Fleet to Gemini CLI's system settings without dropping the settings
    /// an administrator already installed. Returns nil when that file exists
    /// but cannot be read, rather than shadowing it for the session.
    public static func writeGeminiSettings(
        url: String,
        directory: URL,
        systemSettings: URL?
    ) throws -> URL? {
        var root: [String: Any] = [:]
        if let systemSettings, FileManager.default.fileExists(atPath: systemSettings.path) {
            guard let data = try? Data(contentsOf: systemSettings),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            root = object
        }
        var servers: [String: Any]
        if let existing = root["mcpServers"] {
            guard let object = existing as? [String: Any] else { return nil }
            servers = object
        } else {
            servers = [:]
        }
        servers["fleet"] = ["httpUrl": url]
        root["mcpServers"] = servers
        try prepareDirectory(directory)
        let file = directory.appendingPathComponent("gemini-settings.json")
        try write(root, to: file)
        return file
    }

    /// Inline OpenCode configuration. This is the v1 schema, which OpenCode v2
    /// still normalizes into `mcp.servers`.
    public static func opencodeConfig(url: String) -> String {
        let root: [String: Any] = [
            "mcp": [
                "fleet": [
                    "type": "remote",
                    "url": url,
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    public static func remove(_ urls: [URL]) {
        var directories = Set<String>()
        for url in urls {
            try? FileManager.default.removeItem(at: url)
            directories.insert(url.deletingLastPathComponent().path)
        }
        for path in directories {
            if let children = try? FileManager.default.contentsOfDirectory(atPath: path),
               children.isEmpty {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    private static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private static func write(_ object: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
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
            env: launch.spec.applying(to: sessionEnvironment(sessionID: sessionID)),
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
                    env: launch.spec.applying(to: planStepEnvironment()),
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
        var spec: FleetPluginSpec
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
        var spec = FleetPluginSpec()
        if let endpoint, let id = preset?.id ?? presetID(forProgram: program) {
            spec = FleetPluginLaunch.spec(presetID: id, endpoint: endpoint)
            arguments.append(contentsOf: spec.arguments)
        }
        return ResolvedLaunch(program: program, arguments: arguments, spec: spec, cwd: expanded)
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
