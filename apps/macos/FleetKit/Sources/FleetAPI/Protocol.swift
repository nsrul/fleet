import Foundation

/// Versioned vocabulary for the Fleet local session API.
///
/// The wire format is a four-byte big-endian length followed by UTF-8 JSON.
/// Binary terminal data is base64 encoded by Foundation's `Data` codable
/// conformance. See `crates/protocol/src/api.rs` for the Rust definitions.
public enum FleetProtocol {
    public static let version: UInt32 = 1
    public static let maxFrameBytes = 4 * 1024 * 1024
    public static let maxPayloadBytes = maxFrameBytes - 4
    public static let maxSocketPathBytes = 100
    /// Welcome capability for task, plan, and presence commands.
    public static let tasksCapability = "tasks"
    /// Welcome capability for the daemon-owned tab layout.
    public static let workspaceCapability = "workspace"
}

public struct TerminalSize: Codable, Equatable, Sendable {
    public var rows: UInt16
    public var cols: UInt16
    public var pixelWidth: UInt16
    public var pixelHeight: UInt16

    public init(rows: UInt16, cols: UInt16, pixelWidth: UInt16 = 0, pixelHeight: UInt16 = 0) {
        self.rows = rows
        self.cols = cols
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    private enum CodingKeys: String, CodingKey {
        case rows
        case cols
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decode(UInt16.self, forKey: .rows)
        cols = try container.decode(UInt16.self, forKey: .cols)
        pixelWidth = try container.decodeIfPresent(UInt16.self, forKey: .pixelWidth) ?? 0
        pixelHeight = try container.decodeIfPresent(UInt16.self, forKey: .pixelHeight) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rows, forKey: .rows)
        try container.encode(cols, forKey: .cols)
        try container.encode(pixelWidth, forKey: .pixelWidth)
        try container.encode(pixelHeight, forKey: .pixelHeight)
    }
}

public struct CreateSession: Codable, Equatable, Sendable {
    public var id: String
    public var program: String
    public var args: [String]
    public var cwd: String
    public var env: [String: String]
    public var size: TerminalSize
    public var parentID: String?
    public var brief: String?

    public init(
        id: String,
        program: String,
        args: [String] = [],
        cwd: String,
        env: [String: String] = [:],
        size: TerminalSize = TerminalSize(rows: 24, cols: 80),
        parentID: String? = nil,
        brief: String? = nil
    ) {
        self.id = id
        self.program = program
        self.args = args
        self.cwd = cwd
        self.env = env
        self.size = size
        self.parentID = parentID
        self.brief = brief
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case program
        case args
        case cwd
        case env
        case size
        case parentID = "parent_id"
        case brief
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        program = try container.decode(String.self, forKey: .program)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        cwd = try container.decode(String.self, forKey: .cwd)
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        size = try container.decodeIfPresent(TerminalSize.self, forKey: .size)
            ?? TerminalSize(rows: 24, cols: 80)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        brief = try container.decodeIfPresent(String.self, forKey: .brief)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(program, forKey: .program)
        try container.encode(args, forKey: .args)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(env, forKey: .env)
        try container.encode(size, forKey: .size)
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encodeIfPresent(brief, forKey: .brief)
    }
}

public enum Command: Encodable, Sendable {
    case createSession(CreateSession)
    case listSessions
    case inspectSession(id: String)
    case stopSession(id: String)
    case removeSession(id: String)
    case input(id: String, data: Data)
    case resize(id: String, size: TerminalSize)
    case attachSession(id: String)
    case detachSession(id: String)
    case reportPresence(ReportPresence)
    case listTasks(parentID: String?)
    case putPlan(PutPlan)
    case getPlan(id: String)
    case getWorkspace
    case putWorkspace(Workspace)

    private enum CodingKeys: String, CodingKey {
        case command
        case params
    }

    private struct SessionID: Encodable {
        let id: String
    }

    private struct Input: Encodable {
        let id: String
        let data: Data
    }

    private struct Resize: Encodable {
        let id: String
        let size: TerminalSize
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .createSession(let spec):
            try container.encode("create_session", forKey: .command)
            try container.encode(spec, forKey: .params)
        case .listSessions:
            try container.encode("list_sessions", forKey: .command)
        case .inspectSession(let id):
            try container.encode("inspect_session", forKey: .command)
            try container.encode(SessionID(id: id), forKey: .params)
        case .stopSession(let id):
            try container.encode("stop_session", forKey: .command)
            try container.encode(SessionID(id: id), forKey: .params)
        case .removeSession(let id):
            try container.encode("remove_session", forKey: .command)
            try container.encode(SessionID(id: id), forKey: .params)
        case .input(let id, let data):
            try container.encode("input", forKey: .command)
            try container.encode(Input(id: id, data: data), forKey: .params)
        case .resize(let id, let size):
            try container.encode("resize", forKey: .command)
            try container.encode(Resize(id: id, size: size), forKey: .params)
        case .attachSession(let id):
            try container.encode("attach_session", forKey: .command)
            try container.encode(SessionID(id: id), forKey: .params)
        case .detachSession(let id):
            try container.encode("detach_session", forKey: .command)
            try container.encode(SessionID(id: id), forKey: .params)
        case .reportPresence(let report):
            try container.encode("report_presence", forKey: .command)
            try container.encode(report, forKey: .params)
        case .listTasks(let parentID):
            try container.encode("list_tasks", forKey: .command)
            try container.encode(ListTasksParams(parentID: parentID), forKey: .params)
        case .putPlan(let plan):
            try container.encode("put_plan", forKey: .command)
            try container.encode(plan, forKey: .params)
        case .getPlan(let id):
            try container.encode("get_plan", forKey: .command)
            try container.encode(SessionID(id: id), forKey: .params)
        case .getWorkspace:
            try container.encode("get_workspace", forKey: .command)
        case .putWorkspace(let workspace):
            try container.encode("put_workspace", forKey: .command)
            try container.encode(PutWorkspaceParams(workspace: workspace), forKey: .params)
        }
    }
}

private struct PutWorkspaceParams: Encodable {
    let workspace: Workspace
}

private struct ListTasksParams: Encodable {
    var parentID: String?

    private enum CodingKeys: String, CodingKey {
        case parentID = "parent_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(parentID, forKey: .parentID)
    }
}

public enum ClientMessage: Encodable, Sendable {
    case hello(protocolVersion: UInt32, client: String?)
    case request(requestID: UInt64, command: Command)

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case client
        case requestID = "request_id"
        case command
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let version, let client):
            try container.encode("hello", forKey: .type)
            try container.encode(version, forKey: .protocolVersion)
            try container.encodeIfPresent(client, forKey: .client)
        case .request(let requestID, let command):
            try container.encode("request", forKey: .type)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(command, forKey: .command)
        }
    }
}

public struct Welcome: Equatable, Sendable {
    public let protocolVersion: UInt32
    public let daemonVersion: String
    public let engineState: String
    public let capabilities: [String]

    public init(
        protocolVersion: UInt32,
        daemonVersion: String,
        engineState: String,
        capabilities: [String] = []
    ) {
        self.protocolVersion = protocolVersion
        self.daemonVersion = daemonVersion
        self.engineState = engineState
        self.capabilities = capabilities
    }
}

public struct SessionExit: Codable, Equatable, Sendable {
    public let success: Bool
    public let code: UInt32
    public let signal: String?

    public init(success: Bool, code: UInt32, signal: String? = nil) {
        self.success = success
        self.code = code
        self.signal = signal
    }
}

public enum SessionStatus: Codable, Equatable, Sendable {
    case running
    case exited(SessionExit)

    private enum CodingKeys: String, CodingKey {
        case exited
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.exited) {
            self = .exited(try container.decode(SessionExit.self, forKey: .exited))
            return
        }

        let single = try decoder.singleValueContainer()
        let value = try single.decode(String.self)
        guard value == "running" else {
            throw DecodingError.dataCorruptedError(
                in: single,
                debugDescription: "unknown session status \(value)"
            )
        }
        self = .running
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .running:
            var single = encoder.singleValueContainer()
            try single.encode("running")
        case .exited(let exit):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(exit, forKey: .exited)
        }
    }
}

public struct SessionInfo: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let pid: UInt32?
    public let program: String
    /// Arguments passed after the program.
    public let args: [String]
    public let cwd: String
    /// Environment variables the client set for this session. The daemon's own
    /// environment is not included.
    public let env: [String: String]
    public let size: TerminalSize
    public let status: SessionStatus

    public init(
        id: String,
        pid: UInt32?,
        program: String,
        args: [String] = [],
        cwd: String,
        env: [String: String] = [:],
        size: TerminalSize,
        status: SessionStatus
    ) {
        self.id = id
        self.pid = pid
        self.program = program
        self.args = args
        self.cwd = cwd
        self.env = env
        self.size = size
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case pid
        case program
        case args
        case cwd
        case env
        case size
        case status
    }

    /// A daemon that predates `args` and `env` omits them. Reading the session
    /// list must still work against one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        pid = try container.decodeIfPresent(UInt32.self, forKey: .pid)
        program = try container.decode(String.self, forKey: .program)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        cwd = try container.decode(String.self, forKey: .cwd)
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        size = try container.decode(TerminalSize.self, forKey: .size)
        status = try container.decode(SessionStatus.self, forKey: .status)
    }

    public var isRunning: Bool {
        if case .running = status { return true }
        return false
    }
}

public struct OutputSnapshot: Codable, Equatable, Sendable {
    public let data: Data
    public let firstSeq: UInt64?
    public let nextSeq: UInt64
    public let truncated: Bool

    public init(data: Data, firstSeq: UInt64?, nextSeq: UInt64, truncated: Bool) {
        self.data = data
        self.firstSeq = firstSeq
        self.nextSeq = nextSeq
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey {
        case data
        case firstSeq = "first_seq"
        case nextSeq = "next_seq"
        case truncated
    }
}

public struct AttachedSession: Codable, Equatable, Sendable {
    public let session: SessionInfo
    public let output: OutputSnapshot

    public init(session: SessionInfo, output: OutputSnapshot) {
        self.session = session
        self.output = output
    }
}

public struct ReportPresence: Codable, Equatable, Sendable {
    public var id: String
    public var active: Bool
    public var needsAttention: Bool

    public init(id: String, active: Bool, needsAttention: Bool) {
        self.id = id
        self.active = active
        self.needsAttention = needsAttention
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case active
        case needsAttention = "needs_attention"
    }
}

/// Sidebar class shared by the app filter and `list_tasks`.
public enum SidebarClass: String, Codable, Equatable, Sendable {
    case running
    case idle
    case needsYou = "needs_you"
}

public enum StepState: String, Codable, Equatable, Sendable {
    case waiting
    case running
    case done
    case failed
}

public enum PlanState: String, Codable, Equatable, Sendable {
    case running
    case done
    case failed
}

public struct PlanStepSpec: Codable, Equatable, Sendable {
    public var program: String
    public var args: [String]
    public var cwd: String
    public var env: [String: String]
    public var brief: String?

    public init(
        program: String,
        args: [String] = [],
        cwd: String,
        env: [String: String] = [:],
        brief: String? = nil
    ) {
        self.program = program
        self.args = args
        self.cwd = cwd
        self.env = env
        self.brief = brief
    }

    private enum CodingKeys: String, CodingKey {
        case program
        case args
        case cwd
        case env
        case brief
    }
}

public struct PutPlan: Codable, Equatable, Sendable {
    public var parentID: String
    public var steps: [PlanStepSpec]

    public init(parentID: String, steps: [PlanStepSpec]) {
        self.parentID = parentID
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case parentID = "parent_id"
        case steps
    }
}

public struct TaskInfo: Codable, Equatable, Sendable {
    public var sessionID: String
    public var parentID: String?
    public var brief: String?
    public var status: SessionStatus
    public var sidebar: SidebarClass
    public var planID: String?
    public var stepIndex: UInt32?
    public var stepState: StepState?

    public init(
        sessionID: String,
        parentID: String? = nil,
        brief: String? = nil,
        status: SessionStatus,
        sidebar: SidebarClass,
        planID: String? = nil,
        stepIndex: UInt32? = nil,
        stepState: StepState? = nil
    ) {
        self.sessionID = sessionID
        self.parentID = parentID
        self.brief = brief
        self.status = status
        self.sidebar = sidebar
        self.planID = planID
        self.stepIndex = stepIndex
        self.stepState = stepState
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case parentID = "parent_id"
        case brief
        case status
        case sidebar
        case planID = "plan_id"
        case stepIndex = "step_index"
        case stepState = "step_state"
    }
}

public struct PlanStepInfo: Codable, Equatable, Sendable {
    public var index: UInt32
    public var state: StepState
    public var sessionID: String?
    public var brief: String?

    public init(index: UInt32, state: StepState, sessionID: String? = nil, brief: String? = nil) {
        self.index = index
        self.state = state
        self.sessionID = sessionID
        self.brief = brief
    }

    private enum CodingKeys: String, CodingKey {
        case index
        case state
        case sessionID = "session_id"
        case brief
    }
}

public struct PlanInfo: Codable, Equatable, Sendable {
    public var id: String
    public var parentID: String
    public var state: PlanState
    public var steps: [PlanStepInfo]

    public init(id: String, parentID: String, state: PlanState, steps: [PlanStepInfo]) {
        self.id = id
        self.parentID = parentID
        self.state = state
        self.steps = steps
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case parentID = "parent_id"
        case state
        case steps
    }
}

/// Needs you wins. A live session with recent output is Running. Everything else is Idle.
public func sidebarClass(status: SessionStatus, active: Bool, needsAttention: Bool) -> SidebarClass {
    let failed: Bool
    if case .exited(let exit) = status {
        failed = !exit.success
    } else {
        failed = false
    }
    if needsAttention || failed {
        return .needsYou
    }
    if case .running = status, active {
        return .running
    }
    return .idle
}

/// The presence report to send, when the daemon advertised the tasks capability.
public func presenceReport(
    capabilities: [String],
    sessionID: String,
    active: Bool,
    needsAttention: Bool
) -> ReportPresence? {
    guard capabilities.contains(FleetProtocol.tasksCapability) else { return nil }
    return ReportPresence(id: sessionID, active: active, needsAttention: needsAttention)
}

/// Environment for a session the app or the plugin starts. The brief is not included.
public func sessionEnvironment(sessionID: String) -> [String: String] {
    [
        "TERM": "xterm-256color",
        "COLORTERM": "truecolor",
        "FLEET_SESSION_ID": sessionID,
    ]
}

/// Environment stored on a plan step. The daemon adds `FLEET_SESSION_ID` when it assigns the id.
public func planStepEnvironment() -> [String: String] {
    [
        "TERM": "xterm-256color",
        "COLORTERM": "truecolor",
    ]
}

public enum ResponseData: Sendable {
    case session(SessionInfo)
    case sessions([SessionInfo])
    case exit(SessionExit)
    case attached(AttachedSession)
    case acknowledged
    case tasks([TaskInfo])
    case plan(PlanInfo)
    case workspace(Workspace)
}

extension ResponseData: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "session":
            self = .session(try container.decode(SessionInfo.self, forKey: .value))
        case "sessions":
            self = .sessions(try container.decode([SessionInfo].self, forKey: .value))
        case "exit":
            self = .exit(try container.decode(SessionExit.self, forKey: .value))
        case "attached":
            self = .attached(try container.decode(AttachedSession.self, forKey: .value))
        case "acknowledged":
            self = .acknowledged
        case "tasks":
            self = .tasks(try container.decode([TaskInfo].self, forKey: .value))
        case "plan":
            self = .plan(try container.decode(PlanInfo.self, forKey: .value))
        case "workspace":
            self = .workspace(try container.decode(Workspace.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown response kind \(kind)"
            )
        }
    }
}

public struct ApiError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum ResponseResult: Sendable {
    case ok(ResponseData)
    case error(ApiError)
}

extension ResponseResult: Decodable {
    private enum CodingKeys: String, CodingKey {
        case status
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        switch status {
        case "ok":
            self = .ok(try container.decode(ResponseData.self, forKey: .data))
        case "error":
            self = .error(try container.decode(ApiError.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "unknown response status \(status)"
            )
        }
    }
}

public enum Event: Decodable, Sendable {
    case output(sessionID: String, seq: UInt64, data: Data)
    case status(sessionID: String, status: SessionStatus)
    case daemonStopping
    case sessionsChanged
    case workspaceChanged(Workspace)

    private enum CodingKeys: String, CodingKey {
        case event
        case sessionID = "session_id"
        case seq
        case data
        case status
        case workspace
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let event = try container.decode(String.self, forKey: .event)
        switch event {
        case "output":
            self = .output(
                sessionID: try container.decode(String.self, forKey: .sessionID),
                seq: try container.decode(UInt64.self, forKey: .seq),
                data: try container.decode(Data.self, forKey: .data)
            )
        case "status":
            self = .status(
                sessionID: try container.decode(String.self, forKey: .sessionID),
                status: try container.decode(SessionStatus.self, forKey: .status)
            )
        case "daemon_stopping":
            self = .daemonStopping
        case "sessions_changed":
            self = .sessionsChanged
        case "workspace_changed":
            self = .workspaceChanged(try container.decode(Workspace.self, forKey: .workspace))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .event,
                in: container,
                debugDescription: "unknown event \(event)"
            )
        }
    }
}

public enum ServerMessage: Decodable, Sendable {
    case welcome(Welcome)
    case rejected(ApiError)
    case response(requestID: UInt64, result: ResponseResult)
    case event(Event)

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case daemonVersion = "daemon_version"
        case engineState = "engine_state"
        case capabilities
        case error
        case requestID = "request_id"
        case result
        case event
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "welcome":
            self = .welcome(
                Welcome(
                    protocolVersion: try container.decode(UInt32.self, forKey: .protocolVersion),
                    daemonVersion: try container.decode(String.self, forKey: .daemonVersion),
                    engineState: try container.decode(String.self, forKey: .engineState),
                    capabilities: try container.decodeIfPresent(
                        [String].self,
                        forKey: .capabilities
                    ) ?? []
                )
            )
        case "rejected":
            self = .rejected(try container.decode(ApiError.self, forKey: .error))
        case "response":
            self = .response(
                requestID: try container.decode(UInt64.self, forKey: .requestID),
                result: try container.decode(ResponseResult.self, forKey: .result)
            )
        case "event":
            self = .event(try container.decode(Event.self, forKey: .event))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown server message type \(type)"
            )
        }
    }
}

public enum FleetError: Error, LocalizedError, Sendable {
    case socketPathTooLong(Int)
    case connectFailed(path: String, code: Int32, message: String)
    case socketClosed
    case frameTooLarge(Int)
    case invalidFrame(String)
    case protocolMismatch(expected: UInt32, received: UInt32)
    case rejected(ApiError)
    case api(ApiError)
    case unexpectedResponse(String)
    case timeout(String)
    case daemonUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let length):
            return "The socket path is \(length) bytes; Unix socket paths must be at most 100 bytes."
        case .connectFailed(let path, let code, let message):
            return "Could not connect to \(path) (errno \(code)): \(message)"
        case .socketClosed:
            return "The daemon closed the connection."
        case .frameTooLarge(let size):
            return "A protocol frame was \(size) bytes, above the 4 MiB limit."
        case .invalidFrame(let message):
            return "Invalid protocol frame: \(message)"
        case .protocolMismatch(let expected, let received):
            return "The daemon speaks protocol \(received); Fleet needs protocol \(expected)."
        case .rejected(let error):
            return "The daemon rejected the connection: \(error.message)"
        case .api(let error):
            return "\(error.code): \(error.message)"
        case .unexpectedResponse(let message):
            return "Unexpected daemon response: \(message)"
        case .timeout(let operation):
            return "Timed out while \(operation)."
        case .daemonUnavailable(let message):
            return message
        }
    }
}

public enum FleetPaths {
    /// The stable socket the macOS app and demo scripts use by default.
    public static var defaultSocketPath: String {
        if let override = ProcessInfo.processInfo.environment["FLEET_SOCKET"], !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return NSString(string: "~/.fleet/daemon.sock").expandingTildeInPath
    }

    /// The daemon's own default when no `--socket` flag is supplied.
    public static var daemonDefaultSocketPath: String {
        if let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !runtime.isEmpty {
            return (runtime as NSString).appendingPathComponent("fleet/daemon.sock")
        }
        let temp = ProcessInfo.processInfo.environment["TMPDIR"]
            ?? FileManager.default.temporaryDirectory.path
        return (temp as NSString).appendingPathComponent("fleet-\(getuid())/daemon.sock")
    }
}
