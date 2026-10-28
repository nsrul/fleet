import AppKit
import DirectorAPI
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searchFocused: Bool
    @State private var hoveredSessionID: String?
    @State private var searchOpen = false
    @State private var searchText = ""

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
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Agents")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 4)

                    if groups.isEmpty {
                        Text(emptyMessage)
                            .font(Typography.captionRegular)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 16)
                            .padding(.top, 8)
                    }

                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.leading, 16)
                            .padding(.top, index == 0 ? 8 : 18)
                            .padding(.bottom, 6)

                        VStack(spacing: 2) {
                            ForEach(group.sessions) { session in
                                SessionRow(
                                    model: model,
                                    session: session,
                                    isHovered: hoveredSessionID == session.id
                                )
                                .padding(.horizontal, 10)
                                .onHover { hovering in
                                    hoveredSessionID = hovering ? session.id : nil
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebarSurface.ignoresSafeArea())
        .onChange(of: searchOpen) { _, open in
            if !open { searchText = "" }
        }
    }

    private var toolRow: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            sidebarIconButton(
                systemImage: "magnifyingglass",
                help: "Search",
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

    private var isFocusedRow: Bool {
        assignedPane == model.focusedPane
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
            HStack(spacing: 9) {
                StatusDot(status: session.status)
                    .frame(width: 7)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayTitle(for: session))
                        .font(Typography.bodyMedium)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Typography.captionRegular)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.statusLabel(for: session))
                        .font(Typography.captionRegular)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    if let assignedPane {
                        Text("\(assignedPane.number)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                assignedPane == model.focusedPane ? Palette.accent : Color.secondary
                            )
                            .frame(width: 14, height: 12)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            )
                    }
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
            .overlay(alignment: .leading) {
                if isFocusedRow {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Palette.accent)
                        .frame(width: 2, height: 18)
                        .padding(.leading, 4)
                }
            }
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

    private var subtitle: String {
        let agent = AgentCatalog.displayName(for: session.program)
        let location = model.branch(for: session.cwd)
            ?? (session.cwd as NSString).lastPathComponent
        return "\(agent) · \(location)"
    }
}
