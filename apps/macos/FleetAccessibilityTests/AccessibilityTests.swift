import Darwin
import FleetAPI
import Foundation
import XCTest

@MainActor
final class AccessibilityTests: XCTestCase {
    private let bundleID = "dev.fleet.macos.uitesting"

    func testControlsAreDiscoverableAndActionableByIdentifier() async throws {
        continueAfterFailure = false
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let temporary = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("fleet-ax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        registerCleanup { try? FileManager.default.removeItem(at: temporary) }
        let project = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let home = temporary.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        // Isolate MCP files, scratch login-shell configuration, and any shell hooks.
        let isolatedEnvironment = [
            "TMPDIR": temporary.path + "/", "HOME": home.path, "ZDOTDIR": home.path,
            "ENV": "", "BASH_ENV": "",
            FleetPluginFiles.geminiSystemSettingsEnvironmentKey: home.appendingPathComponent("gemini-settings.json").path,
        ]
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["--no-pager", "init", "--quiet", project.path]
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)
        try Data("UI test change\n".utf8).write(to: project.appendingPathComponent("change.txt"))

        let socket = temporary.appendingPathComponent("daemon.sock").path
        let log = temporary.appendingPathComponent("daemon.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        registerCleanup { try? logHandle.close() }
        let daemon = Process()
        daemon.executableURL = root.appendingPathComponent("target/debug/fleet-daemon")
        daemon.arguments = ["--socket", socket]
        daemon.environment = ProcessInfo.processInfo.environment.merging(isolatedEnvironment) { _, isolated in isolated }
        daemon.standardOutput = logHandle
        daemon.standardError = logHandle
        try daemon.run()
        registerCleanup { [self] in
            stop(daemon)
            let attachment = XCTAttachment(contentsOfFile: log)
            attachment.lifetime = .deleteOnSuccess
            add(attachment)
        }
        let startupDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < startupDeadline {
            if FileManager.default.fileExists(atPath: socket) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "Daemon did not bind its socket")
        let client = try FleetClient(path: socket)
        registerCleanup { client.forceClose() }
        _ = try await client.connect(clientName: "accessibility-test")
        for id in ["first", "second"] {
            _ = try await client.createSession(CreateSession(id: id, program: "/bin/sh", cwd: project.path))
        }
        _ = try await client.putWorkspace(Workspace(
            split: nil,
            panes: [WorkspacePane(
                id: "test-pane",
                tabs: [
                    WorkspaceTab(id: "first-tab", sessionID: "first"),
                    WorkspaceTab(id: "second-tab", sessionID: "second"),
                ],
                activeTabID: "first-tab"
            )],
            focusedPaneID: "test-pane"
        ))

        // UITesting builds use their own bundle id, never the user's Fleet defaults.
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        registerCleanup { [self] in UserDefaults.standard.removePersistentDomain(forName: bundleID) }
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchEnvironment = isolatedEnvironment
        app.launchEnvironment["FLEET_SOCKET"] = socket
        app.launchEnvironment["FLEET_WORKDIR"] = project.path
        app.launchEnvironment["FLEET_PREVIEW"] = "0"
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-fleet.autoStartDaemon", "NO"]
        app.launch()
        registerCleanup { [self] in
            if app.windows.firstMatch.exists {
                let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                attachment.lifetime = .deleteOnSuccess
                add(attachment)
            }
            app.terminate()
        }

        let pane = element("workspace.pane.test-pane", in: app)
        XCTAssertTrue(pane.waitForExistence(timeout: 10))
        XCTAssertEqual(pane.label, "Terminal pane 1")
        let pluginConfig = temporary.appendingPathComponent("fleet-plugin-\(getuid())/claude-mcp.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pluginConfig.path), "MCP files must stay inside the fixture")
        let firstRow = app.buttons["sidebar.session.first"]
        let secondRow = app.buttons["sidebar.session.second"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        XCTAssertTrue(secondRow.exists)
        XCTAssertFalse(firstRow.label.isEmpty)
        secondRow.click()
        try await waitForWorkspace(client) { $0.focusedPane?.activeTabID == "second-tab" }

        // Titles may change through OSC; the session-based row id must not change.
        try await client.input(id: "second", data: Data("printf '\\033]0;Renamed shell\\007'\n".utf8))
        let renamed = NSPredicate(format: "label CONTAINS %@", "Renamed shell")
        XCTAssertTrue(wait(secondRow, matching: renamed))
        let firstTab = element("workspace.tab.first-tab", in: app)
        XCTAssertTrue(firstTab.exists)
        firstTab.click()
        try await waitForWorkspace(client) { $0.focusedPane?.activeTabID == "first-tab" }
        element("workspace.tab.second-tab", in: app).click()
        try await waitForWorkspace(client) { $0.focusedPane?.activeTabID == "second-tab" }
        let closeTab = app.buttons["workspace.close-tab.second-tab"]
        XCTAssertEqual(closeTab.label, "Close Renamed shell")
        closeTab.click()
        try await waitForWorkspace(client) { $0.focusedPane?.tabs.count == 1 }
        secondRow.click()
        try await waitForWorkspace(client) { $0.focusedPane?.tabs.count == 2 }

        let newAgent = app.buttons["sidebar.new-agent"]
        XCTAssertEqual(newAgent.label, "New agent")
        newAgent.click()
        let presets = [
            ("claude", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor Agent"),
            ("gemini", "Gemini CLI"), ("opencode", "OpenCode"), ("shell", "Shell"),
            ("custom", "Custom…"),
        ]
        for (id, title) in presets {
            let tile = app.buttons["new-agent.preset.\(id)"]
            XCTAssertTrue(tile.waitForExistence(timeout: 5))
            XCTAssertEqual(tile.label, title)
            tile.click()
            XCTAssertTrue(tile.isSelected)
        }
        let program = app.textFields["new-agent.program"]
        XCTAssertEqual(program.label, "Program")
        replaceText(program, with: "/bin/sh")
        let name = app.textFields["new-agent.name"]
        XCTAssertEqual(name.label, "Session name")
        replaceText(name, with: "UI Created Shell")
        let directory = app.textFields["new-agent.directory"]
        XCTAssertEqual(directory.label, "Working directory")
        replaceText(directory, with: project.path)
        XCTAssertTrue(app.buttons["new-agent.choose-directory"].exists)
        app.buttons["new-agent.create"].click()
        let createdRow = app.buttons["sidebar.session.ui-created-shell"]
        XCTAssertTrue(createdRow.waitForExistence(timeout: 10))
        let created = try await client.inspectSession(id: "ui-created-shell")
        XCTAssertTrue(created.isRunning)
        XCTAssertEqual(created.cwd, project.path)

        app.buttons["workspace.new-agent.test-pane"].click()
        app.buttons["new-agent.cancel"].click()
        XCTAssertFalse(app.buttons["new-agent.cancel"].exists)
        XCTAssertTrue(app.buttons["workspace.new-agent.test-pane"].exists)

        XCTAssertTrue(element("context.panel", in: app).exists)
        XCTAssertTrue(element("context.changes", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["context.show-terminal"].label, "Terminal")
        app.buttons["context.show-terminal"].click()
        XCTAssertTrue(element("context.terminal", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["context.show-changes"].label, "Changes")
        app.buttons["context.show-changes"].click()
        XCTAssertTrue(element("context.changes", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("context.terminal", in: app).exists)

        app.menuBars.menuBarItems["Session"].click()
        let split = app.menuItems["workspace.split"]
        XCTAssertTrue(split.exists, app.debugDescription)
        split.click()
        XCTAssertTrue(app.buttons["split.cancel"].waitForExistence(timeout: 5))
        app.buttons["split.cancel"].click()
        app.menuBars.menuBarItems["Session"].click()
        app.menuItems["workspace.split"].click()
        app.buttons["split.session.first"].click()
        try await waitForWorkspace(client) { $0.panes.count == 2 }
        let workspace = try await client.getWorkspace()
        for pane in workspace.panes {
            XCTAssertTrue(element("workspace.pane.\(pane.id)", in: app).exists)
        }

        firstRow.click()
        app.menuBars.menuBarItems["Session"].click()
        app.menuItems["session.stop"].click()
        XCTAssertTrue(app.buttons["session.stop.cancel"].waitForExistence(timeout: 5))
        app.buttons["session.stop.cancel"].click()
        firstRow.hover()
        let stopButton = app.buttons["sidebar.stop.first"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5))
        XCTAssertEqual(stopButton.label, "Stop agent")
        stopButton.click()
        XCTAssertTrue(wait(firstRow, matching: NSPredicate(format: "value == %@", "Stopped")))
        let stopped = try await client.inspectSession(id: "first")
        XCTAssertFalse(stopped.isRunning)

        // Shutdown exercises the actual error toast, without a fixture hook.
        createdRow.click()
        try await waitForWorkspace(client) { workspace in
            guard let pane = workspace.focusedPane else { return false }
            return pane.tabs.first(where: { $0.id == pane.activeTabID })?.sessionID == "ui-created-shell"
        }
        stop(daemon)
        app.menuBars.menuBarItems["Session"].click()
        app.menuItems["session.stop"].click()
        app.buttons["session.stop.confirm"].click()
        XCTAssertTrue(element("notice.error", in: app).waitForExistence(timeout: 5))
        let errorTitle = app.staticTexts["notice.error.title"]
        XCTAssertFalse((errorTitle.value as? String ?? errorTitle.label).isEmpty)
        let dismiss = app.buttons["notice.error.dismiss"]
        XCTAssertEqual(dismiss.label, "Dismiss error")
        dismiss.click()
        XCTAssertFalse(element("notice.error", in: app).exists)
    }

    private func registerCleanup(_ block: @escaping @MainActor @Sendable () -> Void) {
        addTeardownBlock {
            await block()
        }
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func wait(_ element: XCUIElement, matching predicate: NSPredicate) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }

    private func replaceText(_ field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    private func waitForWorkspace(
        _ client: FleetClient, matching predicate: (Workspace) -> Bool
    ) async throws {
        for _ in 0..<100 {
            if predicate(try await client.getWorkspace()) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Workspace did not reflect the UI action")
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<100 {
            if !process.isRunning { return }
            usleep(50_000)
        }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}
