import Foundation

/// Events streamed by the daemon after a successful handshake.
public enum ClientEvent: Sendable {
    case output(sessionID: String, seq: UInt64, data: Data)
    case status(sessionID: String, status: SessionStatus)
    case daemonStopping
    case sessionsChanged
    case workspaceChanged(Workspace)
}

/// An async client for the Fleet local session API.
///
/// The client owns one Unix socket. Requests are multiplexed by `request_id`;
/// output and status events are delivered through ``events``. The read loop
/// performs blocking socket reads on a detached task so the actor stays
/// responsive.
public actor FleetClient {
    /// How long a request waits for a response before the connection is dropped.
    /// Stop waits at most a few seconds; this leaves room for a slow spawn.
    public static let defaultRequestTimeout: Duration = .seconds(10)

    private let socket: UnixSocket
    private let requestTimeout: Duration
    private let eventContinuation: AsyncStream<ClientEvent>.Continuation
    public nonisolated let events: AsyncStream<ClientEvent>
    /// Set when `fail` closes the socket. Nonisolated so the UI can read it
    /// after the event stream ends without hopping back onto this actor.
    nonisolated private let terminalFailure = TerminalFailure()

    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<ResponseData, Error>] = [:]
    private var deadlines: [UInt64: Task<Void, Never>] = [:]
    private var readTask: Task<Void, Never>?
    private var closed = false

    public init(path: String, requestTimeout: Duration = FleetClient.defaultRequestTimeout) throws {
        let socket = try UnixSocket.connect(path: path)
        var continuation: AsyncStream<ClientEvent>.Continuation!
        let stream = AsyncStream<ClientEvent>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        self.socket = socket
        self.requestTimeout = requestTimeout
        self.events = stream
        self.eventContinuation = continuation
    }

    /// Why the socket was closed, once `fail` has run. Nil while the connection is open.
    public nonisolated func terminalError() -> Error? {
        terminalFailure.current()
    }

    /// Performs the hello handshake and starts streaming events.
    public func connect(clientName: String = "fleet-macos") async throws -> Welcome {
        guard !closed else { throw FleetError.socketClosed }
        guard readTask == nil else {
            throw FleetError.unexpectedResponse("this client is already connected")
        }

        let hello = ClientMessage.hello(
            protocolVersion: FleetProtocol.version,
            client: clientName
        )
        try socket.writeFrame(FrameCodec.encodePayload(hello))

        let payload = try socket.readFrame()
        let message = try FrameCodec.decode(ServerMessage.self, from: payload)

        switch message {
        case .welcome(let welcome):
            guard welcome.protocolVersion == FleetProtocol.version else {
                socket.close()
                throw FleetError.protocolMismatch(
                    expected: FleetProtocol.version,
                    received: welcome.protocolVersion
                )
            }
            startReadLoop()
            return welcome
        case .rejected(let error):
            socket.close()
            throw FleetError.rejected(error)
        default:
            socket.close()
            throw FleetError.unexpectedResponse("expected a welcome message")
        }
    }

    public func listSessions() async throws -> [SessionInfo] {
        let data = try await request(.listSessions)
        guard case .sessions(let sessions) = data else {
            throw FleetError.unexpectedResponse("expected a session list")
        }
        return sessions
    }

    public func createSession(_ spec: CreateSession) async throws -> SessionInfo {
        let data = try await request(.createSession(spec))
        guard case .session(let session) = data else {
            throw FleetError.unexpectedResponse("expected a created session")
        }
        return session
    }

    public func inspectSession(id: String) async throws -> SessionInfo {
        let data = try await request(.inspectSession(id: id))
        guard case .session(let session) = data else {
            throw FleetError.unexpectedResponse("expected session metadata")
        }
        return session
    }

    public func stopSession(id: String) async throws -> SessionExit {
        let data = try await request(.stopSession(id: id))
        guard case .exit(let exit) = data else {
            throw FleetError.unexpectedResponse("expected an exit status")
        }
        return exit
    }

    public func removeSession(id: String) async throws {
        let data = try await request(.removeSession(id: id))
        guard case .acknowledged = data else {
            throw FleetError.unexpectedResponse("expected an acknowledgement")
        }
    }

    public func attachSession(id: String) async throws -> AttachedSession {
        let data = try await request(.attachSession(id: id))
        guard case .attached(let attached) = data else {
            throw FleetError.unexpectedResponse("expected an attached session")
        }
        return attached
    }

    public func detachSession(id: String) async throws {
        let data = try await request(.detachSession(id: id))
        guard case .acknowledged = data else {
            throw FleetError.unexpectedResponse("expected an acknowledgement")
        }
    }

    public func input(id: String, data: Data) async throws {
        let response = try await request(.input(id: id, data: data))
        guard case .acknowledged = response else {
            throw FleetError.unexpectedResponse("expected an acknowledgement")
        }
    }

    public func reportPresence(_ report: ReportPresence) async throws {
        let response = try await request(.reportPresence(report))
        guard case .acknowledged = response else {
            throw FleetError.unexpectedResponse("expected an acknowledgement")
        }
    }

    public func listTasks(parentID: String?) async throws -> [TaskInfo] {
        let data = try await request(.listTasks(parentID: parentID))
        guard case .tasks(let tasks) = data else {
            throw FleetError.unexpectedResponse("expected a task list")
        }
        return tasks
    }

    public func putPlan(_ plan: PutPlan) async throws -> PlanInfo {
        let data = try await request(.putPlan(plan))
        guard case .plan(let info) = data else {
            throw FleetError.unexpectedResponse("expected a plan")
        }
        return info
    }

    public func getWorkspace() async throws -> Workspace {
        let data = try await request(.getWorkspace)
        guard case .workspace(let workspace) = data else {
            throw FleetError.unexpectedResponse("expected a workspace")
        }
        return workspace
    }

    public func putWorkspace(_ workspace: Workspace) async throws -> Workspace {
        let data = try await request(.putWorkspace(workspace))
        guard case .workspace(let workspace) = data else {
            throw FleetError.unexpectedResponse("expected a workspace")
        }
        return workspace
    }

    public func getPlan(id: String) async throws -> PlanInfo {
        let data = try await request(.getPlan(id: id))
        guard case .plan(let info) = data else {
            throw FleetError.unexpectedResponse("expected a plan")
        }
        return info
    }

    public func resize(id: String, size: TerminalSize) async throws {
        let response = try await request(.resize(id: id, size: size))
        guard case .acknowledged = response else {
            throw FleetError.unexpectedResponse("expected an acknowledgement")
        }
    }

    public func disconnect() {
        fail(FleetError.socketClosed)
    }

    /// Closes the socket from any context. Used to unblock a handshake timeout.
    public nonisolated func forceClose() {
        socket.close()
    }

    private func request(_ command: Command) async throws -> ResponseData {
        guard !closed else { throw FleetError.socketClosed }

        let requestID = nextRequestID
        nextRequestID &+= 1
        let payload = try FrameCodec.encodePayload(
            ClientMessage.request(requestID: requestID, command: command)
        )

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            do {
                try socket.writeFrame(payload)
            } catch {
                pending.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
                return
            }

            let timeout = requestTimeout
            deadlines[requestID] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.expire(requestID)
            }
        }
    }

    /// A response that never arrives leaves the read loop blocked. Drop the
    /// socket so every waiter unblocks and the UI can reconnect.
    private func expire(_ requestID: UInt64) {
        guard !closed, pending[requestID] != nil else { return }
        fail(FleetError.timeout("waiting for a response"))
    }

    private func takePending(_ requestID: UInt64) -> CheckedContinuation<ResponseData, Error>? {
        deadlines.removeValue(forKey: requestID)?.cancel()
        return pending.removeValue(forKey: requestID)
    }

    private func startReadLoop() {
        let socket = self.socket
        readTask = Task.detached(priority: .userInitiated) { [weak self, socket] in
            while !Task.isCancelled {
                do {
                    let payload = try socket.readFrame()
                    let message = try FrameCodec.decode(ServerMessage.self, from: payload)
                    await self?.receive(message)
                } catch {
                    await self?.fail(error)
                    return
                }
            }
        }
    }

    private func receive(_ message: ServerMessage) {
        switch message {
        case .welcome:
            return
        case .rejected(let error):
            fail(FleetError.rejected(error))
        case .response(let requestID, let result):
            guard let continuation = takePending(requestID) else {
                return
            }
            switch result {
            case .ok(let data):
                continuation.resume(returning: data)
            case .error(let error):
                continuation.resume(throwing: FleetError.api(error))
            }
        case .event(let event):
            switch event {
            case .output(let sessionID, let seq, let data):
                eventContinuation.yield(.output(sessionID: sessionID, seq: seq, data: data))
            case .status(let sessionID, let status):
                eventContinuation.yield(.status(sessionID: sessionID, status: status))
            case .daemonStopping:
                eventContinuation.yield(.daemonStopping)
            case .sessionsChanged:
                eventContinuation.yield(.sessionsChanged)
            case .workspaceChanged(let workspace):
                eventContinuation.yield(.workspaceChanged(workspace))
            }
        }
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        closed = true
        terminalFailure.record(error)
        socket.close()
        readTask?.cancel()
        readTask = nil

        for task in deadlines.values {
            task.cancel()
        }
        deadlines.removeAll()

        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
        eventContinuation.finish()
    }
}

/// The error that closed the socket. Guarded so the UI can read it after the
/// event stream ends without awaiting the client actor.
private final class TerminalFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?

    func record(_ error: Error) {
        lock.lock()
        if value == nil { value = error }
        lock.unlock()
    }

    func current() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
