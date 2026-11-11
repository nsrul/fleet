import Darwin
import Foundation
import XCTest

@testable import FleetAPI

final class ClientTests: XCTestCase {
    func testHandshakeListAndEvents() async throws {
        let server = try MockServer()
        defer { server.stop() }
        server.start()

        let client = try FleetClient(path: server.path)
        let welcome = try await client.connect(clientName: "unit-test")
        XCTAssertEqual(welcome.protocolVersion, 1)
        XCTAssertEqual(welcome.daemonVersion, "test")

        let sessions = try await client.listSessions()
        XCTAssertEqual(sessions.map(\.id), ["one"])
        XCTAssertEqual(sessions.first?.status, .running)

        var iterator = client.events.makeAsyncIterator()
        let event = await iterator.next()
        guard case .output(let sessionID, let seq, let data)? = event else {
            return XCTFail("expected an output event, got \(String(describing: event))")
        }
        XCTAssertEqual(sessionID, "one")
        XCTAssertEqual(seq, 0)
        XCTAssertEqual(data, Data("hello".utf8))

        await client.disconnect()
    }

    func testDefaultRequestTimeoutIsTenSeconds() {
        XCTAssertEqual(FleetClient.defaultRequestTimeout, .seconds(10))
    }

    func testRequestTimeoutWhenServerNeverResponds() async throws {
        let server = try MockServer(hangAfterRequest: true)
        defer { server.stop() }
        server.start()

        let timeout: Duration = .milliseconds(200)
        let client = try FleetClient(path: server.path, requestTimeout: timeout)
        _ = try await client.connect(clientName: "unit-test")
        XCTAssertNil(client.terminalError())

        let started = Date()
        let outcome = await takeSessions(client)
        let elapsed = Date().timeIntervalSince(started)

        guard case .timeout(let operation) = fleetError(outcome) else {
            return XCTFail("expected FleetError.timeout, got \(outcome)")
        }
        XCTAssertEqual(operation, "waiting for a response")
        XCTAssertEqual(
            FleetError.timeout(operation).localizedDescription,
            "Timed out while waiting for a response."
        )
        // The configured deadline is what fired: not immediately, and not the 10s default.
        XCTAssertGreaterThanOrEqual(elapsed, 0.12)
        XCTAssertLessThan(elapsed, 1)

        guard let closed = client.terminalError() as? FleetError, case .timeout = closed else {
            return XCTFail("expected the connection to close with a timeout, got \(String(describing: client.terminalError()))")
        }

        var iterator = client.events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertNil(event, "the event stream should finish so the UI can reconnect")

        let followUp = Date()
        let again = await takeSessions(client, limit: .seconds(1))
        guard case .socketClosed = fleetError(again) else {
            return XCTFail("expected FleetError.socketClosed, got \(again)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(followUp), 0.5)
    }

    func testTimeoutFailsEveryPendingRequest() async throws {
        let server = try MockServer(hangAfterRequest: true)
        defer { server.stop() }
        server.start()

        // The deadline has to outlast scheduling the second call. On a busy
        // runner a 400ms timeout closed the socket before that write landed.
        let client = try FleetClient(path: server.path, requestTimeout: .seconds(4))
        _ = try await client.connect(clientName: "unit-test")

        async let first = takeSessions(client, limit: .seconds(8))
        let sawFirst = await server.waitUntilRequests(1, timeout: 2)
        guard sawFirst else {
            return XCTFail("the server saw \(server.requestCount()) requests")
        }
        async let second = takeSessions(client, limit: .seconds(8))
        let sawSecond = await server.waitUntilRequests(2, timeout: 2)
        guard sawSecond else {
            return XCTFail("the server saw \(server.requestCount()) requests before the deadline")
        }
        let outcomes = await [first, second]

        for outcome in outcomes {
            guard case .timeout = fleetError(outcome) else {
                return XCTFail("expected every pending request to time out, got \(outcome)")
            }
        }
    }

    func testReplyBeforeTheDeadlineLeavesTheSocketOpen() async throws {
        let server = try MockServer(replies: 2)
        defer { server.stop() }
        server.start()

        let client = try FleetClient(path: server.path, requestTimeout: .milliseconds(300))
        _ = try await client.connect(clientName: "unit-test")

        let first = await takeSessions(client)
        guard case .sessions(let ids) = first else {
            return XCTFail("expected a session list, got \(first)")
        }
        XCTAssertEqual(ids, ["one"])

        // Past the deadline. A timer that was not cancelled would drop the socket here.
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertNil(client.terminalError())

        let second = await takeSessions(client)
        guard case .sessions(let secondIDs) = second else {
            return XCTFail("expected a second session list, got \(second)")
        }
        XCTAssertEqual(secondIDs, ["one"])
        XCTAssertNil(client.terminalError())
    }

    func testLateResponseDoesNotReplaceTheTimeout() async throws {
        let server = try MockServer(respondAfter: 0.7)
        defer { server.stop() }
        server.start()

        let client = try FleetClient(path: server.path, requestTimeout: .milliseconds(200))
        _ = try await client.connect(clientName: "unit-test")

        let started = Date()
        let outcome = await takeSessions(client)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        guard case .timeout = fleetError(outcome) else {
            return XCTFail("expected a timeout before the late reply, got \(outcome)")
        }

        try await Task.sleep(for: .milliseconds(800))
        guard let closed = client.terminalError() as? FleetError, case .timeout = closed else {
            return XCTFail("a late frame must not replace the timeout, got \(String(describing: client.terminalError()))")
        }
    }

    func testConnectionFailureIsReported() throws {
        let path = "/tmp/fleet-missing-\(UUID().uuidString.prefix(8)).sock"
        XCTAssertThrowsError(try FleetClient(path: path)) { error in
            guard case FleetError.connectFailed = error else {
                return XCTFail("expected a connect failure, got \(error)")
            }
        }
    }
}

private enum RequestOutcome: CustomStringConvertible {
    case sessions([String])
    case failed(Error)
    case hung

    var description: String {
        switch self {
        case .sessions(let ids):
            return "sessions \(ids)"
        case .failed(let error):
            return "failed \(error)"
        case .hung:
            return "hung"
        }
    }
}

/// Runs `listSessions` until it finishes, or returns `.hung` when `limit` elapses.
private func fleetError(_ outcome: RequestOutcome) -> FleetError? {
    guard case .failed(let error) = outcome else { return nil }
    return error as? FleetError
}

private func takeSessions(
    _ client: FleetClient,
    limit: Duration = .seconds(5)
) async -> RequestOutcome {
    await withTaskGroup(of: RequestOutcome.self) { group in
        group.addTask {
            do {
                let sessions = try await client.listSessions()
                return .sessions(sessions.map(\.id))
            } catch {
                return .failed(error)
            }
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return .hung
        }
        let outcome = await group.next() ?? .hung
        group.cancelAll()
        return outcome
    }
}

private final class MockServer: @unchecked Sendable {
    let path: String
    private let hangAfterRequest: Bool
    private let replies: Int
    private let respondAfter: TimeInterval
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var requestsSeen = 0

    init(hangAfterRequest: Bool = false, replies: Int = 1, respondAfter: TimeInterval = 0) throws {
        self.hangAfterRequest = hangAfterRequest
        self.replies = replies
        self.respondAfter = respondAfter
        path = "/tmp/fleet-test-\(UUID().uuidString.prefix(8)).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw MockError.socket("socket: \(String(cString: strerror(errno)))")
        }

        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: pathCapacity
            ) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = byte
                }
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(listener, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            close(listener)
            throw MockError.socket("bind: \(message)")
        }
        guard listen(listener, 4) == 0 else {
            let message = String(cString: strerror(errno))
            close(listener)
            throw MockError.socket("listen: \(message)")
        }
    }

    deinit {
        stop()
    }

    func start() {
        // A blocking read on the cooperative pool starves the client tasks
        // that are supposed to write the next request. Use a real thread.
        let thread = Thread { [weak self] in
            self?.serve()
        }
        thread.name = "fleet-mock-server"
        thread.start()
    }

    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        close(listener)
        unlink(path)
    }

    func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestsSeen
    }

    func waitUntilRequests(_ count: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if requestCount() >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return requestCount() >= count
    }

    private func noteRequest() {
        lock.lock()
        requestsSeen += 1
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func serve() {
        while !isStopped {
            var pollDescriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }

            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }

            var noSignal: Int32 = 1
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            )

            do {
                let hello = try JSONSerialization.jsonObject(with: readFrame(client))
                guard let hello = hello as? [String: Any], hello["type"] as? String == "hello" else {
                    throw MockError.socket("expected a hello frame")
                }
                try writeFrame(client, [
                    "type": "welcome",
                    "protocol_version": 1,
                    "daemon_version": "test",
                    "engine_state": "running",
                ])
                var answered = 0
                while answered < replies {
                    let request = try readRequest(client)
                    noteRequest()
                    if hangAfterRequest {
                        try drainUntilStopped(client)
                        return
                    }
                    if respondAfter > 0 {
                        let deadline = Date().addingTimeInterval(respondAfter)
                        while !isStopped, Date() < deadline {
                            Thread.sleep(forTimeInterval: 0.02)
                        }
                        if isStopped { return }
                    }
                    try writeFrame(client, sessionListResponse(requestID: requestID(in: request)))
                    answered += 1
                }
                try writeFrame(client, [
                    "type": "event",
                    "event": [
                        "event": "output",
                        "session_id": "one",
                        "seq": 0,
                        "data": Data("hello".utf8).base64EncodedString(),
                    ],
                ])
                // Give the client's read loop time to consume the event.
                Thread.sleep(forTimeInterval: 0.2)
            } catch {
                return
            }
        }
    }

    private func readRequest(_ descriptor: Int32) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: readFrame(descriptor))
        guard let request = object as? [String: Any], request["type"] as? String == "request" else {
            throw MockError.socket("expected a request frame")
        }
        return request
    }

    /// Reads further requests until the test stops the server or the client hangs up.
    private func drainUntilStopped(_ descriptor: Int32) throws {
        while !isStopped {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }
            if pollDescriptor.revents & Int16(POLLIN) == 0 {
                return
            }
            _ = try readRequest(descriptor)
            noteRequest()
        }
    }
}

private enum MockError: Error {
    case socket(String)
}

private func requestID(in request: [String: Any]) -> Int {
    (request["request_id"] as? NSNumber)?.intValue ?? 1
}

private func sessionListResponse(requestID: Int) -> [String: Any] {
    [
        "type": "response",
        "request_id": requestID,
        "result": [
            "status": "ok",
            "data": [
                "kind": "sessions",
                "value": [[
                    "id": "one",
                    "pid": 42,
                    "program": "/bin/sh",
                    "cwd": "/tmp",
                    "size": ["rows": 24, "cols": 80, "pixel_width": 0, "pixel_height": 0],
                    "status": "running",
                ]],
            ],
        ],
    ]
}

private func readFrame(_ descriptor: Int32) throws -> Data {
    let header = try readExactly(descriptor, count: 4)
    let length = header.reduce(0) { ($0 << 8) | Int($1) }
    guard length > 0, length <= FleetProtocol.maxPayloadBytes else {
        throw MockError.socket("invalid frame length \(length)")
    }
    return try readExactly(descriptor, count: length)
}

private func readExactly(_ descriptor: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
        let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return Darwin.read(descriptor, base.advanced(by: offset), count - offset)
        }
        if bytesRead == 0 {
            throw MockError.socket("unexpected EOF")
        }
        if bytesRead < 0 {
            if errno == EINTR { continue }
            throw MockError.socket("read: \(String(cString: strerror(errno)))")
        }
        offset += bytesRead
    }
    return data
}

private func writeFrame(_ descriptor: Int32, _ object: [String: Any]) throws {
    let payload = try JSONSerialization.data(withJSONObject: object)
    var frame = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)

    var offset = 0
    while offset < frame.count {
        let written = frame.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return Darwin.write(descriptor, base.advanced(by: offset), frame.count - offset)
        }
        if written < 0 {
            if errno == EINTR { continue }
            throw MockError.socket("write: \(String(cString: strerror(errno)))")
        }
        if written == 0 {
            throw MockError.socket("short write")
        }
        offset += written
    }
}
