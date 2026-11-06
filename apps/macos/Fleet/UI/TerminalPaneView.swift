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
                PaneDropOverlay(model: model)
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

        return HStack(spacing: 6) {
            if renamingTabID == tab.id {
                InlineNameField(text: $draft, onCommit: commitRename, onCancel: cancelRename)
                    .frame(height: 18)
            } else {
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
                if exited, !kept {
                    Button("Keep") {
                        model.keepTab(tab.id)
                    }
                    .buttonStyle(.plain)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.accent)
                    .help("Keep this tab open")
                }
                if hoveredTabID == tab.id || active {
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
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 96, maxWidth: exited ? 240 : 180, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color.white.opacity(isFocused ? 0.12 : 0.07) : Color.white.opacity(0.03))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard let session else { return }
            draft = model.displayTitle(for: session)
            renamingTabID = tab.id
            model.focusPane(pane.id)
        }
        .onTapGesture {
            model.editWorkspace(.focusTab(paneID: pane.id, tabID: tab.id))
        }
        .onHover { hovering in
            hoveredTabID = hovering ? tab.id : (hoveredTabID == tab.id ? nil : hoveredTabID)
        }
        .onDrag {
            let drag = TabDrag(tabID: tab.id, paneID: pane.id, sessionID: tab.sessionID)
            model.beginTabDrag(drag)
            let provider = NSItemProvider()
            let payload = drag.data
            provider.registerDataRepresentation(
                forTypeIdentifier: TabDrag.pasteboardType,
                visibility: .all
            ) { completion in
                completion(payload, nil)
                return nil
            }
            return provider
        }
        .background {
            TabDropTarget(onTargeted: { _ in }) { drag in
                guard let drag = drag ?? model.draggingTab else { return false }
                model.dropTab(drag, onPane: pane.id, index: index)
                return true
            }
        }
        .contextMenu {
            Button("Rename") {
                guard let session else { return }
                draft = model.displayTitle(for: session)
                renamingTabID = tab.id
            }
            if let session {
                Button("Fork Agent") {
                    model.forkSession(session.id)
                }
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
