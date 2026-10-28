import Foundation
import XCTest

@testable import DirectorAPI

final class ProtocolTests: XCTestCase {
    func testHelloEncodesWithSnakeCaseKeys() throws {
        let message = ClientMessage.hello(protocolVersion: 1, client: "test")
        let object = try jsonObject(FrameCodec.encode(message))
        XCTAssertEqual(object["type"] as? String, "hello")
        XCTAssertEqual(object["protocol_version"] as? Int, 1)
        XCTAssertEqual(object["client"] as? String, "test")
    }

    func testCreateSessionRequestMatchesTheRustShape() throws {
        let spec = CreateSession(
            id: "one",
            program: "/bin/sh",
            args: ["-c", "true"],
            cwd: "/tmp",
            env: ["TERM": "xterm-256color"],
            size: TerminalSize(rows: 24, cols: 80)
        )
        let message = ClientMessage.request(requestID: 7, command: .createSession(spec))
        let object = try jsonObject(FrameCodec.encode(message))

        XCTAssertEqual(object["type"] as? String, "request")
        XCTAssertEqual(object["request_id"] as? Int, 7)
        let command = try XCTUnwrap(object["command"] as? [String: Any])
        XCTAssertEqual(command["command"] as? String, "create_session")
        let params = try XCTUnwrap(command["params"] as? [String: Any])
        XCTAssertEqual(params["id"] as? String, "one")
        XCTAssertEqual(params["program"] as? String, "/bin/sh")
        XCTAssertEqual(params["args"] as? [String], ["-c", "true"])
        XCTAssertEqual(params["cwd"] as? String, "/tmp")
        XCTAssertEqual((params["env"] as? [String: String])?["TERM"], "xterm-256color")
        let size = try XCTUnwrap(params["size"] as? [String: Any])
        XCTAssertEqual(size["rows"] as? Int, 24)
        XCTAssertEqual(size["cols"] as? Int, 80)
        XCTAssertEqual(size["pixel_width"] as? Int, 0)
    }

    func testUnitCommandsHaveAStableShape() throws {
        let object = try jsonObject(
            FrameCodec.encode(ClientMessage.request(requestID: 1, command: .listSessions))
        )
        let command = try XCTUnwrap(object["command"] as? [String: Any])
        XCTAssertEqual(command["command"] as? String, "list_sessions")
        XCTAssertNil(command["params"])
    }

    func testWelcomeDecodes() throws {
        let payload = Data("""
        {"type":"welcome","protocol_version":1,"daemon_version":"0.1.0","engine_state":"running"}
        """.utf8)
        let message = try FrameCodec.decode(ServerMessage.self, from: payload)
        guard case .welcome(let welcome) = message else {
            return XCTFail("expected welcome")
        }
        XCTAssertEqual(welcome.protocolVersion, 1)
        XCTAssertEqual(welcome.daemonVersion, "0.1.0")
        XCTAssertEqual(welcome.engineState, "running")
        XCTAssertTrue(welcome.capabilities.isEmpty)
    }

    func testWelcomeDecodesCapabilities() throws {
        let payload = Data("""
        {"type":"welcome","protocol_version":1,"daemon_version":"0.1.0","engine_state":"running","capabilities":["remove_session"]}
        """.utf8)
        let message = try FrameCodec.decode(ServerMessage.self, from: payload)
        guard case .welcome(let welcome) = message else {
            return XCTFail("expected welcome")
        }
        XCTAssertEqual(welcome.capabilities, ["remove_session"])
    }

    func testSessionResponseDecodes() throws {
        let payload = Data("""
        {
          "type": "response",
          "request_id": 9,
          "result": {
            "status": "ok",
            "data": {
              "kind": "session",
              "value": {
                "id": "one",
                "pid": 42,
                "program": "/bin/sh",
                "cwd": "/tmp",
                "size": {"rows": 24, "cols": 80, "pixel_width": 640, "pixel_height": 384},
                "status": "running"
              }
            }
          }
        }
        """.utf8)
        let message = try FrameCodec.decode(ServerMessage.self, from: payload)
        guard case .response(let requestID, .ok(.session(let session))) = message else {
            return XCTFail("expected a session response")
        }
        XCTAssertEqual(requestID, 9)
        XCTAssertEqual(session.id, "one")
        XCTAssertEqual(session.pid, 42)
        XCTAssertEqual(session.size.pixelWidth, 640)
        XCTAssertEqual(session.status, .running)
    }

    func testAttachedSessionDecodesBase64Output() throws {
        let payload = Data("""
        {
          "type": "response",
          "request_id": 3,
          "result": {
            "status": "ok",
            "data": {
              "kind": "attached",
              "value": {
                "session": {
                  "id": "one",
                  "pid": 42,
                  "program": "/bin/sh",
                  "cwd": "/tmp",
                  "size": {"rows": 24, "cols": 80},
                  "status": "running"
                },
                "output": {
                  "data": "aGVsbG8=",
                  "first_seq": 0,
                  "next_seq": 1,
                  "truncated": false
                }
              }
            }
          }
        }
        """.utf8)
        let message = try FrameCodec.decode(ServerMessage.self, from: payload)
        guard case .response(_, .ok(.attached(let attached))) = message else {
            return XCTFail("expected an attached response")
        }
        XCTAssertEqual(attached.output.data, Data("hello".utf8))
        XCTAssertEqual(attached.output.firstSeq, 0)
        XCTAssertEqual(attached.output.nextSeq, 1)
        XCTAssertFalse(attached.output.truncated)
    }

    func testOutputAndStatusEventsDecode() throws {
        let output = Data("""
        {"type":"event","event":{"event":"output","session_id":"one","seq":3,"data":"aGVsbG8="}}
        """.utf8)
        guard case .event(.output(let id, let seq, let data)) =
            try FrameCodec.decode(ServerMessage.self, from: output) else {
            return XCTFail("expected an output event")
        }
        XCTAssertEqual(id, "one")
        XCTAssertEqual(seq, 3)
        XCTAssertEqual(data, Data("hello".utf8))

        let status = Data("""
        {"type":"event","event":{"event":"status","session_id":"one","status":{"exited":{"success":true,"code":0,"signal":null}}}}
        """.utf8)
        guard case .event(.status(let statusID, let sessionStatus)) =
            try FrameCodec.decode(ServerMessage.self, from: status) else {
            return XCTFail("expected a status event")
        }
        XCTAssertEqual(statusID, "one")
        XCTAssertEqual(sessionStatus, .exited(SessionExit(success: true, code: 0, signal: nil)))
    }

    func testErrorsDecode() throws {
        let payload = Data("""
        {
          "type": "response",
          "request_id": 4,
          "result": {
            "status": "error",
            "data": {"code": "session_not_found", "message": "no such session"}
          }
        }
        """.utf8)
        let message = try FrameCodec.decode(ServerMessage.self, from: payload)
        guard case .response(_, .error(let error)) = message else {
            return XCTFail("expected an error response")
        }
        XCTAssertEqual(error.code, "session_not_found")
        XCTAssertEqual(error.message, "no such session")
    }

    func testAcknowledgedResponseDecodesWithoutAValue() throws {
        let payload = Data("""
        {"type":"response","request_id":5,"result":{"status":"ok","data":{"kind":"acknowledged"}}}
        """.utf8)
        let message = try FrameCodec.decode(ServerMessage.self, from: payload)
        guard case .response(_, .ok(.acknowledged)) = message else {
            return XCTFail("expected an acknowledgement")
        }
    }

    func testFrameCodecRejectsOversizedAndEmptyFrames() throws {
        let oversized = Data(repeating: 0x41, count: DirectorProtocol.maxPayloadBytes + 1)
        XCTAssertThrowsError(try FrameCodec.encode(oversized))

        let empty = Data([0, 0, 0, 0])
        XCTAssertThrowsError(try FrameCodec.decode(ServerMessage.self, from: empty))
    }

    private func jsonObject(_ frame: Data) throws -> [String: Any] {
        XCTAssertGreaterThanOrEqual(frame.count, 4)
        let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        XCTAssertEqual(length, frame.count - 4)
        let payload = frame.dropFirst(4)
        let object = try JSONSerialization.jsonObject(with: Data(payload))
        return try XCTUnwrap(object as? [String: Any])
    }
}
