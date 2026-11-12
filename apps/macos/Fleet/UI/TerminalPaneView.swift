import AppKit
import FleetAPI
import SwiftUI

struct TerminalPaneView: View {
    @Bindable var model: AppModel
    let pane: WorkspacePane
    var showsSidebarToggle = false
    var showsContextToggle = false
    @State private var renamingTabID: String?
    @State private var draft = ""
    @State private var hoveredTabID: String?

    private var isFocused: Bool { model.workspace.focusedPaneID == pane.id }

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            terminal
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.terminal)
    }

    private var terminal: some View {
        Group {
            if let session = model.session(in: pane.id) {
                TerminalHostView(controller: model.controller(for: session.id))
                    .id(session.id)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 16)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            if model.draggingTab != nil {
                PaneDropOverlay(model: model, paneID: pane.id)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.32), value: model.draggingTab != nil)
        .onTapGesture {
            model.focusPane(pane.id)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            if showsSidebarToggle {
                sidebarToggle
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabButton(tab, index: index)
                    }
                    newTabButton
                }
                .padding(.vertical, 5)
            }
            Spacer(minLength: 0)
            if showsContextToggle {
                contextToggle
            }
        }
        .padding(.leading, showsSidebarToggle ? (model.showSidebar ? 8 : 72) : 8)
        .padding(.trailing, showsContextToggle ? 8 : 8)
        .frame(height: WorkspaceChrome.barHeight)
        .background {
            TabDropTarget(onTargeted: { _ in }) { drag in
                guard let drag = drag ?? model.draggingTab else { return false }
                guard drag.paneID != pane.id || pane.tabs.count > 1 else { return false }
                model.dropTab(drag, onPane: pane.id, index: pane.tabs.count)
                return true
            }
        }
    }

    private var sidebarToggle: some View {
        PanelToggleButton(
            systemImage: "sidebar.left",
            help: model.showSidebar ? "Hide sidebar" : "Show sidebar",
            isOn: model.showSidebar,
            action: model.toggleSidebar
        )
    }

    private var contextToggle: some View {
        PanelToggleButton(
            systemImage: "sidebar.right",
            help: model.showContext ? "Hide context panel" : "Show context panel",
            isOn: model.showContext,
            action: model.toggleContext
        )
    }

    private var newTabButton: some View {
        Button {
            model.focusPane(pane.id)
            model.showNewAgent = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.terminalSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New agent")
        .accessibilityLabel("New agent")
    }

    private func tabButton(_ tab: WorkspaceTab, index: Int) -> some View {
        let session = model.session(id: tab.sessionID)
        let active = pane.activeTabID == tab.id
        let title = session.map { model.displayTitle(for: $0) } ?? tab.sessionID
        let exited = session.map { !$0.isRunning } ?? true
        let kept = model.isTabKept(tab.id)
        _ = model.graceTick
        let seconds = model.graceSeconds(for: tab.id)

        let drag = TabDrag(tabID: tab.id, paneID: pane.id, sessionID: tab.sessionID)
        let showClose = hoveredTabID == tab.id || active
        let showKeep = exited && !kept
        return ZStack {
            if renamingTabID == tab.id {
                InlineNameField(text: $draft, onCommit: commitRename, onCancel: cancelRename)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            } else {
                HStack(spacing: 6) {
                    if let session {
                        AgentMark(program: session.program)
                            .frame(width: 14, height: 14)
                        stateDot(session)
                    }
                    Text(title)
                        .font(Typography.caption)
                        .foregroundStyle(exited ? Palette.terminalSecondary : Palette.terminalTitle)
                        .lineLimit(1)
                    if exited, let seconds, !kept {
                        Text("\(seconds)s")
                            .font(Typography.captionRegular)
                            .foregroundStyle(Palette.attention)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .padding(.trailing, tabControlReserve(showKeep: showKeep, showClose: showClose))
                .allowsHitTesting(false)
                // Transparent, and in front of the title. A hidden title bar treats
                // this row as window chrome unless the hit view refuses to move it.
                TabGrabber(
                    drag: drag,
                    title: title,
                    program: session?.program,
                    onClick: {
                        model.editWorkspace(.focusTab(paneID: pane.id, tabID: tab.id))
                    },
                    onDoubleClick: {
                        guard let session else { return }
                        draft = model.displayTitle(for: session)
                        renamingTabID = tab.id
                        model.focusPane(pane.id)
                    },
                    onHover: { hovering in
                        hoveredTabID = hovering ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID)
                    },
                    onReceive: { incoming in
                        let resolved = incoming ?? model.draggingTab
                        guard let resolved else { return false }
                        model.dropTab(resolved, onPane: pane.id, index: index)
                        return true
                    },
                    onDragStart: { model.beginTabDrag($0) },
                    onDragEnd: { model.endTabDrag($0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .trailing) {
            if renamingTabID != tab.id {
                HStack(spacing: 6) {
                    if showKeep {
                        Button("Keep") {
                            model.keepTab(tab.id)
                        }
                        .buttonStyle(.plain)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.accent)
                        .help("Keep this tab open")
                    }
                    if showClose {
                        Button {
                            model.closeTab(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Palette.terminalSecondary)
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Close tab")
                        .accessibilityLabel("Close \(title)")
                    }
                }
                .padding(.trailing, 8)
                .allowsHitTesting(model.draggingTab == nil)
            }
        }
        .frame(minWidth: 96, maxWidth: exited ? 240 : 180, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color.white.opacity(isFocused ? 0.12 : 0.07) : Color.white.opacity(0.03))
        )
        .opacity(model.draggingTab?.tabID == tab.id ? 0.4 : 1)
        .contextMenu {
            Button("Rename") {
                guard let session else { return }
                draft = model.displayTitle(for: session)
                renamingTabID = tab.id
            }
            if let session {
                Button("Fork Agent in New Process") {
                    model.forkSession(session.id)
                }
                .help("Starts a new process with the same command, working directory, and arguments. The conversation is not copied.")
            }
            if model.workspace.panes.count == 2 {
                Button("Move to Other Pane") {
                    if let other = model.workspace.panes.first(where: { $0.id != pane.id }) {
                        model.dropTab(
                            TabDrag(tabID: tab.id, paneID: pane.id, sessionID: tab.sessionID),
                            onPane: other.id,
                            index: other.tabs.count
                        )
                    }
                }
            }
            Divider()
            Button("Close Tab") {
                model.closeTab(tab.id)
            }
        }
        .help(title)
        .accessibilityLabel("\(title), tab \(index + 1)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func stateDot(_ session: SessionInfo) -> some View {
        let kind = sidebarClass(
            status: session.status,
            active: model.activeSessionIDs.contains(session.id),
            needsAttention: model.attentionSessionIDs.contains(session.id)
        )
        return Circle()
            .fill(color(for: kind))
            .frame(width: 6, height: 6)
            .accessibilityLabel(kind.rawValue)
    }

    private func color(for kind: SidebarClass) -> Color {
        switch kind {
        case .running: return Palette.accent
        case .idle: return Palette.terminalSecondary
        case .needsYou: return Palette.attention
        }
    }

    /// Room left of the title so Keep and Close, drawn above the grabber, do not cover it.
    private func tabControlReserve(showKeep: Bool, showClose: Bool) -> CGFloat {
        var width: CGFloat = 8
        if showKeep { width += 40 }
        if showClose { width += 22 }
        return width
    }

    private func commitRename(_ value: String) {
        guard let tabID = renamingTabID,
              let tab = pane.tabs.first(where: { $0.id == tabID })
        else {
            renamingTabID = nil
            return
        }
        renamingTabID = nil
        model.setSessionName(tab.sessionID, value)
    }

    private func cancelRename() {
        renamingTabID = nil
    }
}
