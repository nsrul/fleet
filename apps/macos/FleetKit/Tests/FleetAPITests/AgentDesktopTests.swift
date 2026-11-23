import XCTest

@testable import FleetAPI

final class AgentDesktopTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fleet-agent-desktop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testLaunchPreparesAPrivateHomeForEachSession() throws {
        let first = try prepare("one")
        let second = try prepare("two")

        XCTAssertEqual(first.environment["FLEET_AGENT_DESKTOP_BIN"], "/usr/bin/true")
        XCTAssertEqual(first.environment["FLEET_AGENT_DESKTOP_SESSION"], "one")
        XCTAssertEqual(first.environment["AGENT_DESKTOP_HOME"], first.home)
        XCTAssertNotEqual(first.home, second.home)
        XCTAssertEqual(mode(first.home), 0o700)
        XCTAssertEqual(mode(second.home), 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.home))

        AgentDesktop.removeHome(sessionID: "one", root: root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.home))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.home))
    }

    func testABlankBinaryOrUnsafeSessionDoesNotCreateAHome() {
        XCTAssertNil(AgentDesktop.launch(binary: "  ", sessionID: "one", root: root.path))
        XCTAssertNil(AgentDesktop.launch(binary: "/usr/bin/true", sessionID: "../outside", root: root.path))
        XCTAssertNil(AgentDesktop.launch(binary: "/usr/bin/true", sessionID: "a/b", root: root.path))
        let contents = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(contents, [])
    }

    func testPruneDropsHomesWhoseSessionsAreGone() throws {
        _ = try prepare("live")
        _ = try prepare("gone")
        AgentDesktop.pruneHomes(root: root.path, keeping: ["live"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("live").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gone").path))
    }

    func testPendingEnvironmentWaitsForTheSessionId() {
        XCTAssertEqual(
            AgentDesktop.pendingEnvironment(
                installation: AgentDesktop.Installation(binary: "/usr/bin/true", root: root.path)
            ),
            [
                "FLEET_AGENT_DESKTOP_BIN": "/usr/bin/true",
                "FLEET_AGENT_DESKTOP_ROOT": root.path,
            ]
        )
        XCTAssertNil(
            AgentDesktop.pendingEnvironment(
                installation: AgentDesktop.Installation(binary: " ", root: root.path)
            )
        )
        XCTAssertNil(
            AgentDesktop.pendingEnvironment(
                installation: AgentDesktop.Installation(binary: "/usr/bin/true", root: "relative")
            )
        )
        let contents = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(contents, [])
    }

    func testPermissionCommandsNeverRequestScreenRecording() throws {
        XCTAssertEqual(AgentDesktop.permissionArguments(guide: false), ["permissions"])
        XCTAssertEqual(AgentDesktop.permissionArguments(guide: true), ["permissions", "--guide"])
        let encoded = try JSONEncoder().encode(AgentDesktop.permissionArguments(guide: true))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("request"))
        XCTAssertFalse(text.contains("screenshot"))
        XCTAssertFalse(text.contains("headed"))
    }

    func testDeniedAccessibilityIsDistinctFromOtherGrants() throws {
        let denied = """
        {"ok":true,"data":{"accessibility":{"state":"denied","suggestion":"guide"},"screen_recording":{"state":"denied","suggestion":"no"},"automation":{"state":"unknown"}}}
        """
        let granted = """
        {"ok":true,"data":{"accessibility":{"state":"granted"},"screen_recording":{"state":"denied","suggestion":"no"}}}
        """
        let guided = """
        {"ok":true,"data":{"accessibility":{"state":"denied","suggestion":"guide"},"guide":"started"}}
        """
        let parsedDenied = try XCTUnwrap(AgentDesktop.parsePermissions(Data(denied.utf8)))
        XCTAssertTrue(parsedDenied.accessibilityDenied)
        XCTAssertNil(parsedDenied.guide)
        let parsedGranted = try XCTUnwrap(AgentDesktop.parsePermissions(Data(granted.utf8)))
        XCTAssertFalse(parsedGranted.accessibilityDenied)
        let parsedGuided = try XCTUnwrap(AgentDesktop.parsePermissions(Data(guided.utf8)))
        XCTAssertEqual(parsedGuided.guide, "started")
        XCTAssertNil(AgentDesktop.parsePermissions(Data("{\"ok\":false}".utf8)))

        let notice = AgentDesktop.accessibilityNotice(appName: "Fleet", guide: "started")
        XCTAssertEqual(notice.title, "Fleet needs Accessibility.")
        XCTAssertTrue(notice.detail.contains("Fleet"))
        XCTAssertTrue(notice.detail.contains("still running"))
        XCTAssertFalse(notice.detail.localizedCaseInsensitiveContains("screen recording"))
    }

    private func prepare(_ sessionID: String) throws -> AgentDesktop.Launch {
        let launch = try XCTUnwrap(
            AgentDesktop.launch(binary: "/usr/bin/true", sessionID: sessionID, root: root.path)
        )
        try AgentDesktop.prepareHome(at: launch.home)
        return launch
    }

    private func mode(_ path: String) -> Int {
        let raw = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?
            .intValue ?? -1
        return raw & 0o777
    }
}
