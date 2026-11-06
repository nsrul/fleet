import XCTest

@testable import FleetAPI

final class WorkspaceTests: XCTestCase {
    private var issued = 0

    override func setUp() {
        issued = 0
    }

    private func nextID() -> String {
        issued += 1
        return "id-\(issued)"
    }

    private func apply(_ workspace: Workspace, _ edit: WorkspaceEdit) -> Workspace {
        WorkspaceEditor.apply(workspace, edit, newID: nextID)
    }

    func testOpenFocusesAnExistingTab() {
        let opened = apply(.empty, .open(sessionID: "alpha"))
        let again = apply(opened, .open(sessionID: "beta"))
        let focused = apply(again, .open(sessionID: "alpha"))
        XCTAssertEqual(focused.panes.count, 1)
        XCTAssertEqual(focused.panes[0].tabs.map(\.sessionID), ["alpha", "beta"])
        XCTAssertEqual(focused.panes[0].activeTabID, focused.panes[0].tabs[0].id)
        XCTAssertEqual(focused.focusedPaneID, focused.panes[0].id)
    }

    func testCloseCollapsesAnEmptyPaneAndTheLastTab() {
        var workspace = apply(.empty, .open(sessionID: "alpha"))
        workspace = apply(workspace, .open(sessionID: "beta"))
        workspace = apply(
            workspace,
            .split(tabID: workspace.panes[0].tabs[1].id, axis: .horizontal, placeFirst: false)
        )
        XCTAssertEqual(workspace.panes.count, 2)
        XCTAssertEqual(workspace.split, .horizontal)

        let second = workspace.panes[1].tabs[0].id
        workspace = apply(workspace, .closeTab(id: second))
        XCTAssertEqual(workspace.panes.count, 1)
        XCTAssertNil(workspace.split)

        let last = workspace.panes[0].tabs[0].id
        workspace = apply(workspace, .closeTab(id: last))
        XCTAssertEqual(workspace, .empty)
    }

    func testMoveAndAThirdPaneIsRejected() {
        var workspace = apply(.empty, .open(sessionID: "alpha"))
        workspace = apply(workspace, .open(sessionID: "beta"))
        let beta = workspace.panes[0].tabs[1].id
        workspace = apply(workspace, .split(tabID: beta, axis: .vertical, placeFirst: false))
        XCTAssertEqual(workspace.split, .vertical)
        XCTAssertEqual(workspace.panes[1].tabs.map(\.sessionID), ["beta"])

        workspace = apply(workspace, .open(sessionID: "gamma"))
        XCTAssertEqual(workspace.panes.count, 2)
        let gamma = workspace.panes[1].tabs[1].id
        let moved = apply(
            workspace,
            .split(tabID: gamma, axis: .horizontal, placeFirst: true)
        )
        XCTAssertEqual(moved.panes.count, 2)
        XCTAssertEqual(moved.split, .horizontal)
        XCTAssertEqual(moved.panes[0].tabs.map(\.sessionID), ["alpha", "gamma"])
        XCTAssertEqual(moved.panes[1].tabs.map(\.sessionID), ["beta"])
        XCTAssertEqual(moved.focusedPaneID, moved.panes[0].id)
        XCTAssertEqual(moved.panes[0].activeTabID, moved.panes[0].tabs[1].id)

        let beside = apply(moved, .openBeside(sessionID: "delta", axis: .vertical))
        XCTAssertEqual(beside.panes.count, 2)
        XCTAssertFalse(beside.panes.flatMap(\.tabs).map(\.sessionID).contains("delta"))
    }

    func testDroppingTheLastTabOfAPaneCollapsesIt() {
        var workspace = apply(.empty, .open(sessionID: "alpha"))
        workspace = apply(workspace, .open(sessionID: "beta"))
        let beta = workspace.panes[0].tabs[1].id
        workspace = apply(workspace, .split(tabID: beta, axis: .horizontal, placeFirst: false))
        let moved = apply(
            workspace,
            .moveTab(id: beta, toPaneID: workspace.panes[0].id, index: 1)
        )
        XCTAssertEqual(moved.panes.count, 1)
        XCTAssertNil(moved.split)
        XCTAssertEqual(moved.panes[0].tabs.map(\.sessionID), ["alpha", "beta"])
    }

    func testPruneDropsMissingSessions() {
        var workspace = apply(.empty, .open(sessionID: "alpha"))
        workspace = apply(workspace, .openBeside(sessionID: "beta", axis: .horizontal))
        let pruned = apply(workspace, .prune(keeping: ["beta"]))
        XCTAssertEqual(pruned.panes.count, 1)
        XCTAssertEqual(pruned.panes[0].tabs.map(\.sessionID), ["beta"])
        XCTAssertNil(pruned.split)
    }

    func testWorkspaceEncodesTheRustShape() throws {
        let workspace = Workspace(
            split: .horizontal,
            panes: [
                WorkspacePane(
                    id: "pane-a",
                    tabs: [WorkspaceTab(id: "tab-a", sessionID: "one")],
                    activeTabID: "tab-a"
                ),
            ],
            focusedPaneID: "pane-a"
        )
        let message = ClientMessage.request(requestID: 4, command: .putWorkspace(workspace))
        let object = try jsonObject(FrameCodec.encode(message))
        let command = try XCTUnwrap(object["command"] as? [String: Any])
        XCTAssertEqual(command["command"] as? String, "put_workspace")
        let params = try XCTUnwrap(command["params"] as? [String: Any])
        let encoded = try XCTUnwrap(params["workspace"] as? [String: Any])
        XCTAssertEqual(encoded["split"] as? String, "horizontal")
        XCTAssertEqual(encoded["focused_pane_id"] as? String, "pane-a")
        let panes = try XCTUnwrap(encoded["panes"] as? [[String: Any]])
        XCTAssertEqual(panes[0]["active_tab_id"] as? String, "tab-a")
        let tabs = try XCTUnwrap(panes[0]["tabs"] as? [[String: Any]])
        XCTAssertEqual(tabs[0]["session_id"] as? String, "one")

        let event = """
        {"event":"workspace_changed","workspace":{"split":"vertical","panes":[],"focused_pane_id":"pane-a"}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Event.self, from: event)
        guard case .workspaceChanged(let decodedWorkspace) = decoded else {
            return XCTFail("expected a workspace event")
        }
        XCTAssertEqual(decodedWorkspace.split, .vertical)
        XCTAssertTrue(decodedWorkspace.panes.isEmpty)
    }
}

private func jsonObject(_ frame: Data) throws -> [String: Any] {
    XCTAssertGreaterThanOrEqual(frame.count, 4)
    let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    XCTAssertEqual(length, frame.count - 4)
    let payload = frame.dropFirst(4)
    let object = try JSONSerialization.jsonObject(with: Data(payload))
    return try XCTUnwrap(object as? [String: Any])
}
