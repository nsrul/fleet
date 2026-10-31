import AppKit
import DirectorAPI
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searchFocused: Bool
    @State private var hoveredSessionID: String?
    @State private var hoveredGroupID: String?
    @State private var searchOpen = false
    @State private var searchText = ""
    @State private var selectedSessionIDs: Set<String> = []
    @State private var selectionAnchorID: String?
    /// Directories the user opened. Active directories expand without an entry here.
    @State private var expandedGroupIDs: Set<String> = []
    /// Directories the user closed, including an active one they collapsed.
    @State private var collapsedGroupIDs: Set<String> = []

    private var groups: [SessionGroup] {
        let filtered = model.filteredSessions.filter(matchesSearch)
        let grouped = Dictionary(grouping: filtered, by: \.cwd)
        return grouped.map { cwd, sessions in
            SessionGroup(
                id: cwd,
                title: projectName(for: cwd),
                sessions: sessions.sorted {
                    $0.id.localizedStandardCompare($1.id) == .orderedAscending
                }
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolRow

            if searchOpen {
                searchField
            }

            newAgentControl

            ScrollView {
                let sessionGroups = groups
                let anyAssigned = sessionGroups.contains(where: containsAssignedSession)
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Agents")
                        .font(Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, SidebarList.labelLeading)
                        .padding(.top, 16)
                        .padding(.bottom, 6)

                    if sessionGroups.isEmpty {
                        Text(emptyMessage)
                            .font(Typography.captionRegular)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, SidebarList.labelLeading)
                            .padding(.top, 4)
                    }

                    ForEach(Array(sessionGroups.enumerated()), id: \.element.id) { index, group in
                        let expanded = isExpanded(group, anyAssigned: anyAssigned)
                        directoryHeader(group, index: index, expanded: expanded)

                        if expanded {
                            VStack(spacing: 2) {
                                ForEach(group.sessions) { session in
                                    SessionRow(
                                        model: model,
                                        session: session,
                                        isHovered: hoveredSessionID == session.id,
                                        isSelected: selectedSessionIDs.contains(session.id),
                                        onActivate: { activate(session.id) },
                                        onStop: { model.stopSession(session.id) },
                                        onDelete: { model.requestDelete([session.id]) }
                                    )
                                    .onHover { hovering in
                                        hoveredSessionID = hovering ? session.id : nil
                                    }
                                }
                            }
                            .padding(.top, 2)
                            .padding(.bottom, 6)
                        }
                    }
                }
                .padding(.horizontal, SidebarList.inset)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            if selectedSessionIDs.isEmpty {
                footer
            } else {
                selectionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            PanelSurface(solid: Palette.sidebarSurface, solidity: model.panelSolidity)
                .ignoresSafeArea()
        }
        .onChange(of: searchOpen) { _, open in
            if !open { searchText = "" }
        }
        .onChange(of: model.sessions) { _, sessions in
            let ids = Set(sessions.map(\.id))
            selectedSessionIDs.formIntersection(ids)
            if let anchor = selectionAnchorID, !ids.contains(anchor) {
                selectionAnchorID = nil
            }
        }
        .onChange(of: model.focusedSession?.cwd) { _, cwd in
            guard let cwd else { return }
            collapsedGroupIDs.remove(cwd)
            expandedGroupIDs.insert(cwd)
        }
        .onDeleteCommand {
            if !selectedSessionIDs.isEmpty {
                model.requestDelete(Array(selectedSessionIDs))
            } else if let id = model.focusedSession?.id {
                model.requestDelete([id])
            }
        }
    }

    private var toolRow: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            sidebarIconButton(
                systemImage: searchOpen ? "chevron.up" : "magnifyingglass",
                help: searchOpen ? "Close search" : "Search",
                isOn: searchOpen
            ) {
                searchOpen.toggle()
            }
            filterMenu
        }
        .padding(.trailing, WorkspaceChrome.trailingInset)
        .frame(height: WorkspaceChrome.barHeight)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $model.filter) {
                ForEach(SessionFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(model.filter == .all ? Color.secondary : Palette.accent)
                .frame(
                    width: WorkspaceChrome.controlSize,
                    height: WorkspaceChrome.controlSize
                )
                .background(
                    RoundedRectangle(
                        cornerRadius: WorkspaceChrome.controlRadius,
                        style: .continuous
                    )
                    .fill(Color.primary.opacity(model.filter == .all ? 0 : 0.08))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter")
        .accessibilityLabel("Filter")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .onAppear { searchFocused = true }
    }

    private var newAgentControl: some View {
        Button {
            model.showNewAgent = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
                    // The pencil tip sits in the symbol box, so the square reads low.
                    .offset(y: -1.5)
                Text("New agent")
                    .font(Typography.bodyMedium)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.accent)
            // Symbol bearing is about 2pt, so the ink lands on the Agents heading.
            .padding(.leading, SidebarList.labelLeading - 2)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(NewAgentButtonStyle())
        .focusEffectDisabled()
        .help("New agent (⌘N)")
        .accessibilityLabel("New agent")
        .padding(.horizontal, SidebarList.inset)
        .padding(.top, 6)
    }

    private func sidebarIconButton(
        systemImage: String,
        help: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .frame(
                    width: WorkspaceChrome.controlSize,
                    height: WorkspaceChrome.controlSize
                )
                .background(
                    RoundedRectangle(
                        cornerRadius: WorkspaceChrome.controlRadius,
                        style: .continuous
                    )
                    .fill(Color.primary.opacity(isOn ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func directoryHeader(_ group: SessionGroup, index: Int, expanded: Bool) -> some View {
        let active = containsAssignedSession(group)
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                toggleGroup(group.id, expanded: expanded)
            }
        } label: {
            HStack(spacing: SidebarList.iconGap) {
                Image(systemName: active ? "folder.fill" : "folder")
                    .font(.system(size: 13, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(active ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .frame(width: SidebarList.icon, height: SidebarList.icon)
                Text(group.title)
                    .font(Typography.bodyMedium)
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: SidebarList.chevron, height: SidebarList.chevron)
            }
            .padding(.leading, SidebarList.labelLeading)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hoveredGroupID == group.id ? Palette.sidebarHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(.top, index == 0 ? 0 : 10)
        .onHover { hovering in
            hoveredGroupID = hovering ? group.id : (hoveredGroupID == group.id ? nil : hoveredGroupID)
        }
        .accessibilityLabel("\(group.title), directory")
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .help(expanded ? "Collapse \(group.title)" : "Expand \(group.title)")
    }

    private func containsAssignedSession(_ group: SessionGroup) -> Bool {
        group.sessions.contains { model.paneSlot(for: $0.id) != nil }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Active directories (ones with a session in a pane) start open.
    /// A search shows every matching directory open.
    private func isExpanded(_ group: SessionGroup, anyAssigned: Bool) -> Bool {
        if isSearching { return true }
        if collapsedGroupIDs.contains(group.id) { return false }
        if expandedGroupIDs.contains(group.id) { return true }
        if !anyAssigned { return true }
        return containsAssignedSession(group)
    }

    private func toggleGroup(_ id: String, expanded: Bool) {
        if expanded {
            expandedGroupIDs.remove(id)
            collapsedGroupIDs.insert(id)
        } else {
            collapsedGroupIDs.remove(id)
            expandedGroupIDs.insert(id)
        }
    }

    private func matchesSearch(_ session: SessionInfo) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let title = model.displayTitle(for: session)
        let agent = AgentCatalog.displayName(for: session.program)
        return title.localizedStandardContains(query)
            || agent.localizedStandardContains(query)
            || session.cwd.localizedStandardContains(query)
            || session.id.localizedStandardContains(query)
    }

    private var selectedRunningSessionIDs: [String] {
        Array(selectedSessionIDs.filter { model.session(id: $0)?.isRunning == true })
    }

    private func activate(_ sessionID: String) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            selectionAnchorID = sessionID
            if selectedSessionIDs.contains(sessionID) {
                selectedSessionIDs.remove(sessionID)
            } else {
                selectedSessionIDs.insert(sessionID)
            }
            return
        }
        if flags.contains(.shift), let anchor = selectionAnchorID {
            selectRange(from: anchor, to: sessionID)
            return
        }
        clearSelection()
        selectionAnchorID = sessionID
        model.selectSession(sessionID)
    }

    private func selectRange(from anchor: String, to target: String) {
        let ids = groups.flatMap { $0.sessions.map(\.id) }
        guard let anchorIndex = ids.firstIndex(of: anchor),
              let targetIndex = ids.firstIndex(of: target)
        else {
            selectedSessionIDs = [target]
            selectionAnchorID = target
            return
        }
        selectedSessionIDs = Set(
            ids[min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)]
        )
    }

    private func clearSelection() {
        selectedSessionIDs.removeAll()
        selectionAnchorID = nil
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            HorizontalDivider()
            HStack(spacing: 4) {
                Text("\(selectedSessionIDs.count) selected")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !selectedRunningSessionIDs.isEmpty {
                    Button("Stop") {
                        model.stopSessions(selectedRunningSessionIDs)
                    }
                    .buttonStyle(SelectionActionButtonStyle(tint: Palette.accent))
                    .help("Stop the selected running agents")
                }
                Button("Remove") {
                    model.requestDelete(Array(selectedSessionIDs))
                }
                .buttonStyle(SelectionActionButtonStyle(tint: Palette.error))
                .help("Remove the selected agents")
                Button {
                    clearSelection()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear selection")
            }
            .padding(.leading, 20)
            .padding(.trailing, 10)
            .frame(height: 52)
        }
    }

    private var emptyMessage: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matches"
        }
        switch model.filter {
        case .all: return "No agents"
        case .running: return "No agents running"
        case .idle: return "No idle agents"
        case .needsYou: return "Nothing needs you"
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            HorizontalDivider()
            HStack {
                Spacer(minLength: 0)
                Button("Settings") {
                    openSettings()
                }
                .buttonStyle(.plain)
                .font(Typography.body)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
    }

    private func projectName(for cwd: String) -> String {
        if cwd == NSHomeDirectory() { return "home" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

/// Shared columns for the agent list.
/// The section label and the directory folder share the first column.
/// An agent row steps in so its mark sits under the directory name and the
/// row reads as content of that accordion. The chevron stays on the trailing edge.
private enum SidebarList {
    static let inset: CGFloat = 10
    static let labelLeading: CGFloat = 6
    static let chevron: CGFloat = 12
    static let icon: CGFloat = 16
    static let iconGap: CGFloat = 8
    /// Inset of the mark inside the session pill.
    static let rowIconLeading: CGFloat = labelLeading
    /// Indents the pill until the mark lands on the directory name.
    static var rowLeading: CGFloat { icon + iconGap }
}

private struct NewAgentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08))
            )
    }
}

private struct SessionGroup: Identifiable {
    let id: String
    let title: String
    let sessions: [SessionInfo]
}

private struct SessionRow: View {
    @Bindable var model: AppModel
    let session: SessionInfo
    let isHovered: Bool
    let isSelected: Bool
    let onActivate: () -> Void
    let onStop: () -> Void
    let onDelete: () -> Void
    @State private var isRenaming = false
    @State private var draft = ""

    private var assignedPane: PaneSlot? {
        model.paneSlot(for: session.id)
    }

    private var background: Color {
        if isRenaming {
            return Palette.sidebarHover
        }
        if isSelected {
            return Palette.accent.opacity(0.12)
        }
        if assignedPane != nil {
            return Palette.sidebarSelection
        }
        if isHovered {
            return Palette.sidebarHover
        }
        return .clear
    }

    var body: some View {
        HStack(spacing: 0) {
            if isRenaming {
                HStack(spacing: SidebarList.iconGap) {
                    AgentMark(program: session.program)
                        .frame(width: SidebarList.icon, height: SidebarList.icon)
                    InlineNameField(text: $draft, onCommit: commitRename, onCancel: cancelRename)
                        .frame(height: 18)
                        .accessibilityLabel("Session name")
                }
                .padding(.leading, SidebarList.rowIconLeading)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            } else {
                Button(action: onActivate) {
                    HStack(spacing: SidebarList.iconGap) {
                        AgentMark(program: session.program)
                            .frame(width: SidebarList.icon, height: SidebarList.icon)

                        Text(model.displayTitle(for: session))
                            .font(Typography.bodyMedium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        if let assignedPane, !isHovered {
                            Text("\(assignedPane.number)")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(
                                    assignedPane == model.focusedPane ? Palette.accent : Color.secondary
                                )
                                .frame(width: 16, height: 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )
                        }
                    }
                    .padding(.leading, SidebarList.rowIconLeading)
                    .padding(.trailing, isHovered ? 2 : 8)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(AgentCatalog.displayName(for: session.program)), \(model.displayTitle(for: session))"
                )
                .accessibilityValue(session.isRunning ? "Running" : "Stopped")
                .accessibilityAddTraits(isSelected ? .isSelected : [])

                if isHovered {
                    HStack(spacing: 2) {
                        if session.isRunning {
                            RowActionButton(
                                systemImage: "stop.circle.fill",
                                help: "Stop agent",
                                tint: Palette.error,
                                action: onStop
                            )
                        }
                        RowActionButton(
                            systemImage: "trash",
                            help: "Delete agent",
                            tint: Palette.error,
                            action: onDelete
                        )
                    }
                    .padding(.trailing, 6)
                }
            }
        }
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)
        )
        .padding(.leading, SidebarList.rowLeading)
        .contextMenu {
            Button("Rename") {
                draft = model.displayTitle(for: session)
                // The menu is still dismissing on this turn and would steal focus.
                Task { @MainActor in
                    isRenaming = true
                }
            }

            Button("Fork Agent") {
                model.forkSession(session.id)
            }

            Button("Copy Session ID") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(session.id, forType: .string)
            }

            Button("Reveal Working Directory") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: session.cwd)
                ])
            }

            Divider()

            if session.isRunning {
                Button("Stop Agent…", role: .destructive) {
                    model.requestStop(session.id)
                }
            }

            Button("Delete Agent…", role: .destructive, action: onDelete)
        }
    }

    private func commitRename(_ value: String) {
        guard isRenaming else { return }
        isRenaming = false
        model.setSessionName(session.id, value)
    }

    private func cancelRename() {
        isRenaming = false
    }
}

/// A borderless field that edits a session name in the row and selects the text.
private struct InlineNameField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        context.coordinator.armFocus(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        guard field.currentEditor() == nil, field.stringValue != text else { return }
        field.stringValue = text
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineNameField
        private var didFocus = false
        private var focusAttempts = 0
        private var cancelled = false

        init(_ parent: InlineNameField) {
            self.parent = parent
        }

        func armFocus(_ field: NSTextField) {
            Task { @MainActor [weak self, weak field] in
                guard let self, let field, !self.didFocus else { return }
                guard let window = field.window else {
                    self.focusAttempts += 1
                    if self.focusAttempts < 6 { self.armFocus(field) }
                    return
                }
                self.didFocus = true
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                cancelled = true
                parent.onCancel()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !cancelled, let field = notification.object as? NSTextField else { return }
            parent.onCommit(field.stringValue)
        }
    }
}

private struct RowActionButton: View {
    let systemImage: String
    let help: String
    let tint: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovered ? tint : tint.opacity(0.75))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct SelectionActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.calloutMedium)
            .foregroundStyle(tint.opacity(configuration.isPressed ? 0.7 : 1))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
            )
            .contentShape(Rectangle())
    }
}
