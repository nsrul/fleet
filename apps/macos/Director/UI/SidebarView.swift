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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, SidebarList.labelLeading)
                        .padding(.top, 14)
                        .padding(.bottom, 8)

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
                                        isHovered: hoveredSessionID == session.id
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

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebarSurface.ignoresSafeArea())
        .onChange(of: searchOpen) { _, open in
            if !open { searchText = "" }
        }
        .onChange(of: model.focusedSession?.cwd) { _, cwd in
            guard let cwd else { return }
            collapsedGroupIDs.remove(cwd)
            expandedGroupIDs.insert(cwd)
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
        .padding(.trailing, 8)
        .frame(height: 38)
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
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
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
                    .font(.system(size: 15, weight: .regular))
                Text("New agent")
                    .font(.system(size: 14, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(NewAgentButtonStyle())
        .focusEffectDisabled()
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .help("New agent (⌘N)")
        .accessibilityLabel("New agent")
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
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
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
            HStack(spacing: SidebarList.chevronGap) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: SidebarList.chevron, height: SidebarList.chevron)
                Text(group.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, SidebarList.labelLeading)
            .padding(.trailing, 6)
            .frame(height: 26)
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
        .accessibilityLabel(group.title)
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

/// One inset for the agent list, so the section label, directory chevron,
/// and row icons share a column and the directory name lines up with the icons.
private enum SidebarList {
    static let inset: CGFloat = 10
    static let labelLeading: CGFloat = 6
    static let chevron: CGFloat = 12
    static let chevronGap: CGFloat = 6
    static let icon: CGFloat = 16
    static let iconGap: CGFloat = 8
    /// Pill starts just left of the directory title. Icon then lands on that title.
    static var rowLeading: CGFloat { labelLeading + chevron + chevronGap - 8 }
}

private struct NewAgentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
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

    private var assignedPane: PaneSlot? {
        model.paneSlot(for: session.id)
    }

    private var background: Color {
        if assignedPane != nil {
            return Palette.sidebarSelection
        }
        if isHovered {
            return Palette.sidebarHover
        }
        return .clear
    }

    var body: some View {
        Button {
            model.selectSession(session.id)
        } label: {
            HStack(spacing: SidebarList.iconGap) {
                AgentMark(program: session.program)
                    .frame(width: SidebarList.icon, height: SidebarList.icon)

                Text(model.displayTitle(for: session))
                    .font(Typography.bodyMedium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let assignedPane {
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
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .frame(height: 32)
            .accessibilityLabel(
                "\(AgentCatalog.displayName(for: session.program)), \(model.displayTitle(for: session))"
            )
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
            .padding(.leading, SidebarList.rowLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
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

            Button("Stop Session…", role: .destructive) {
                model.requestStop(session.id)
            }
        }
    }
}
