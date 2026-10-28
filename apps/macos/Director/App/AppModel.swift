import AppKit
import DirectorAPI
import Foundation
import Observation
import SwiftUI

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected(Welcome)
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    var failure: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

enum PaneSlot: String, CaseIterable, Identifiable, Sendable {
    case primary
    case secondary

    var id: String { rawValue }
    var number: Int { self == .primary ? 1 : 2 }
}

enum SplitLayout: String, CaseIterable, Identifiable, Sendable {
    case stacked
    case sideBySide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stacked: return "Stacked"
        case .sideBySide: return "Side by Side"
        }
    }
}

enum SessionFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case running
    case idle
    case needsYou

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .running: return "Running"
        case .idle: return "Idle"
        case .needsYou: return "Needs you"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var connection: ConnectionState = .idle
    var sessions: [SessionInfo] = []
    var primarySessionID: String?
    var secondarySessionID: String?
    var focusedPane: PaneSlot = .primary
    var isSplit = false
    var splitLayout: SplitLayout = .stacked
    var showSidebar = true {
        didSet { UserDefaults.standard.set(showSidebar, forKey: Self.showSidebarKey) }
    }
    var showContext = true {
        didSet { UserDefaults.standard.set(showContext, forKey: Self.showContextKey) }
    }
    var filter: SessionFilter = .all
    /// Sessions that produced output in the last few seconds.
    private(set) var activeSessionIDs: Set<String> = []
    /// Sessions that rang the bell and have not been touched since.
    private(set) var attentionSessionIDs: Set<String> = []
    var showNewAgent = false
    var pendingStopID: String?
    var errorMessage: String?
    var isStartingDaemon = false
    var gitSnapshots: [String: GitSnapshot] = [:]
    var terminalFontSize: Double = 16

    var socketPath: String
    var autoStartDaemon: Bool {
        didSet {
            UserDefaults.standard.set(autoStartDaemon, forKey: Self.autoStartKey)
        }
    }

    @ObservationIgnored private var client: DirectorClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var gitTask: Task<Void, Never>?
    @ObservationIgnored private var inputPumpTask: Task<Void, Never>?
    @ObservationIgnored private var inputBuffers: [String: Data] = [:]
    @ObservationIgnored private var resizeBuffers: [String: TerminalSize] = [:]
    @ObservationIgnored private var resizeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var controllers: [String: TerminalController] = [:]
    @ObservationIgnored private var attachedSessionIDs: Set<String> = []
    @ObservationIgnored private var attachingSessionIDs: Set<String> = []
    @ObservationIgnored private var errorToken = UUID()

    private static let socketKey = "director.socketPath"
    private static let autoStartKey = "director.autoStartDaemon"
    private static let fontSizeKey = "director.terminalFontSize"
    private static let showSidebarKey = "director.showSidebar"
    private static let showContextKey = "director.showContext"

    init() {
        let defaults = UserDefaults.standard
        if let override = ProcessInfo.processInfo.environment["DIRECTOR_SOCKET"], !override.isEmpty {
            socketPath = NSString(string: override).expandingTildeInPath
        } else {
            socketPath = defaults.string(forKey: Self.socketKey) ?? DirectorPaths.defaultSocketPath
        }
        autoStartDaemon = defaults.object(forKey: Self.autoStartKey) as? Bool ?? true
        terminalFontSize = defaults.object(forKey: Self.fontSizeKey) as? Double ?? 16
        showSidebar = defaults.object(forKey: Self.showSidebarKey) as? Bool ?? true
        showContext = defaults.object(forKey: Self.showContextKey) as? Bool ?? true
    }

    // MARK: - Derived state

    var focusedSession: SessionInfo? {
        session(for: focusedPane) ?? session(for: .primary)
    }

    var primarySession: SessionInfo? { session(for: .primary) }
    var secondarySession: SessionInfo? { session(for: .secondary) }

    var filteredSessions: [SessionInfo] {
        sessions.filter { matches($0, filter: filter) }
    }

    func matches(_ session: SessionInfo, filter: SessionFilter) -> Bool {
        let needsYou = needsAttention(session)
        switch filter {
        case .all:
            return true
        case .running:
            return session.isRunning
                && activeSessionIDs.contains(session.id)
                && !needsYou
        case .idle:
            if needsYou { return false }
            if session.isRunning { return !activeSessionIDs.contains(session.id) }
            if case .exited(let exit) = session.status { return exit.success }
            return false
        case .needsYou:
            return needsYou
        }
    }

    private func needsAttention(_ session: SessionInfo) -> Bool {
        if attentionSessionIDs.contains(session.id) { return true }
        if case .exited(let exit) = session.status, !exit.success { return true }
        return false
    }

    func noteSessionActivity(_ sessionID: String, active: Bool, needsAttention: Bool) {
        if active {
            activeSessionIDs.insert(sessionID)
        } else {
            activeSessionIDs.remove(sessionID)
        }
        if needsAttention {
            attentionSessionIDs.insert(sessionID)
        } else {
            attentionSessionIDs.remove(sessionID)
        }
    }

    var runningCount: Int { sessions.filter(\.isRunning).count }

    var contextSession: SessionInfo? { focusedSession }

    var contextSnapshot: GitSnapshot? {
        guard let cwd = contextSession?.cwd else { return nil }
        return gitSnapshot(for: cwd)
    }

    var connectionSummary: String {
        switch connection {
        case .idle:
            return "offline"
        case .connecting:
            return "connecting…"
        case .connected(let welcome):
            return "daemon \(welcome.daemonVersion)"
        case .failed:
            return "offline"
        }
    }

    var daemonExecutable: String? { DaemonLauncher.locate() }

    func session(for slot: PaneSlot) -> SessionInfo? {
        let id: String?
        switch slot {
        case .primary: id = primarySessionID
        case .secondary: id = isSplit ? secondarySessionID : nil
        }
        guard let id else { return nil }
        return sessions.first(where: { $0.id == id })
    }

    func session(id: String) -> SessionInfo? {
        sessions.first(where: { $0.id == id })
    }

    func gitSnapshot(for cwd: String) -> GitSnapshot? {
        gitSnapshots[cwd]
    }

    func branch(for cwd: String) -> String? {
        gitSnapshots[cwd]?.branch
    }

    func displayTitle(for session: SessionInfo) -> String {
        let words = session.id.split(separator: "-").map(String.init)
        guard !words.isEmpty else { return session.id }
        return words
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    func paneTitle(for session: SessionInfo) -> String {
        displayTitle(for: session)
    }

    func subtitle(for session: SessionInfo) -> String {
        let project = (session.cwd as NSString).lastPathComponent
        let agent = AgentCatalog.displayName(for: session.program)
        let branch = gitSnapshots[session.cwd]?.branch
        return [project, agent, branch]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    func statusLabel(for session: SessionInfo) -> String {
        switch session.status {
        case .running:
            return "running"
        case .exited(let exit):
            return exit.success ? "done" : "exit \(exit.code)"
        }
    }

    func paneSlot(for sessionID: String) -> PaneSlot? {
        if primarySessionID == sessionID { return .primary }
        if isSplit, secondarySessionID == sessionID { return .secondary }
        return nil
    }

    func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard case .idle = connection else { return }
        await connect(allowAutoStart: true)
    }

    func connect() async {
        await connect(allowAutoStart: true)
    }

    private func connect(allowAutoStart: Bool) async {
        guard !connection.isConnected, !connection.isConnecting else { return }
        connection = .connecting
        errorMessage = nil

        do {
            try await openConnection()
        } catch {
            if allowAutoStart, autoStartDaemon, isConnectionFailure(error),
               let executable = DaemonLauncher.locate() {
                isStartingDaemon = true
                do {
                    try await DaemonLauncher.start(executable: executable, socketPath: socketPath)
                    try await openConnection()
                } catch {
                    connection = .failed(friendly(error))
                }
                isStartingDaemon = false
                return
            }
            connection = .failed(friendly(error))
        }
    }

    private func openConnection() async throws {
        let client = try DirectorClient(path: socketPath)
        do {
            let welcome = try await client.connect(clientName: "director-macos")
            self.client = client
            connection = .connected(welcome)
            attachedSessionIDs.removeAll()
            attachingSessionIDs.removeAll()
            startEventLoop(client)
            try await reloadSessions()
            await attachVisiblePanes()
            startGitLoop()
        } catch {
            await client.disconnect()
            self.client = nil
            throw error
        }
    }

    func reconnect() async {
        teardownConnection()
        connection = .idle
        sessions = []
        primarySessionID = nil
        secondarySessionID = nil
        attachedSessionIDs.removeAll()
        attachingSessionIDs.removeAll()
        for controller in controllers.values {
            controller.reset()
            controller.update(status: .running)
        }
        await connect(allowAutoStart: true)
    }

    func startDaemonManually() async {
        guard let executable = DaemonLauncher.locate() else {
            showError("No director-daemon binary was found. Build it with `cargo build -p director-daemon` or set DIRECTOR_DAEMON.")
            return
        }
        isStartingDaemon = true
        defer { isStartingDaemon = false }
        do {
            try await DaemonLauncher.start(executable: executable, socketPath: socketPath)
            await connect(allowAutoStart: false)
        } catch {
            connection = .failed(friendly(error))
        }
    }

    func shutdown() {
        teardownConnection()
    }

    private func teardownConnection() {
        eventTask?.cancel()
        eventTask = nil
        gitTask?.cancel()
        gitTask = nil
        inputPumpTask?.cancel()
        inputPumpTask = nil
        inputBuffers.removeAll()
        activeSessionIDs.removeAll()
        attentionSessionIDs.removeAll()
        resizeTasks.values.forEach { $0.cancel() }
        resizeTasks.removeAll()
        resizeBuffers.removeAll()
        if let client {
            Task { await client.disconnect() }
        }
        client = nil
    }

    func applyAppearance(_ rawValue: String) {
        let appearance = AppAppearance(rawValue: rawValue) ?? .light
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    // MARK: - Event stream

    private func startEventLoop(_ client: DirectorClient) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in client.events {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.handle(event)
            }
            guard !Task.isCancelled else { return }
            self?.eventStreamEnded()
        }
    }

    private func eventStreamEnded() {
        guard connection.isConnected else { return }
        gitTask?.cancel()
        gitTask = nil
        connection = .failed("The daemon closed the connection.")
    }

    private func handle(_ event: ClientEvent) {
        switch event {
        case .output(let sessionID, _, let data):
            controllers[sessionID]?.feed(data)
        case .status(let sessionID, let status):
            updateStatus(status, for: sessionID)
        case .daemonStopping:
            connection = .failed("The daemon is shutting down.")
        }
    }

    private func updateStatus(_ status: SessionStatus, for sessionID: String) {
        controllers[sessionID]?.update(status: status)
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let old = sessions[index]
        sessions[index] = SessionInfo(
            id: old.id,
            pid: old.pid,
            program: old.program,
            cwd: old.cwd,
            size: old.size,
            status: status
        )
    }

    private func updateMetadata(_ info: SessionInfo) {
        guard let index = sessions.firstIndex(where: { $0.id == info.id }) else { return }
        sessions[index] = info
    }

    // MARK: - Sessions

    private func reloadSessions() async throws {
        guard let client else {
            throw DirectorError.daemonUnavailable("Not connected to the daemon.")
        }
        let list = try await client.listSessions()
        sessions = list.sorted(by: sessionSort)
        let ids = Set(sessions.map(\.id))
        activeSessionIDs.formIntersection(ids)
        attentionSessionIDs.formIntersection(ids)
        reconcilePanes()
    }

    private func reconcilePanes() {
        let ids = Set(sessions.map(\.id))

        if let primarySessionID, !ids.contains(primarySessionID) {
            self.primarySessionID = nil
        }
        if let secondarySessionID, !ids.contains(secondarySessionID) {
            self.secondarySessionID = nil
        }
        if primarySessionID == secondarySessionID {
            secondarySessionID = nil
        }

        if primarySessionID == nil {
            primarySessionID = sessions.first(where: \.isRunning)?.id ?? sessions.first?.id
        }
        if isSplit, secondarySessionID == nil {
            secondarySessionID = sessions.first(where: {
                $0.id != primarySessionID && $0.isRunning
            })?.id ?? sessions.first(where: {
                $0.id != primarySessionID
            })?.id
        }
    }

    private func sessionSort(_ lhs: SessionInfo, _ rhs: SessionInfo) -> Bool {
        if lhs.isRunning != rhs.isRunning {
            return lhs.isRunning
        }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }

    func selectSession(_ sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        primarySessionID = sessionID
        if secondarySessionID == sessionID {
            secondarySessionID = nil
        }
        focusedPane = .primary
        isSplit = false

        Task {
            await attachIfNeeded(sessionID)
            await refreshGitForFocusedSession()
        }
    }

    func focusPane(_ slot: PaneSlot) {
        guard slot == .primary || isSplit else { return }
        focusedPane = slot
        if let session = session(for: slot) {
            controller(for: session.id).focus()
            Task { await refreshGit(cwd: session.cwd) }
        }
    }

    func swapPanes() {
        guard isSplit else { return }
        (primarySessionID, secondarySessionID) = (secondarySessionID, primarySessionID)
        focusedPane = focusedPane == .primary ? .secondary : .primary
        Task { await attachVisiblePanes() }
    }

    func toggleSplit() {
        setSplit(!isSplit)
    }

    func setSplit(_ value: Bool) {
        isSplit = value
        if value {
            ensureSecondary()
        }
        Task { await attachVisiblePanes() }
    }

    private func ensureSecondary() {
        if secondarySessionID == nil {
            secondarySessionID = sessions.first(where: { $0.id != primarySessionID })?.id
        }
    }

    func setSplitLayout(_ layout: SplitLayout) {
        splitLayout = layout
        if isSplit {
            showContext = layout == .stacked
        }
    }

    func toggleSidebar() {
        showSidebar.toggle()
    }

    func toggleContext() {
        showContext.toggle()
    }

    func requestStop(_ sessionID: String) {
        pendingStopID = sessionID
    }

    func requestStopFocused() {
        if let id = focusedSession?.id {
            pendingStopID = id
        }
    }

    func stopSession(_ sessionID: String) {
        pendingStopID = nil
        Task {
            do {
                _ = try await client?.stopSession(id: sessionID)
            } catch {
                showError("Could not stop \(sessionID): \(friendly(error))")
            }
            try? await reloadSessions()
            await attachVisiblePanes()
        }
    }

    func forkSession(_ sessionID: String) {
        guard let session = session(id: sessionID) else { return }
        Task {
            do {
                _ = try await createSession(
                    program: session.program,
                    arguments: [],
                    cwd: session.cwd,
                    requestedName: "\(session.id)-fork"
                )
            } catch {
                showError("Could not fork \(session.id): \(friendly(error))")
            }
        }
    }

    @discardableResult
    func createSession(
        program: String,
        arguments: [String],
        cwd: String,
        requestedName: String
    ) async throws -> SessionInfo {
        guard let client else {
            throw DirectorError.daemonUnavailable("Not connected to the daemon.")
        }

        let name = requestedName.isEmpty
            ? (program as NSString).lastPathComponent
            : requestedName
        let id = uniqueSessionID(name)
        let spec = CreateSession(
            id: id,
            program: program,
            args: arguments,
            cwd: cwd,
            env: [
                "TERM": "xterm-256color",
                "COLORTERM": "truecolor",
            ],
            size: TerminalSize(rows: 24, cols: 80)
        )
        let session = try await client.createSession(spec)
        sessions.append(session)
        sessions.sort(by: sessionSort)

        primarySessionID = session.id
        if secondarySessionID == session.id {
            secondarySessionID = nil
        }
        focusedPane = .primary
        isSplit = false

        UserDefaults.standard.set(cwd, forKey: "director.lastWorkingDirectory")
        await attachIfNeeded(session.id)
        await refreshGit(cwd: cwd)
        return session
    }

    private func uniqueSessionID(_ raw: String) -> String {
        let mapped = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber || character == "-" || character == "_" {
                    return character
                }
                return "-"
            }
        var base = String(mapped)
        while base.contains("--") {
            base = base.replacingOccurrences(of: "--", with: "-")
        }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if base.isEmpty { base = "agent" }
        if base.count > 64 { base = String(base.prefix(64)) }

        let used = Set(sessions.map(\.id))
        if !used.contains(base) { return base }
        var suffix = 2
        while used.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    // MARK: - Attach and I/O

    func controller(for sessionID: String) -> TerminalController {
        if let controller = controllers[sessionID] {
            return controller
        }
        let controller = TerminalController(sessionID: sessionID, fontSize: terminalFontSize)
        controller.onInput = { [weak self] data in
            self?.enqueueInput(data, for: sessionID)
        }
        controller.onResize = { [weak self] size in
            self?.enqueueResize(size, for: sessionID)
        }
        controller.onFocus = { [weak self] in
            guard let self else { return }
            let slot: PaneSlot = (self.isSplit && self.secondarySessionID == sessionID)
                ? .secondary
                : .primary
            if self.focusedPane != slot {
                self.focusedPane = slot
                Task { await self.refreshGitForFocusedSession() }
            }
        }
        controller.onPresence = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.noteSessionActivity(
                sessionID,
                active: controller.recentlyActive,
                needsAttention: controller.needsAttention
            )
        }
        controllers[sessionID] = controller
        return controller
    }

    private func attachVisiblePanes() async {
        for slot in [PaneSlot.primary, .secondary] {
            if slot == .secondary, !isSplit { continue }
            if let id = session(for: slot)?.id {
                await attachIfNeeded(id)
            }
        }
    }

    private func attachIfNeeded(_ sessionID: String) async {
        guard let client else { return }
        guard !attachedSessionIDs.contains(sessionID) else { return }
        guard !attachingSessionIDs.contains(sessionID) else { return }
        guard sessions.contains(where: { $0.id == sessionID }) else { return }

        attachingSessionIDs.insert(sessionID)
        defer { attachingSessionIDs.remove(sessionID) }

        let controller = controller(for: sessionID)
        do {
            let attached = try await client.attachSession(id: sessionID)
            attachedSessionIDs.insert(sessionID)
            controller.reset()
            controller.feed(attached.output.data)
            controller.update(status: attached.session.status)
            updateMetadata(attached.session)
            if let size = controller.currentSize {
                enqueueResize(size, for: sessionID)
            }
            await refreshGit(cwd: attached.session.cwd)
        } catch {
            if case let DirectorError.api(apiError) = error, apiError.code == "already_attached" {
                attachedSessionIDs.insert(sessionID)
                return
            }
            showError("Could not attach to \(sessionID): \(friendly(error))")
        }
    }

    private func enqueueInput(_ data: Data, for sessionID: String) {
        guard !data.isEmpty else { return }
        inputBuffers[sessionID, default: Data()].append(data)
        guard inputPumpTask == nil else { return }

        inputPumpTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(8))
            guard let self else { return }
            while !self.inputBuffers.isEmpty {
                let batches = self.inputBuffers
                self.inputBuffers.removeAll()
                guard let client = self.client else { break }
                for (id, data) in batches {
                    do {
                        try await client.input(id: id, data: data)
                    } catch {
                        self.showError("Could not send input to \(id): \(self.friendly(error))")
                    }
                }
                if !self.inputBuffers.isEmpty {
                    try? await Task.sleep(for: .milliseconds(8))
                }
            }
            self.inputPumpTask = nil
        }
    }

    private func enqueueResize(_ size: TerminalSize, for sessionID: String) {
        resizeBuffers[sessionID] = size
        guard resizeTasks[sessionID] == nil else { return }

        resizeTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard let self else { return }
            while let next = self.resizeBuffers.removeValue(forKey: sessionID) {
                if let client = self.client {
                    do {
                        try await client.resize(id: sessionID, size: next)
                    } catch {
                        // A resize for an exited session is harmless.
                    }
                }
                if self.resizeBuffers[sessionID] != nil {
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
            self.resizeTasks[sessionID] = nil
        }
    }

    func clearFocusedTerminal() {
        guard let id = focusedSession?.id else { return }
        controller(for: id).clear()
    }

    func setTerminalFontSize(_ size: Double) {
        terminalFontSize = min(max(size, 10), 18)
        UserDefaults.standard.set(terminalFontSize, forKey: Self.fontSizeKey)
        for controller in controllers.values {
            controller.setFontSize(CGFloat(terminalFontSize))
        }
    }

    func setSocketPath(_ path: String) {
        let expanded = NSString(string: path).expandingTildeInPath
        guard !expanded.isEmpty else { return }
        socketPath = expanded
        UserDefaults.standard.set(expanded, forKey: Self.socketKey)
    }

    func connectUsingPath(_ path: String) async {
        setSocketPath(path)
        await reconnect()
    }

    func startDaemonUsingPath(_ path: String) async {
        setSocketPath(path)
        await startDaemonManually()
    }

    // MARK: - Git

    private func startGitLoop() {
        gitTask?.cancel()
        gitTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshGitForFocusedSession()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func refreshGitNow() {
        Task { await refreshGitForFocusedSession() }
    }

    private func refreshGitForFocusedSession() async {
        guard let cwd = focusedSession?.cwd else { return }
        await refreshGit(cwd: cwd)
    }

    private func refreshGit(cwd: String) async {
        guard !cwd.isEmpty else { return }
        let snapshot = await Task.detached(priority: .utility) {
            GitService.snapshot(cwd: cwd)
        }.value
        gitSnapshots[cwd] = snapshot
    }

    // MARK: - Errors

    func showError(_ message: String) {
        errorMessage = message
        let token = UUID()
        errorToken = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.errorToken == token else { return }
            self.errorMessage = nil
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func friendly(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private func isConnectionFailure(_ error: Error) -> Bool {
        if case DirectorError.connectFailed = error {
            return true
        }
        return false
    }

    // MARK: - Defaults

    static var defaultWorkingDirectory: String {
        if let env = ProcessInfo.processInfo.environment["DIRECTOR_WORKDIR"], !env.isEmpty {
            return NSString(string: env).expandingTildeInPath
        }
        if let saved = UserDefaults.standard.string(forKey: "director.lastWorkingDirectory"),
           FileManager.default.fileExists(atPath: saved) {
            return saved
        }
        let home = NSHomeDirectory()
        for candidate in ["\(home)/code", "\(home)/Desktop/director"] {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return home
    }
}
