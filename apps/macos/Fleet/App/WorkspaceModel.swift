import AppKit
import FleetAPI
import Foundation

/// A tab being dragged between panes or onto a split edge.
struct TabDrag: Equatable, Codable, Sendable {
    var tabID: String
    var paneID: String
    var sessionID: String

    static let pasteboardType = "dev.fleet.workspace-tab"

    var data: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    static func read(_ pasteboard: NSPasteboard) -> TabDrag? {
        guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(pasteboardType)),
              let drag = try? JSONDecoder().decode(TabDrag.self, from: data)
        else { return nil }
        return drag
    }
}

/// Set for the whole drag so drop targets can accept hits without stealing clicks.
enum TabDragSession {
    nonisolated(unsafe) static var active = false
}

extension AppModel {
    private var workspaceWritePending: Bool {
        workspaceGeneration != ackedWorkspaceGeneration
    }

    func editWorkspace(_ edit: WorkspaceEdit) {
        let next = WorkspaceEditor.apply(workspace, edit, newID: newWorkspaceID)
        guard next != workspace else { return }
        workspace = next
    }

    func newWorkspaceID() -> String {
        UUID().uuidString.lowercased()
    }

    func closeTab(_ tabID: String) {
        keptTabIDs.remove(tabID)
        exitDeadlines.removeValue(forKey: tabID)
        editWorkspace(.closeTab(id: tabID))
    }

    @discardableResult
    func closeActiveTab() -> Bool {
        guard let tabID = workspace.focusedPane?.activeTabID else { return false }
        closeTab(tabID)
        return true
    }

    func keepTab(_ tabID: String) {
        keptTabIDs.insert(tabID)
        exitDeadlines.removeValue(forKey: tabID)
        graceTick &+= 1
    }

    @discardableResult
    func selectTab(index: Int) -> Bool {
        guard let pane = workspace.focusedPane, pane.tabs.indices.contains(index - 1) else {
            return false
        }
        let tab = pane.tabs[index - 1]
        editWorkspace(.focusTab(paneID: pane.id, tabID: tab.id))
        return true
    }

    func canSelectTab(index: Int) -> Bool {
        guard let pane = workspace.focusedPane else { return false }
        return pane.tabs.indices.contains(index - 1)
    }

    func cycleTab(forward: Bool) {
        guard let pane = workspace.focusedPane, !pane.tabs.isEmpty else { return }
        let current = pane.tabs.firstIndex { $0.id == pane.activeTabID } ?? 0
        let count = pane.tabs.count
        let next = forward ? (current + 1) % count : (current + count - 1) % count
        editWorkspace(.focusTab(paneID: pane.id, tabID: pane.tabs[next].id))
    }

    func cyclePane(forward: Bool) {
        guard workspace.panes.count > 1 else { return }
        let current = workspace.panes.firstIndex { $0.id == workspace.focusedPaneID } ?? 0
        let target = forward
            ? min(current + 1, workspace.panes.count - 1)
            : max(current - 1, 0)
        guard target != current else { return }
        focusPane(workspace.panes[target].id)
    }

    func openInOtherPane(_ sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        guard let other = workspace.panes.first(where: { $0.id != workspace.focusedPaneID }) else {
            return
        }
        if let tabID = workspace.tabID(forSession: sessionID),
           let paneID = workspace.paneID(forSession: sessionID) {
            if paneID == other.id {
                editWorkspace(.focusTab(paneID: other.id, tabID: tabID))
                return
            }
            editWorkspace(.moveTab(id: tabID, toPaneID: other.id, index: other.tabs.count))
            return
        }
        editWorkspace(.focusPane(id: other.id))
        editWorkspace(.open(sessionID: sessionID))
    }

    func beginSplit() {
        guard workspace.panes.count == 1 else { return }
        showSplitPicker = true
    }

    func split(with sessionID: String) {
        showSplitPicker = false
        editWorkspace(.openBeside(sessionID: sessionID, axis: preferredSplitAxis))
    }

    func focusTerminal() {
        guard let id = focusedSession?.id else { return }
        controller(for: id).focus()
    }

    func beginTabDrag(_ drag: TabDrag) {
        TabDragSession.active = true
        draggingTab = drag
        let board = NSPasteboard(name: .drag)
        board.setData(drag.data, forType: NSPasteboard.PasteboardType(TabDrag.pasteboardType))
        dragWatch?.cancel()
        dragWatch = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    // The drop is delivered on mouse-up. Wait so the target is
                    // still in the window when AppKit asks it to perform.
                    try? await Task.sleep(for: .milliseconds(280))
                    if Task.isCancelled { break }
                    self.endTabDrag(drag)
                    break
                }
            }
        }
    }

    func dropTab(_ drag: TabDrag, onPane paneID: String, index: Int) {
        editWorkspace(.moveTab(id: drag.tabID, toPaneID: paneID, index: index))
        finishTabDrag(drag)
    }

    func dropTab(_ drag: TabDrag, axis: SplitAxis, placeFirst: Bool) {
        editWorkspace(.split(tabID: drag.tabID, axis: axis, placeFirst: placeFirst))
        finishTabDrag(drag)
    }

    /// Clears the drag after AppKit has finished the drop callback.
    private func finishTabDrag(_ drag: TabDrag) {
        Task { @MainActor in
            endTabDrag(drag)
        }
    }

    private func endTabDrag(_ drag: TabDrag) {
        guard draggingTab?.tabID == drag.tabID else { return }
        TabDragSession.active = false
        draggingTab = nil
    }

    func graceSeconds(for tabID: String) -> Int? {
        guard let deadline = exitDeadlines[tabID] else { return nil }
        return max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
    }

    func isTabKept(_ tabID: String) -> Bool {
        keptTabIDs.contains(tabID)
    }

    func loadWorkspace() async {
        persistsWorkspace = daemonCapabilities.contains(FleetProtocol.workspaceCapability)
        guard persistsWorkspace, let client else { return }
        do {
            let remote = try await client.getWorkspace()
            let live = Set(sessions.map(\.id))
            let pruned = WorkspaceEditor.apply(remote, .prune(keeping: live), newID: newWorkspaceID)
            suppressWorkspacePersistence = true
            workspace = pruned
            suppressWorkspacePersistence = false
            if pruned != remote {
                scheduleWorkspaceSave()
            }
        } catch {
            persistsWorkspace = false
        }
    }

    func applyRemoteWorkspace(_ remote: Workspace) {
        guard persistsWorkspace, !workspaceWritePending else { return }
        let live = Set(sessions.map(\.id))
        let pruned = WorkspaceEditor.apply(remote, .prune(keeping: live), newID: newWorkspaceID)
        guard pruned != workspace else { return }
        suppressWorkspacePersistence = true
        workspace = pruned
        suppressWorkspacePersistence = false
    }

    func scheduleWorkspaceSave() {
        guard !isPreview, persistsWorkspace, client != nil else { return }
        workspaceGeneration += 1
        let generation = workspaceGeneration
        workspaceWriteTask?.cancel()
        workspaceWriteTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self.flushWorkspaceSave(generation)
        }
    }

    func noteWorkspaceFocus() {
        let tabIDs = Set(workspace.panes.flatMap { $0.tabs.map(\.id) })
        let kept = keptTabIDs.intersection(tabIDs)
        if kept != keptTabIDs {
            keptTabIDs = kept
        }
        exitDeadlines = exitDeadlines.filter { tabIDs.contains($0.key) }
        let id = focusedSession?.id
        if id != lastFocusedSessionID {
            lastFocusedSessionID = id
            if let id {
                controller(for: id).focus()
                Task { await refreshGitForFocusedSession() }
            }
        }
        Task { await syncOpenAttachments() }
    }

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let chord = KeyChord(
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue,
                characters: event.charactersIgnoringModifiers ?? "",
                keyCode: event.keyCode
            )
            let handled = MainActor.assumeIsolated {
                self.handleKeyDown(chord)
            }
            return handled ? nil : event
        }
    }

    func startGraceLoop() {
        guard graceTask == nil else { return }
        graceTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.sweepExitGrace()
            }
        }
    }

    private func flushWorkspaceSave(_ generation: Int) async {
        guard persistsWorkspace, let client, generation == workspaceGeneration else { return }
        let snapshot = workspace
        do {
            let stored = try await client.putWorkspace(snapshot)
            guard generation == workspaceGeneration else { return }
            ackedWorkspaceGeneration = generation
            if stored != workspace {
                suppressWorkspacePersistence = true
                workspace = stored
                suppressWorkspacePersistence = false
            }
        } catch {
            guard generation == workspaceGeneration else { return }
            showNotice(UserNotice(
                "The workspace could not be saved.",
                detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ))
            if let fresh = try? await client.getWorkspace() {
                let live = Set(sessions.map(\.id))
                let pruned = WorkspaceEditor.apply(fresh, .prune(keeping: live), newID: newWorkspaceID)
                suppressWorkspacePersistence = true
                workspace = pruned
                suppressWorkspacePersistence = false
            }
            ackedWorkspaceGeneration = generation
        }
        if generation == workspaceGeneration {
            workspaceWriteTask = nil
        }
    }

    func storeKeptTabs() {
        guard !isPreview else { return }
        let values = keptTabIDs.sorted()
        if values.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.keptTabsKey)
        } else {
            UserDefaults.standard.set(values, forKey: Self.keptTabsKey)
        }
    }

    private func sweepExitGrace() {
        let tabIDs = Set(workspace.panes.flatMap { $0.tabs.map(\.id) })
        exitDeadlines = exitDeadlines.filter { tabIDs.contains($0.key) }
        let now = Date()
        var close: [String] = []
        var counting = false
        for pane in workspace.panes {
            let focused = pane.id == workspace.focusedPaneID
            for tab in pane.tabs {
                guard let session = session(id: tab.sessionID), !session.isRunning else {
                    exitDeadlines.removeValue(forKey: tab.id)
                    continue
                }
                if keptTabIDs.contains(tab.id) {
                    exitDeadlines.removeValue(forKey: tab.id)
                    continue
                }
                let reading = focused && pane.activeTabID == tab.id
                if reading {
                    exitDeadlines.removeValue(forKey: tab.id)
                    continue
                }
                if exitDeadlines[tab.id] == nil {
                    exitDeadlines[tab.id] = now.addingTimeInterval(Self.exitGrace)
                }
                counting = true
                if let deadline = exitDeadlines[tab.id], deadline <= now {
                    close.append(tab.id)
                }
            }
        }
        if counting || !close.isEmpty {
            graceTick &+= 1
        }
        for id in close {
            closeTab(id)
        }
    }

    private func handleKeyDown(_ chord: KeyChord) -> Bool {
        if showNewAgent || showSplitPicker { return false }
        let mods = NSEvent.ModifierFlags(rawValue: chord.modifiers)
        let characters = chord.characters

        if mods == .command, characters == "w" {
            return closeActiveTab()
        }
        if mods == [.command, .shift], characters == "w" {
            NSApp.keyWindow?.performClose(nil)
            return true
        }
        if mods == .command, characters == "t" {
            showNewAgent = true
            return true
        }
        if mods == .command, let index = Int(characters), (1...9).contains(index) {
            return selectTab(index: index)
        }
        if chord.keyCode == 48, mods == .control || mods == [.control, .shift] {
            cycleTab(forward: mods == .control)
            return true
        }
        if mods == [.command, .option], chord.keyCode == 123 || chord.keyCode == 124 {
            cyclePane(forward: chord.keyCode == 124)
            return true
        }
        if mods == [.command, .shift], characters == "\\" {
            beginSplit()
            return true
        }
        return false
    }
}

/// The parts of a key event the monitor can move onto the main actor.
private struct KeyChord: Sendable {
    var modifiers: UInt
    var characters: String
    var keyCode: UInt16
}
