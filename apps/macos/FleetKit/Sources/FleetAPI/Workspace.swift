import Foundation

/// Side-by-side panes, or panes stacked on top of each other.
///
/// `horizontal` places panes in a row. `vertical` places them in a column.
public enum SplitAxis: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical
}

/// One open session inside a pane. A session appears in at most one tab.
public struct WorkspaceTab: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sessionID: String

    public init(id: String, sessionID: String) {
        self.id = id
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
    }
}

/// Tabs owned by one pane.
public struct WorkspacePane: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var tabs: [WorkspaceTab]
    public var activeTabID: String?

    public init(id: String, tabs: [WorkspaceTab], activeTabID: String?) {
        self.id = id
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case tabs
        case activeTabID = "active_tab_id"
    }
}

/// The arrangement of open sessions. Terminal scrollback is not stored here.
///
/// Zero panes means nothing is open. One pane has no split. Two panes name a split axis.
public struct Workspace: Codable, Equatable, Sendable {
    public var split: SplitAxis?
    public var panes: [WorkspacePane]
    public var focusedPaneID: String

    public static let empty = Workspace(split: nil, panes: [], focusedPaneID: "")

    public init(split: SplitAxis?, panes: [WorkspacePane], focusedPaneID: String) {
        self.split = split
        self.panes = panes
        self.focusedPaneID = focusedPaneID
    }

    private enum CodingKeys: String, CodingKey {
        case split
        case panes
        case focusedPaneID = "focused_pane_id"
    }

    public var focusedPane: WorkspacePane? {
        panes.first { $0.id == focusedPaneID }
    }

    public func isOpen(_ sessionID: String) -> Bool {
        panes.contains { pane in pane.tabs.contains { $0.sessionID == sessionID } }
    }

    /// True when the session is the active tab of either pane.
    public func isActiveTab(_ sessionID: String) -> Bool {
        panes.contains { pane in
            guard let active = pane.activeTabID,
                  let tab = pane.tabs.first(where: { $0.id == active })
            else { return false }
            return tab.sessionID == sessionID
        }
    }

    public func paneID(forSession sessionID: String) -> String? {
        panes.first { pane in pane.tabs.contains { $0.sessionID == sessionID } }?.id
    }

    public func tabID(forSession sessionID: String) -> String? {
        panes.lazy.flatMap(\.tabs).first { $0.sessionID == sessionID }?.id
    }

    func location(ofTab id: String) -> TabLocation? {
        for (paneIndex, pane) in panes.enumerated() {
            if let tabIndex = pane.tabs.firstIndex(where: { $0.id == id }) {
                return TabLocation(
                    paneIndex: paneIndex,
                    paneID: pane.id,
                    tabIndex: tabIndex,
                    tabID: id
                )
            }
        }
        return nil
    }

    func location(ofSession id: String) -> TabLocation? {
        for (paneIndex, pane) in panes.enumerated() {
            if let tabIndex = pane.tabs.firstIndex(where: { $0.sessionID == id }) {
                return TabLocation(
                    paneIndex: paneIndex,
                    paneID: pane.id,
                    tabIndex: tabIndex,
                    tabID: pane.tabs[tabIndex].id
                )
            }
        }
        return nil
    }

    /// Drops empty panes and repairs focus after an edit.
    func normalized() -> Workspace {
        var workspace = self
        workspace.panes.removeAll { $0.tabs.isEmpty }
        if workspace.panes.count > 2 {
            workspace.panes = Array(workspace.panes.prefix(2))
        }
        switch workspace.panes.count {
        case 0:
            return .empty
        case 1:
            workspace.split = nil
        default:
            if workspace.split == nil {
                workspace.split = .horizontal
            }
        }
        if !workspace.panes.contains(where: { $0.id == workspace.focusedPaneID }) {
            workspace.focusedPaneID = workspace.panes[0].id
        }
        for index in workspace.panes.indices {
            let ids = workspace.panes[index].tabs.map(\.id)
            if let active = workspace.panes[index].activeTabID, ids.contains(active) {
                continue
            }
            workspace.panes[index].activeTabID = ids.last
        }
        return workspace
    }
}

struct TabLocation: Equatable {
    var paneIndex: Int
    var paneID: String
    var tabIndex: Int
    var tabID: String
}

/// One change to the open arrangement. The daemon checks the result again.
public enum WorkspaceEdit: Equatable, Sendable {
    case open(sessionID: String)
    /// Closes the tab and leaves the session running.
    case closeTab(id: String)
    case focusPane(id: String)
    case focusTab(paneID: String, tabID: String)
    case moveTab(id: String, toPaneID: String, index: Int)
    /// Moves a tab to a new or existing edge. A third pane is never created.
    case split(tabID: String, axis: SplitAxis, placeFirst: Bool)
    /// Opens `sessionID` in a second pane. A single remaining tab stays put.
    case openBeside(sessionID: String, axis: SplitAxis)
    case prune(keeping: Set<String>)
}

public enum WorkspaceEditor {
    public static func apply(
        _ workspace: Workspace,
        _ edit: WorkspaceEdit,
        newID: () -> String
    ) -> Workspace {
        switch edit {
        case .open(let sessionID):
            return open(workspace, sessionID: sessionID, newID: newID)
        case .closeTab(let id):
            return close(workspace, tabID: id)
        case .focusPane(let id):
            guard workspace.panes.contains(where: { $0.id == id }) else { return workspace }
            var workspace = workspace
            workspace.focusedPaneID = id
            return workspace
        case .focusTab(let paneID, let tabID):
            guard let paneIndex = workspace.panes.firstIndex(where: { $0.id == paneID }),
                  workspace.panes[paneIndex].tabs.contains(where: { $0.id == tabID })
            else { return workspace }
            var workspace = workspace
            workspace.focusedPaneID = paneID
            workspace.panes[paneIndex].activeTabID = tabID
            return workspace
        case .moveTab(let id, let toPaneID, let index):
            return move(workspace, tabID: id, toPaneID: toPaneID, index: index)
        case .split(let tabID, let axis, let placeFirst):
            return split(workspace, tabID: tabID, axis: axis, placeFirst: placeFirst, newID: newID)
        case .openBeside(let sessionID, let axis):
            return openBeside(workspace, sessionID: sessionID, axis: axis, newID: newID)
        case .prune(let keeping):
            var workspace = workspace
            for index in workspace.panes.indices {
                workspace.panes[index].tabs.removeAll { !keeping.contains($0.sessionID) }
            }
            return workspace.normalized()
        }
    }

    private static func open(
        _ workspace: Workspace,
        sessionID: String,
        newID: () -> String
    ) -> Workspace {
        if let place = workspace.location(ofSession: sessionID) {
            var workspace = workspace
            workspace.focusedPaneID = place.paneID
            workspace.panes[place.paneIndex].activeTabID = place.tabID
            return workspace
        }
        var workspace = workspace
        let tab = WorkspaceTab(id: newID(), sessionID: sessionID)
        if workspace.panes.isEmpty {
            let pane = WorkspacePane(id: newID(), tabs: [tab], activeTabID: tab.id)
            workspace.panes = [pane]
            workspace.focusedPaneID = pane.id
            workspace.split = nil
            return workspace
        }
        let index = workspace.panes.firstIndex { $0.id == workspace.focusedPaneID } ?? 0
        workspace.panes[index].tabs.append(tab)
        workspace.panes[index].activeTabID = tab.id
        workspace.focusedPaneID = workspace.panes[index].id
        return workspace
    }

    private static func close(_ workspace: Workspace, tabID: String) -> Workspace {
        guard let place = workspace.location(ofTab: tabID) else { return workspace }
        var workspace = workspace
        workspace.panes[place.paneIndex].tabs.remove(at: place.tabIndex)
        if workspace.panes[place.paneIndex].tabs.isEmpty {
            let removedFocus = workspace.panes[place.paneIndex].id == workspace.focusedPaneID
            workspace.panes.remove(at: place.paneIndex)
            if removedFocus {
                workspace.focusedPaneID = workspace.panes.first?.id ?? ""
            }
        } else if workspace.panes[place.paneIndex].activeTabID == tabID {
            let tabs = workspace.panes[place.paneIndex].tabs
            let neighbor = min(place.tabIndex, tabs.count - 1)
            workspace.panes[place.paneIndex].activeTabID = tabs[neighbor].id
        }
        return workspace.normalized()
    }

    private static func move(
        _ workspace: Workspace,
        tabID: String,
        toPaneID: String,
        index: Int
    ) -> Workspace {
        guard let source = workspace.location(ofTab: tabID),
              workspace.panes.contains(where: { $0.id == toPaneID })
        else { return workspace }
        var workspace = workspace
        let tab = workspace.panes[source.paneIndex].tabs.remove(at: source.tabIndex)
        let samePane = source.paneID == toPaneID
        if workspace.panes[source.paneIndex].tabs.isEmpty {
            if samePane {
                workspace.panes[source.paneIndex].tabs = [tab]
                workspace.panes[source.paneIndex].activeTabID = tab.id
                workspace.focusedPaneID = source.paneID
                return workspace.normalized()
            }
            workspace.panes.remove(at: source.paneIndex)
        } else if workspace.panes[source.paneIndex].activeTabID == tabID {
            let tabs = workspace.panes[source.paneIndex].tabs
            let neighbor = min(source.tabIndex, tabs.count - 1)
            workspace.panes[source.paneIndex].activeTabID = tabs[neighbor].id
        }
        guard let destination = workspace.panes.firstIndex(where: { $0.id == toPaneID }) else {
            return workspace.normalized()
        }
        var insertAt = index
        if samePane, source.tabIndex < index {
            insertAt -= 1
        }
        insertAt = min(max(0, insertAt), workspace.panes[destination].tabs.count)
        workspace.panes[destination].tabs.insert(tab, at: insertAt)
        workspace.panes[destination].activeTabID = tab.id
        workspace.focusedPaneID = toPaneID
        return workspace.normalized()
    }

    private static func split(
        _ workspace: Workspace,
        tabID: String,
        axis: SplitAxis,
        placeFirst: Bool,
        newID: () -> String
    ) -> Workspace {
        guard let place = workspace.location(ofTab: tabID) else { return workspace }
        if workspace.panes.count >= 2 {
            let target = placeFirst ? 0 : min(1, workspace.panes.count - 1)
            if place.paneIndex == target {
                var workspace = workspace
                workspace.split = axis
                workspace.focusedPaneID = workspace.panes[target].id
                workspace.panes[target].activeTabID = tabID
                return workspace.normalized()
            }
            let destination = workspace.panes[target].id
            var moved = move(
                workspace,
                tabID: tabID,
                toPaneID: destination,
                index: workspace.panes[target].tabs.count
            )
            if moved.panes.count == 2 {
                moved.split = axis
            }
            return moved.normalized()
        }
        guard workspace.panes.count == 1, workspace.panes[0].tabs.count >= 2 else {
            return workspace
        }
        var workspace = workspace
        let tab = workspace.panes[0].tabs.remove(at: place.tabIndex)
        if workspace.panes[0].activeTabID == tabID {
            let tabs = workspace.panes[0].tabs
            let neighbor = min(place.tabIndex, tabs.count - 1)
            workspace.panes[0].activeTabID = tabs[neighbor].id
        }
        let pane = WorkspacePane(id: newID(), tabs: [tab], activeTabID: tab.id)
        if placeFirst {
            workspace.panes.insert(pane, at: 0)
        } else {
            workspace.panes.append(pane)
        }
        workspace.split = axis
        workspace.focusedPaneID = pane.id
        return workspace.normalized()
    }

    private static func openBeside(
        _ workspace: Workspace,
        sessionID: String,
        axis: SplitAxis,
        newID: () -> String
    ) -> Workspace {
        if workspace.panes.count >= 2 {
            return workspace
        }
        if workspace.panes.isEmpty {
            return open(workspace, sessionID: sessionID, newID: newID)
        }
        if let place = workspace.location(ofSession: sessionID) {
            return split(
                workspace,
                tabID: place.tabID,
                axis: axis,
                placeFirst: false,
                newID: newID
            )
        }
        var workspace = workspace
        let tab = WorkspaceTab(id: newID(), sessionID: sessionID)
        let pane = WorkspacePane(id: newID(), tabs: [tab], activeTabID: tab.id)
        workspace.panes.append(pane)
        workspace.split = axis
        workspace.focusedPaneID = pane.id
        return workspace.normalized()
    }
}
