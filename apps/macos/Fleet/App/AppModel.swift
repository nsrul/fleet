import AppKit
import FleetAPI
import Foundation
import Observation
import SwiftUI

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected(Welcome)
    case failed(UserNotice)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    var failure: UserNotice? {
        if case .failed(let notice) = self { return notice }
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

/// Preferences for the middle terminal panel. SwiftTerm types stay in the controller.
struct TerminalPreferences: Equatable, Sendable {
    var fontID: String
    var fontSize: Double
    var cursorTag: String
    var lineSpacing: Double
    var scrollback: Int
    var optionIsMeta: Bool
    var bellSound: Bool

    static let standard = TerminalPreferences(
        fontID: TerminalFont.systemID,
        fontSize: 16,
        cursorTag: "blinkBlock",
        lineSpacing: 1,
        scrollback: 20_000,
        optionIsMeta: true,
        bellSound: true
    )

    static let spacings: [Double] = [1, 1.15, 1.35]
    static let scrollbacks: [Int] = [5_000, 20_000, 50_000, 100_000]
    private static let cursorTags: Set<String> = [
        "blinkBlock", "steadyBlock",
        "blinkUnderline", "steadyUnderline",
        "blinkBar", "steadyBar",
    ]

    func clamped() -> TerminalPreferences {
        var copy = self
        if copy.fontID.isEmpty { copy.fontID = Self.standard.fontID }
        if !copy.fontSize.isFinite {
            copy.fontSize = Self.standard.fontSize
        } else {
            copy.fontSize = min(18, max(10, copy.fontSize.rounded()))
        }
        if !Self.cursorTags.contains(copy.cursorTag) {
            copy.cursorTag = Self.standard.cursorTag
        }
        if let match = Self.spacings.first(where: { abs($0 - copy.lineSpacing) < 0.001 }) {
            copy.lineSpacing = match
        } else {
            copy.lineSpacing = Self.standard.lineSpacing
        }
        if !Self.scrollbacks.contains(copy.scrollback) {
            copy.scrollback = Self.standard.scrollback
        }
        return copy
    }

    static func tag(shape: String, blinks: Bool) -> String {
        switch shape {
        case "underline": return blinks ? "blinkUnderline" : "steadyUnderline"
        case "bar": return blinks ? "blinkBar" : "steadyBar"
        default: return blinks ? "blinkBlock" : "steadyBlock"
        }
    }

    static func shape(of tag: String) -> String {
        if tag.contains("Underline") { return "underline" }
        if tag.contains("Bar") { return "bar" }
        return "block"
    }

    static func blinks(_ tag: String) -> Bool {
        tag.hasPrefix("blink")
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
        didSet { store(showSidebar, forKey: Self.showSidebarKey) }
    }
    var showContext = true {
        didSet { store(showContext, forKey: Self.showContextKey) }
    }
    /// 0 is liquid glass on the side panels. 1 is the solid panel color.
    var panelSolidity: Double = 1 {
        didSet {
            let clamped = min(1, max(0, panelSolidity))
            if clamped != panelSolidity {
                panelSolidity = clamped
                return
            }
            store(clamped, forKey: Self.panelSolidityKey)
        }
    }
    var filter: SessionFilter = .all
    /// Sessions that produced output in the last few seconds.
    private(set) var activeSessionIDs: Set<String> = []
    /// Sessions that rang the bell and have not been touched since.
    private(set) var attentionSessionIDs: Set<String> = []
    var showNewAgent = false
    var pendingStopID: String?
    var errorNotice: UserNotice?
    var isStartingDaemon = false
    var gitSnapshots: [String: GitSnapshot] = [:]
    /// Path pinned in the context panel. Nil shows the file list without a diff.
    var contextSelection: String?
    /// When true, the panel selects the file the latest refresh says changed most.
    var contextFollowsEdits = true
    /// Path follow would select, including while another file is pinned.
    var contextLatestPath: String?
    /// Review is the default. Terminal is the panel's own shell.
    var contextShowsTerminal = false
    /// Bumped when the focused session's snapshot is replaced, so the diff reloads.
    var contextRevision = 0
    /// Shell owned by the context panel. It stays out of the sidebar until promoted.
    var scratchSession: SessionInfo?
    /// Id of that shell. Persisted so a relaunch keeps hiding it.
    /// Cleared on promote, which is what lets that session stay in the sidebar.
    var panelScratchID: String? {
        didSet {
            guard panelScratchID != oldValue else { return }
            guard !isPreview else { return }
            if let panelScratchID {
                UserDefaults.standard.set(panelScratchID, forKey: Self.panelScratchKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.panelScratchKey)
            }
        }
    }
    var terminal: TerminalPreferences = .standard {
        didSet {
            let clamped = terminal.clamped()
            if clamped != terminal {
                terminal = clamped
                return
            }
            persistTerminal(clamped)
            for controller in controllers.values {
                controller.apply(clamped)
            }
        }
    }
    /// Layout used the next time the app launches. The live split is separate.
    var defaultSplitLayout: SplitLayout = .stacked {
        didSet { store(defaultSplitLayout.rawValue, forKey: Self.defaultSplitKey) }
    }
    var confirmStop = true {
        didSet { store(confirmStop, forKey: Self.confirmStopKey) }
    }
    /// Empty means a new agent starts in the last directory that was used.
    var pinnedWorkingDirectory = "" {
        didSet { store(pinnedWorkingDirectory, forKey: Self.pinnedDirectoryKey) }
    }
    /// Names shown for sessions. The daemon keeps the id; this is the label.
    var sessionNames: [String: String] = [:] {
        didSet { store(sessionNames, forKey: Self.sessionNamesKey) }
    }

    /// Screenshot mode. The sidebar and the middle panes are fixtures.
    /// The context-panel shell still uses the daemon, so Helix can open.
    /// Set with `FLEET_PREVIEW=1`.
    var isPreview: Bool {
        ProcessInfo.processInfo.environment["FLEET_PREVIEW"] == "1"
    }

    var socketPath: String
    var autoStartDaemon: Bool {
        didSet {
            UserDefaults.standard.set(autoStartDaemon, forKey: Self.autoStartKey)
        }
    }

    @ObservationIgnored private var client: FleetClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var gitTask: Task<Void, Never>?
    @ObservationIgnored private var contextRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var scratchCreateTask: Task<Void, Never>?
    @ObservationIgnored private var inputPumpTask: Task<Void, Never>?
    @ObservationIgnored private var inputBuffers: [String: Data] = [:]
    /// Sessions whose input the daemon has already rejected as closed or missing.
    @ObservationIgnored private var inputMutedSessionIDs: Set<String> = []
    /// Set when the socket itself fails, so later keystrokes do not repeat the toast.
    @ObservationIgnored private var inputSuspended = false
    @ObservationIgnored private var resizeBuffers: [String: TerminalSize] = [:]
    @ObservationIgnored private var resizeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var controllers: [String: TerminalController] = [:]
    @ObservationIgnored private var attachedSessionIDs: Set<String> = []
    @ObservationIgnored private var attachingSessionIDs: Set<String> = []
    @ObservationIgnored private var errorToken = UUID()
    @ObservationIgnored private var paintedPreviewSizes: [String: TerminalSize] = [:]
    /// Fixture sessions whose terminals are drawn locally. A real shell is not in this set.
    @ObservationIgnored private var paintedPreviewIDs: Set<String> = []
    @ObservationIgnored private let plugin = PluginServer(token: PluginServer.newToken())
    @ObservationIgnored private var sessionListRefresh: Task<Void, Never>?
    @ObservationIgnored private var sessionListRefreshAgain = false

    private static let socketKey = "fleet.socketPath"
    private static let autoStartKey = "fleet.autoStartDaemon"
    private static let fontIDKey = "fleet.terminalFontID"
    private static let fontSizeKey = "fleet.terminalFontSize"
    private static let cursorKey = "fleet.terminalCursor"
    private static let spacingKey = "fleet.terminalLineSpacing"
    private static let scrollbackKey = "fleet.terminalScrollback"
    private static let optionMetaKey = "fleet.terminalOptionAsMeta"
    private static let bellKey = "fleet.terminalBellSound"
    private static let showSidebarKey = "fleet.showSidebar"
    private static let showContextKey = "fleet.showContext"
    private static let sessionNamesKey = "fleet.sessionNames"
    private static let panelSolidityKey = "fleet.panelSolidity"
    private static let defaultSplitKey = "fleet.defaultSplitLayout"
    private static let confirmStopKey = "fleet.confirmStop"
    private static let pinnedDirectoryKey = "fleet.pinnedWorkingDirectory"
    private static let panelScratchKey = "fleet.panelScratchID"

    init() {
        let defaults = UserDefaults.standard
        if let override = ProcessInfo.processInfo.environment["FLEET_SOCKET"], !override.isEmpty {
            socketPath = NSString(string: override).expandingTildeInPath
        } else {
            socketPath = defaults.string(forKey: Self.socketKey) ?? FleetPaths.defaultSocketPath
        }
        autoStartDaemon = defaults.object(forKey: Self.autoStartKey) as? Bool ?? true
        terminal = Self.loadTerminal(from: defaults)
        showSidebar = defaults.object(forKey: Self.showSidebarKey) as? Bool ?? true
        showContext = defaults.object(forKey: Self.showContextKey) as? Bool ?? true
        sessionNames = defaults.dictionary(forKey: Self.sessionNamesKey) as? [String: String] ?? [:]
        if let stored = defaults.object(forKey: Self.panelSolidityKey) as? Double {
            panelSolidity = min(1, max(0, stored))
        }
        if let raw = defaults.string(forKey: Self.defaultSplitKey),
           let layout = SplitLayout(rawValue: raw) {
            defaultSplitLayout = layout
            splitLayout = layout
        }
        confirmStop = defaults.object(forKey: Self.confirmStopKey) as? Bool ?? true
        pinnedWorkingDirectory = defaults.string(forKey: Self.pinnedDirectoryKey) ?? ""
        if let stored = defaults.string(forKey: Self.panelScratchKey), !stored.isEmpty {
            panelScratchID = stored
        }
        if isPreview {
            loadPreview()
        }
    }

    /// Preview must not replace the names and layout saved for real sessions.
    private func store(_ value: Any, forKey key: String) {
        guard !isPreview else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func loadPreview() {
        let fixture = ClaudePreview.make()
        connection = .connected(
            Welcome(
                protocolVersion: FleetProtocol.version,
                daemonVersion: "preview",
                engineState: "running",
                capabilities: []
            )
        )
        panelScratchID = nil
        showSidebar = true
        showContext = true
        isSplit = false
        splitLayout = .stacked
        filter = .all
        contextShowsTerminal = false
        paintedPreviewIDs = Set(fixture.sessions.map(\.id))
        sessions = fixture.sessions
        sessionNames = fixture.names
        activeSessionIDs = fixture.activeIDs
        attentionSessionIDs = fixture.attentionIDs
        primarySessionID = fixture.focusID
        secondarySessionID = nil
        focusedPane = .primary
    }

    private static func loadTerminal(from defaults: UserDefaults) -> TerminalPreferences {
        var prefs = TerminalPreferences.standard
        if let id = defaults.string(forKey: fontIDKey), !id.isEmpty {
            prefs.fontID = id
        }
        if let size = defaults.object(forKey: fontSizeKey) as? Double {
            prefs.fontSize = size
        }
        if let tag = defaults.string(forKey: cursorKey), !tag.isEmpty {
            prefs.cursorTag = tag
        }
        if let spacing = defaults.object(forKey: spacingKey) as? Double {
            prefs.lineSpacing = spacing
        }
        if let lines = defaults.object(forKey: scrollbackKey) as? Int {
            prefs.scrollback = lines
        }
        if let meta = defaults.object(forKey: optionMetaKey) as? Bool {
            prefs.optionIsMeta = meta
        }
        if let bell = defaults.object(forKey: bellKey) as? Bool {
            prefs.bellSound = bell
        }
        return prefs.clamped()
    }

    private func persistTerminal(_ prefs: TerminalPreferences) {
        guard !isPreview else { return }
        let defaults = UserDefaults.standard
        defaults.set(prefs.fontID, forKey: Self.fontIDKey)
        defaults.set(prefs.fontSize, forKey: Self.fontSizeKey)
        defaults.set(prefs.cursorTag, forKey: Self.cursorKey)
        defaults.set(prefs.lineSpacing, forKey: Self.spacingKey)
        defaults.set(prefs.scrollback, forKey: Self.scrollbackKey)
        defaults.set(prefs.optionIsMeta, forKey: Self.optionMetaKey)
        defaults.set(prefs.bellSound, forKey: Self.bellKey)
    }

    // MARK: - Derived state

    var focusedSession: SessionInfo? {
        session(for: focusedPane) ?? session(for: .primary)
    }

    var primarySession: SessionInfo? { session(for: .primary) }
    var secondarySession: SessionInfo? { session(for: .secondary) }

    var filteredSessions: [SessionInfo] {
        sessions.filter { $0.id != panelScratchID && matches($0, filter: filter) }
    }

    func matches(_ session: SessionInfo, filter: SessionFilter) -> Bool {
        if filter == .all { return true }
        let kind = sidebarClass(
            status: session.status,
            active: activeSessionIDs.contains(session.id),
            needsAttention: attentionSessionIDs.contains(session.id)
        )
        switch filter {
        case .all:
            return true
        case .running:
            return kind == .running
        case .idle:
            return kind == .idle
        case .needsYou:
            return kind == .needsYou
        }
    }

    func noteSessionActivity(_ sessionID: String, active: Bool, needsAttention: Bool) {
        let becameActive = active && !activeSessionIDs.contains(sessionID)
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
        if becameActive, sessionID == focusedSession?.id, sessionID != panelScratchID {
            scheduleContextRefresh()
        }
        guard let report = presenceReport(
            capabilities: daemonCapabilities,
            sessionID: sessionID,
            active: active,
            needsAttention: needsAttention
        ), let client else { return }
        Task { try? await client.reportPresence(report) }
    }

    private var daemonCapabilities: [String] {
        guard case .connected(let welcome) = connection else { return [] }
        return welcome.capabilities
    }

    var runningCount: Int { sessions.filter(\.isRunning).count }

    var canRemoveSessions: Bool {
        guard case .connected(let welcome) = connection else { return false }
        return welcome.capabilities.contains("remove_session")
    }

    func deletePromptTitle(for ids: [String]) -> String {
        if ids.count == 1, let session = session(id: ids[0]) {
            return "Delete “\(displayTitle(for: session))”?"
        }
        return "Delete \(ids.count) agents?"
    }

    func deletePromptMessage(for ids: [String]) -> String {
        let selected = ids.compactMap { session(id: $0) }
        let running = selected.filter(\.isRunning).count
        if selected.count == 1 {
            return running == 1
                ? "The agent is still running. It will be stopped and removed from the list."
                : "The agent will be removed from the list."
        }
        if running > 0 {
            return "The \(selected.count) selected agents will be removed. \(running) running \(running == 1 ? "agent" : "agents") will be stopped first."
        }
        return "The \(selected.count) selected agents will be removed from the list."
    }

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
        if let name = sessionNames[session.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return Self.displayTitle(forSessionID: session.id)
    }

    func setSessionName(_ sessionID: String, _ name: String) {
        guard session(id: sessionID) != nil else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let limited = String(trimmed.prefix(80))
        guard sessionNames[sessionID] != limited else { return }
        sessionNames[sessionID] = limited
    }

    static func displayTitle(forSessionID id: String) -> String {
        let words = id.split(separator: "-").map(String.init)
        guard !words.isEmpty else { return id }
        return words
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    func paneTitle(for session: SessionInfo) -> String {
        displayTitle(for: session)
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
        AgentNotices.displayPath(path)
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        if isPreview {
            startGitLoop()
            return
        }
        guard case .idle = connection else { return }
        await connect(allowAutoStart: true)
    }

    func connect() async {
        await connect(allowAutoStart: true)
    }

    private func connect(allowAutoStart: Bool) async {
        guard !connection.isConnected, !connection.isConnecting else { return }
        connection = .connecting
        errorNotice = nil

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
                    connection = .failed(AgentNotices.explainConnection(error, socketPath: socketPath))
                }
                isStartingDaemon = false
                return
            }
            connection = .failed(AgentNotices.explainConnection(error, socketPath: socketPath))
        }
    }

    private func openConnection() async throws {
        let client = try FleetClient(path: socketPath)
        do {
            let welcome = try await client.connect(clientName: "fleet-macos")
            self.client = client
            inputSuspended = false
            connection = .connected(welcome)
            attachedSessionIDs.removeAll()
            attachingSessionIDs.removeAll()
            startPlugin(client)
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
            showNotice(AgentNotices.daemonBinaryMissing())
            return
        }
        isStartingDaemon = true
        defer { isStartingDaemon = false }
        do {
            try await DaemonLauncher.start(executable: executable, socketPath: socketPath)
            await connect(allowAutoStart: false)
        } catch {
            connection = .failed(AgentNotices.explainConnection(error, socketPath: socketPath))
        }
    }

    func shutdown() {
        teardownConnection()
    }

    private func teardownConnection() {
        plugin.stop()
        sessionListRefresh?.cancel()
        sessionListRefresh = nil
        sessionListRefreshAgain = false
        eventTask?.cancel()
        eventTask = nil
        gitTask?.cancel()
        gitTask = nil
        inputPumpTask?.cancel()
        inputPumpTask = nil
        inputBuffers.removeAll()
        inputMutedSessionIDs.removeAll()
        inputSuspended = false
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

    private func startEventLoop(_ client: FleetClient) {
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
        if isPreview {
            client = nil
            attachedSessionIDs.removeAll()
            return
        }
        gitTask?.cancel()
        gitTask = nil
        connection = .failed(AgentNotices.daemonClosedConnection())
    }

    private func handle(_ event: ClientEvent) {
        switch event {
        case .output(let sessionID, _, let data):
            controllers[sessionID]?.feed(data)
        case .status(let sessionID, let status):
            updateStatus(status, for: sessionID)
        case .daemonStopping:
            if isPreview {
                client = nil
                showNotice(AgentNotices.daemonShuttingDown())
                return
            }
            connection = .failed(AgentNotices.daemonShuttingDown())
        case .sessionsChanged:
            scheduleSessionReload()
        }
    }

    private func updateStatus(_ status: SessionStatus, for sessionID: String) {
        controllers[sessionID]?.update(status: status)
        if scratchSession?.id == sessionID, let old = scratchSession {
            scratchSession = SessionInfo(
                id: old.id,
                pid: old.pid,
                program: old.program,
                cwd: old.cwd,
                size: old.size,
                status: status
            )
            return
        }
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
        if scratchSession?.id == info.id {
            scratchSession = info
            return
        }
        guard let index = sessions.firstIndex(where: { $0.id == info.id }) else { return }
        sessions[index] = info
    }

    // MARK: - Sessions

    private func scheduleSessionReload() {
        sessionListRefreshAgain = true
        guard sessionListRefresh == nil else { return }
        sessionListRefresh = Task { [weak self] in
            await self?.drainSessionReloads()
        }
    }

    private func drainSessionReloads() async {
        while sessionListRefreshAgain {
            sessionListRefreshAgain = false
            if Task.isCancelled { break }
            try? await reloadSessions()
        }
        sessionListRefresh = nil
        if sessionListRefreshAgain {
            scheduleSessionReload()
        }
    }

    private func startPlugin(_ client: FleetClient) {
        guard daemonCapabilities.contains(FleetProtocol.tasksCapability) else { return }
        do {
            _ = try plugin.start { endpoint in
                PluginHandler(
                    daemon: client,
                    presets: AgentCatalog.pluginPresets,
                    resolve: { AgentCatalog.resolveProgram($0) },
                    directoryExists: { path in
                        var isDirectory: ObjCBool = false
                        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                            && isDirectory.boolValue
                    },
                    endpoint: endpoint,
                    uniqueSuffix: {
                        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8).description
                    }
                )
            }
        } catch {
            plugin.stop()
        }
    }

    private func reloadSessions() async throws {
        guard let client else {
            throw FleetError.daemonUnavailable("Not connected to the daemon.")
        }
        let list = try await client.listSessions()
        if let scratchID = panelScratchID {
            if let found = list.first(where: { $0.id == scratchID }) {
                scratchSession = found
            } else {
                scratchSession = nil
                panelScratchID = nil
            }
        }
        let hidden = panelScratchID
        sessions = list.filter { $0.id != hidden }.sorted(by: sessionSort)
        let ids = Set(sessions.map(\.id))
        pruneSessionNames(keeping: ids)
        inputMutedSessionIDs.subtract(sessions.filter(\.isRunning).map(\.id))
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

    private func pruneSessionNames(keeping ids: Set<String>) {
        guard sessionNames.contains(where: { !ids.contains($0.key) }) else { return }
        sessionNames = sessionNames.filter { ids.contains($0.key) }
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
            if !paintsPreview(sessionID) {
                await attachIfNeeded(sessionID)
            }
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
        if confirmStop {
            pendingStopID = sessionID
        } else {
            stopSession(sessionID)
        }
    }

    func requestStopFocused() {
        if let id = focusedSession?.id {
            requestStop(id)
        }
    }

    func stopSession(_ sessionID: String) {
        pendingStopID = nil
        stopSessions([sessionID])
    }

    /// Stops the running sessions in the list. Exited sessions are ignored.
    func stopSessions(_ sessionIDs: [String]) {
        if isPreview { return }
        let ids = sessionIDs.filter { session(id: $0)?.isRunning == true }
        guard !ids.isEmpty else { return }
        Task {
            guard let client else {
                showNotice(AgentNotices.notConnected())
                return
            }
            var failures: [(id: String, error: Error)] = []
            for id in ids {
                do {
                    _ = try await client.stopSession(id: id)
                } catch {
                    failures.append((id, error))
                }
            }
            if let first = failures.first {
                showFailure(
                    first.error,
                    action: .stop,
                    sessionID: first.id,
                    extraCount: failures.count - 1
                )
            }
            try? await reloadSessions()
            await attachVisiblePanes()
        }
    }

    func requestDelete(_ sessionIDs: [String]) {
        if isPreview { return }
        guard connection.isConnected else {
            showNotice(AgentNotices.notConnected())
            return
        }
        guard canRemoveSessions else {
            showNotice(AgentNotices.deleteNeedsNewerDaemon())
            return
        }
        let existing = Set(sessions.map(\.id))
        let ids = sessionIDs.filter { existing.contains($0) }
        guard !ids.isEmpty else { return }
        let title = deletePromptTitle(for: ids)
        let message = deletePromptMessage(for: ids)
        // Present on the next turn. A context menu or row button is still
        // dismissing on this turn, and that swallows an alert shown immediately.
        Task { @MainActor in
            await nextMainTurn()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            await deleteSessions(ids)
        }
    }

    func requestDeleteFocused() {
        if let id = focusedSession?.id {
            requestDelete([id])
        }
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func deleteSessions(_ sessionIDs: [String]) async {
        guard let client else {
            showNotice(AgentNotices.notConnected())
            return
        }

        var stopFailure: (id: String, error: Error)?
        for id in sessionIDs where session(id: id)?.isRunning == true {
            do {
                _ = try await client.stopSession(id: id)
            } catch {
                if stopFailure == nil { stopFailure = (id, error) }
            }
        }

        var removedIDs: Set<String> = []
        var removeFailure: (id: String, error: Error)?
        for id in sessionIDs {
            if attachedSessionIDs.contains(id) {
                try? await client.detachSession(id: id)
                attachedSessionIDs.remove(id)
            }
            do {
                try await client.removeSession(id: id)
                removedIDs.insert(id)
            } catch {
                if removeFailure == nil { removeFailure = (id, error) }
            }
        }

        if !removedIDs.isEmpty {
            sessions.removeAll { removedIDs.contains($0.id) }
            reconcilePanes()
        }

        try? await reloadSessions()
        await attachVisiblePanes()

        for id in removedIDs {
            attachedSessionIDs.remove(id)
            attachingSessionIDs.remove(id)
            controllers.removeValue(forKey: id)
        }

        let failedCount = sessionIDs.count - removedIDs.count
        if failedCount > 0, let failure = removeFailure ?? stopFailure {
            showFailure(
                failure.error,
                action: .delete,
                sessionID: failure.id,
                extraCount: failedCount - 1
            )
        }
    }

    func forkSession(_ sessionID: String) {
        if isPreview { return }
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
                showNotice(notice(for: error, action: .fork, sessionID: session.id))
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
            throw FleetError.daemonUnavailable("Not connected to the daemon.")
        }

        let trimmedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty
            ? (program as NSString).lastPathComponent
            : trimmedName
        let id = uniqueSessionID(name)
        let launch = isPreview
            ? CodexLaunch(arguments: arguments, notice: nil)
            : await CodexControlSocket.adjustForLaunch(program: program, arguments: arguments)
        if let notice = launch.notice {
            showNotice(UserNotice(notice))
        }
        var launchArguments = launch.arguments
        if let endpoint = plugin.currentEndpoint() {
            launchArguments += AgentCatalog.pluginArguments(program: program, endpoint: endpoint)
        }
        let spec = CreateSession(
            id: id,
            program: program,
            args: launchArguments,
            cwd: cwd,
            env: sessionEnvironment(sessionID: id),
            size: TerminalSize(rows: 24, cols: 80)
        )
        let session = try await client.createSession(spec)
        if !trimmedName.isEmpty, trimmedName != Self.slug(trimmedName) {
            sessionNames[session.id] = String(trimmedName.prefix(80))
        }
        sessions.append(session)
        sessions.sort(by: sessionSort)

        primarySessionID = session.id
        if secondarySessionID == session.id {
            secondarySessionID = nil
        }
        focusedPane = .primary
        isSplit = false

        UserDefaults.standard.set(cwd, forKey: "fleet.lastWorkingDirectory")
        await attachIfNeeded(session.id)
        await refreshGit(cwd: cwd)
        return session
    }

    private static func slug(_ raw: String) -> String {
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
        return base
    }

    private func uniqueSessionID(_ raw: String) -> String {
        let base = Self.slug(raw)

        var used = Set(sessions.map(\.id))
        if let id = scratchSession?.id { used.insert(id) }
        if let id = panelScratchID { used.insert(id) }
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
        let controller = TerminalController(sessionID: sessionID, preferences: terminal)
        controller.onInput = { [weak self] data in
            self?.enqueueInput(data, for: sessionID)
        }
        controller.onResize = { [weak self] size in
            guard let self else { return }
            if self.paintsPreview(sessionID) {
                self.paintPreview(sessionID, size: size)
                return
            }
            self.enqueueResize(size, for: sessionID)
        }
        controller.onFocus = { [weak self] in
            guard let self else { return }
            // The panel shell takes the keyboard without becoming the middle pane.
            if sessionID == self.panelScratchID { return }
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

    /// The live controller when one already exists. Does not create one.
    func existingController(for sessionID: String) -> TerminalController? {
        controllers[sessionID]
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
        let known = sessions.contains(where: { $0.id == sessionID }) || scratchSession?.id == sessionID
        guard known else { return }

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
            if case let FleetError.api(apiError) = error, apiError.code == "already_attached" {
                attachedSessionIDs.insert(sessionID)
                return
            }
            showNotice(notice(for: error, action: .attach, sessionID: sessionID))
        }
    }

    private func paintPreview(_ sessionID: String, size: TerminalSize) {
        guard size.cols >= 20, size.rows >= 8 else { return }
        if paintedPreviewSizes[sessionID] == size { return }
        paintedPreviewSizes[sessionID] = size
        guard let controller = controllers[sessionID] else { return }
        let title = session(id: sessionID).map(displayTitle(for:)) ?? sessionID
        let bytes = ClaudePreview.screen(
            sessionID: sessionID,
            columns: Int(size.cols),
            rows: Int(size.rows),
            title: title
        )
        controller.reset()
        controller.feed(bytes)
    }

    /// Fixture panes are drawn locally. A context-panel shell is a real session.
    private func paintsPreview(_ sessionID: String) -> Bool {
        isPreview && paintedPreviewIDs.contains(sessionID)
    }

    private func enqueueInput(_ data: Data, for sessionID: String) {
        if paintsPreview(sessionID) { return }
        guard !data.isEmpty else { return }
        if inputSuspended || inputMutedSessionIDs.contains(sessionID) { return }
        inputBuffers[sessionID, default: Data()].append(data)
        guard inputPumpTask == nil else { return }

        inputPumpTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(8))
            guard let self else { return }
            while !self.inputBuffers.isEmpty {
                let batches = self.inputBuffers
                self.inputBuffers.removeAll()
                guard let client = self.client else {
                    self.suspendInput(AgentNotices.notConnected())
                    break
                }
                for (id, data) in batches {
                    do {
                        try await client.input(id: id, data: data)
                    } catch {
                        self.reportInputFailure(error, sessionID: id)
                        if self.inputSuspended { break }
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

    func choosePinnedDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let current = pinnedWorkingDirectory.isEmpty
            ? Self.defaultWorkingDirectory
            : pinnedWorkingDirectory
        panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pinnedWorkingDirectory = url.path
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
        let previous = gitSnapshots[cwd]?.changes ?? []
        let snapshot = await Task.detached(priority: .utility) {
            GitService.snapshot(cwd: cwd)
        }.value
        gitSnapshots[cwd] = snapshot
        guard cwd == contextSession?.cwd else { return }
        contextRevision += 1
        let latest = ChangeFollow.selection(
            previous: previous,
            next: snapshot.changes,
            selected: contextSelection,
            following: true
        )
        contextLatestPath = latest
        if contextFollowsEdits {
            contextSelection = latest
        } else {
            contextSelection = ChangeFollow.selection(
                previous: previous,
                next: snapshot.changes,
                selected: contextSelection,
                following: false
            )
        }
    }

    private func scheduleContextRefresh() {
        contextRefreshTask?.cancel()
        contextRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await self.refreshGitForFocusedSession()
        }
    }

    // MARK: - Panel shell

    /// Opens the panel shell the first time. An exited shell stays exited.
    func openScratchTerminal() async {
        guard scratchSession == nil else { return }
        await createScratch(cwd: scratchDirectory(replacing: nil))
    }

    /// Replaces an exited panel shell. Starts in the focused agent's directory.
    func newScratchShell() async {
        let previous = scratchSession
        let cwd = scratchDirectory(replacing: previous)
        if let previous {
            await discardScratch(previous)
        }
        await createScratch(cwd: cwd)
    }

    /// Focuses the panel shell and runs Helix on the file. The click is the confirmation.
    func editInScratch(_ path: String) async {
        contextShowsTerminal = true
        if scratchSession?.isRunning == true {
            await openScratchTerminal()
        } else {
            await newScratchShell()
        }
        guard let session = scratchSession, session.isRunning else { return }
        await attachIfNeeded(session.id)
        guard attachedSessionIDs.contains(session.id) else { return }
        let base = focusedSession?.cwd ?? session.cwd
        let absolute = Self.absolutePath(base, path)
        enqueueInput(Data("hx -- \(Self.shellQuote(absolute))\n".utf8), for: session.id)
        controller(for: session.id).focus()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.scratchSession?.id == session.id else { return }
            self.controller(for: session.id).focus()
        }
    }

    /// Sends the panel shell to the focused agent's directory.
    func jumpScratchToAgent() {
        guard let session = scratchSession, session.isRunning else { return }
        guard let cwd = focusedSession?.cwd, Self.directoryExists(cwd) else { return }
        enqueueInput(Data("cd \(Self.shellQuote(cwd))\n".utf8), for: session.id)
    }

    /// Moves the panel shell into the sidebar and selects it in the middle pane.
    func promoteScratch() {
        guard let session = scratchSession, session.isRunning else { return }
        scratchSession = nil
        panelScratchID = nil
        if sessionNames[session.id] == nil {
            sessionNames[session.id] = "Shell"
        }
        if !sessions.contains(where: { $0.id == session.id }) {
            sessions.append(session)
            sessions.sort(by: sessionSort)
        }
        contextShowsTerminal = false
        let sessionID = session.id
        Task { @MainActor in
            await Task.yield()
            self.selectSession(sessionID)
        }
    }

    static func shellQuote(_ value: String) -> String {
        ShellEscape.quote(value)
    }

    static func normalizeDirectory(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("file:") {
            if let url = URL(string: value), url.isFileURL {
                value = url.path
            } else if let range = value.range(of: "file://") {
                let rest = value[range.upperBound...]
                if let slash = rest.firstIndex(of: "/") {
                    value = String(rest[slash...])
                }
            }
        }
        if value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    static func absolutePath(_ cwd: String, _ relative: String) -> String {
        if relative.hasPrefix("/") { return relative }
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(relative)
            .standardizedFileURL
            .path
    }

    private func scratchDirectory(replacing previous: SessionInfo?) -> String {
        if let cwd = focusedSession?.cwd, Self.directoryExists(cwd) { return cwd }
        if let cwd = previous?.cwd, Self.directoryExists(cwd) { return cwd }
        return Self.defaultWorkingDirectory
    }

    private func createScratch(cwd: String) async {
        if scratchSession != nil { return }
        if let existing = scratchCreateTask {
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.createScratchNow(cwd: cwd)
        }
        scratchCreateTask = task
        await task.value
        scratchCreateTask = nil
    }

    private func createScratchNow(cwd: String) async {
        guard scratchSession == nil else { return }
        if client == nil, isPreview {
            guard await ensurePreviewDaemon() else { return }
        }
        guard let client else { return }
        let directory = Self.directoryExists(cwd) ? cwd : Self.defaultWorkingDirectory
        let id = await nextScratchID(client: client)
        let spec = CreateSession(
            id: id,
            program: "/bin/zsh",
            args: ["-l"],
            cwd: directory,
            env: sessionEnvironment(sessionID: id),
            size: TerminalSize(rows: 24, cols: 80)
        )
        do {
            let session = try await client.createSession(spec)
            panelScratchID = session.id
            scratchSession = session
            await attachIfNeeded(session.id)
        } catch {
            showNotice(notice(for: error, action: .create, sessionID: id))
        }
    }

    /// Opens a daemon connection for the context-panel shell without replacing
    /// the fixture sessions or the saved window.
    private func ensurePreviewDaemon() async -> Bool {
        if client != nil { return true }
        do {
            try await openPreviewDaemon()
            return client != nil
        } catch {
            if autoStartDaemon, isConnectionFailure(error), let executable = DaemonLauncher.locate() {
                do {
                    try await DaemonLauncher.start(executable: executable, socketPath: socketPath)
                    try await openPreviewDaemon()
                    return client != nil
                } catch {
                    showNotice(AgentNotices.explainConnection(error, socketPath: socketPath))
                    return false
                }
            }
            showNotice(AgentNotices.explainConnection(error, socketPath: socketPath))
            return false
        }
    }

    private func openPreviewDaemon() async throws {
        let client = try FleetClient(path: socketPath)
        do {
            _ = try await client.connect(clientName: "fleet-macos")
            self.client = client
            inputSuspended = false
            startEventLoop(client)
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private func nextScratchID(client: FleetClient) async -> String {
        var used = Set(sessions.map(\.id))
        if let id = scratchSession?.id { used.insert(id) }
        if let id = panelScratchID { used.insert(id) }
        if let remote = try? await client.listSessions() {
            used.formUnion(remote.map(\.id))
        }
        let base = isPreview ? "preview-shell" : "fleet-scratch"
        if !used.contains(base) { return base }
        var suffix = 2
        while used.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    private func discardScratch(_ session: SessionInfo) async {
        if let client {
            if attachedSessionIDs.contains(session.id) {
                try? await client.detachSession(id: session.id)
            }
            try? await client.removeSession(id: session.id)
        }
        attachedSessionIDs.remove(session.id)
        attachingSessionIDs.remove(session.id)
        controllers.removeValue(forKey: session.id)
        if scratchSession?.id == session.id {
            scratchSession = nil
        }
        if panelScratchID == session.id {
            panelScratchID = nil
        }
    }

    // MARK: - Errors

    func showNotice(_ notice: UserNotice) {
        guard errorNotice != notice else { return }
        errorNotice = notice
        let token = UUID()
        errorToken = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.errorToken == token else { return }
            self.errorNotice = nil
        }
    }

    func clearError() {
        errorNotice = nil
    }

    private func showFailure(
        _ error: Error,
        action: AgentAction,
        sessionID: String,
        extraCount: Int
    ) {
        var notice = notice(for: error, action: action, sessionID: sessionID)
        if extraCount > 0 {
            let extra = extraCount == 1
                ? "1 other agent also failed."
                : "\(extraCount) other agents also failed."
            notice.detail = notice.detail.isEmpty ? extra : "\(notice.detail) \(extra)"
        }
        showNotice(notice)
    }

    private func notice(for error: Error, action: AgentAction, sessionID: String) -> UserNotice {
        AgentNotices.explain(
            error,
            action: action,
            agent: agentName(for: sessionID),
            exit: exitStatus(for: sessionID)
        )
    }

    private func agentName(for sessionID: String) -> String {
        let title = session(id: sessionID).map(displayTitle(for:))
            ?? Self.displayTitle(forSessionID: sessionID)
        return title.isEmpty ? "The agent" : title
    }

    private func exitStatus(for sessionID: String) -> SessionExit? {
        guard let session = session(id: sessionID), case .exited(let exit) = session.status else {
            return nil
        }
        return exit
    }

    private func suspendInput(_ notice: UserNotice) {
        inputBuffers.removeAll()
        guard !inputSuspended else { return }
        inputSuspended = true
        showNotice(notice)
    }

    private func reportInputFailure(_ error: Error, sessionID: String) {
        if AgentNotices.isTransport(error) {
            suspendInput(AgentNotices.explain(
                error,
                action: .sendInput,
                agent: agentName(for: sessionID),
                exit: nil
            ))
            return
        }
        let code = AgentNotices.code(of: error)
        if code == "session_closed" || code == "session_not_found" {
            inputBuffers[sessionID] = nil
            guard inputMutedSessionIDs.insert(sessionID).inserted else { return }
            showNotice(notice(for: error, action: .sendInput, sessionID: sessionID))
            let id = sessionID
            Task { [weak self] in
                guard let self else { return }
                try? await self.reloadSessions()
                if let session = self.session(id: id) {
                    self.controllers[id]?.update(status: session.status)
                }
            }
            return
        }
        showNotice(notice(for: error, action: .sendInput, sessionID: sessionID))
    }

    private func isConnectionFailure(_ error: Error) -> Bool {
        if case FleetError.connectFailed = error {
            return true
        }
        return false
    }

    // MARK: - Defaults

    static var defaultWorkingDirectory: String {
        if let env = ProcessInfo.processInfo.environment["FLEET_WORKDIR"], !env.isEmpty {
            return NSString(string: env).expandingTildeInPath
        }
        if let pinned = UserDefaults.standard.string(forKey: "fleet.pinnedWorkingDirectory"),
           directoryExists(pinned) {
            return pinned
        }
        if let saved = UserDefaults.standard.string(forKey: "fleet.lastWorkingDirectory"),
           FileManager.default.fileExists(atPath: saved) {
            return saved
        }
        let home = NSHomeDirectory()
        for candidate in ["\(home)/code", "\(home)/Desktop/fleet"] {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return home
    }

    private static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
