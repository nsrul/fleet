import Foundation
import XCTest

@testable import FleetAPI

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
        XCTAssertNil(params["parent_id"])
        XCTAssertNil(params["brief"])
    }

    func testCreateSessionEncodesParentAndBrief() throws {
        let spec = CreateSession(
            id: "child",
            program: "/bin/sleep",
            cwd: "/tmp",
            parentID: "parent",
            brief: "watch this"
        )
        let object = try jsonObject(
            FrameCodec.encode(ClientMessage.request(requestID: 1, command: .createSession(spec)))
        )
        let command = try XCTUnwrap(object["command"] as? [String: Any])
        let params = try XCTUnwrap(command["params"] as? [String: Any])
        XCTAssertEqual(params["parent_id"] as? String, "parent")
        XCTAssertEqual(params["brief"] as? String, "watch this")
    }

    func testTaskCommandsEncode() throws {
        let report = ClientMessage.request(
            requestID: 2,
            command: .reportPresence(ReportPresence(id: "one", active: true, needsAttention: true))
        )
        let reportObject = try jsonObject(FrameCodec.encode(report))
        let reportCommand = try XCTUnwrap(reportObject["command"] as? [String: Any])
        XCTAssertEqual(reportCommand["command"] as? String, "report_presence")
        let reportParams = try XCTUnwrap(reportCommand["params"] as? [String: Any])
        XCTAssertEqual(reportParams["needs_attention"] as? Bool, true)

        let list = ClientMessage.request(requestID: 3, command: .listTasks(parentID: nil))
        let listCommand = try XCTUnwrap(
            (try jsonObject(FrameCodec.encode(list)))["command"] as? [String: Any]
        )
        XCTAssertEqual(listCommand["command"] as? String, "list_tasks")
        let listParams = try XCTUnwrap(listCommand["params"] as? [String: Any])
        XCTAssertNil(listParams["parent_id"])
    }

    func testSidebarClassMatchesTheAppRows() {
        let rows: [(SessionStatus, Bool, Bool, SidebarClass)] = [
            (.running, true, false, .running),
            (.running, false, false, .idle),
            (.running, true, true, .needsYou),
            (.exited(SessionExit(success: true, code: 0)), false, false, .idle),
            (.exited(SessionExit(success: false, code: 1)), false, false, .needsYou),
        ]
        for (status, active, needsAttention, expected) in rows {
            XCTAssertEqual(
                sidebarClass(status: status, active: active, needsAttention: needsAttention),
                expected
            )
        }
    }

    func testPresenceReportRequiresTheTasksCapability() {
        XCTAssertNil(presenceReport(
            capabilities: ["remove_session"],
            sessionID: "one",
            active: true,
            needsAttention: false
        ))
        let report = presenceReport(
            capabilities: [FleetProtocol.tasksCapability],
            sessionID: "one",
            active: true,
            needsAttention: true
        )
        XCTAssertEqual(report, ReportPresence(id: "one", active: true, needsAttention: true))
    }

    func testTasksPlanAndSessionListEventsDecode() throws {
        let tasks = Data("""
        {"type":"response","request_id":1,"result":{"status":"ok","data":{"kind":"tasks","value":[{"session_id":"child","parent_id":"parent","brief":"watch this","status":"running","sidebar":"needs_you"}]}}}
        """.utf8)
        guard case .response(_, .ok(.tasks(let decoded))) =
            try FrameCodec.decode(ServerMessage.self, from: tasks) else {
            return XCTFail("expected tasks")
        }
        XCTAssertEqual(decoded.first?.sessionID, "child")
        XCTAssertEqual(decoded.first?.sidebar, .needsYou)
        XCTAssertEqual(decoded.first?.brief, "watch this")

        let plan = Data("""
        {"type":"response","request_id":2,"result":{"status":"ok","data":{"kind":"plan","value":{"id":"plan-1","parent_id":"parent","state":"done","steps":[{"index":0,"state":"done","session_id":"plan-1-1"},{"index":1,"state":"done","session_id":"plan-1-2"}]}}}}
        """.utf8)
        guard case .response(_, .ok(.plan(let info))) =
            try FrameCodec.decode(ServerMessage.self, from: plan) else {
            return XCTFail("expected a plan")
        }
        XCTAssertEqual(info.id, "plan-1")
        XCTAssertEqual(info.state, .done)
        XCTAssertEqual(info.steps.map(\.sessionID), ["plan-1-1", "plan-1-2"])

        let changed = Data("""
        {"type":"event","event":{"event":"sessions_changed"}}
        """.utf8)
        guard case .event(.sessionsChanged) =
            try FrameCodec.decode(ServerMessage.self, from: changed) else {
            return XCTFail("expected sessions_changed")
        }
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
        let oversized = Data(repeating: 0x41, count: FleetProtocol.maxPayloadBytes + 1)
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
