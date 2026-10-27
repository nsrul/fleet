import Darwin
import Foundation
import XCTest

@testable import DirectorAPI

final class ClientTests: XCTestCase {
    func testHandshakeListAndEvents() async throws {
        let server = try MockServer()
        defer { server.stop() }
        server.start()

        let client = try DirectorClient(path: server.path)
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

    func testConnectionFailureIsReported() throws {
        let path = "/tmp/director-missing-\(UUID().uuidString.prefix(8)).sock"
        XCTAssertThrowsError(try DirectorClient(path: path)) { error in
            guard case DirectorError.connectFailed = error else {
                return XCTFail("expected a connect failure, got \(error)")
            }
        }
    }
}

private final class MockServer: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var task: Task<Void, Never>?

    init() throws {
        path = "/tmp/director-test-\(UUID().uuidString.prefix(8)).sock"
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
        task = Task.detached { [weak self] in
            self?.serve()
        }
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
        task?.cancel()
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
                let request = try JSONSerialization.jsonObject(with: readFrame(client))
                guard let request = request as? [String: Any],
                      request["type"] as? String == "request" else {
                    throw MockError.socket("expected a request frame")
                }
                try writeFrame(client, [
                    "type": "response",
                    "request_id": 1,
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
                ])
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
}

private enum MockError: Error {
    case socket(String)
}

private func readFrame(_ descriptor: Int32) throws -> Data {
    let header = try readExactly(descriptor, count: 4)
    let length = header.reduce(0) { ($0 << 8) | Int($1) }
    guard length > 0, length <= DirectorProtocol.maxPayloadBytes else {
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
