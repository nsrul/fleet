import AppKit
import DirectorAPI
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var hoveredSessionID: String?

    private var groups: [SessionGroup] {
        let filtered = model.filteredSessions
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
            Color.clear.frame(height: 52)

            segmentedControl

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .padding(.leading, 24)
                            .padding(.top, index == 0 ? 20 : 22)
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
        .frame(width: 256)
        .background(Palette.sidebarSurface.ignoresSafeArea())
    }

    private var segmentedControl: some View {
        HStack(spacing: 0) {
            ForEach(SessionFilter.allCases) { filter in
                let selected = model.filter == filter
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        model.filter = filter
                    }
                } label: {
                    Text("\(filter.title) \(count(for: filter))")
                        .font(Typography.calloutMedium)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .frame(height: 28)
        .padding(.horizontal, 16)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            HorizontalDivider()
            HStack(spacing: 14) {
                Button {
                    model.showNewAgent = true
                } label: {
                    Text("+ New agent")
                }
                .buttonStyle(PlainTextButtonStyle())

                Text("⌘N")
                    .font(Typography.captionRegular)
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 8)

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

    private func count(for filter: SessionFilter) -> Int {
        switch filter {
        case .all: return model.sessions.count
        case .running: return model.runningCount
        }
    }

    private func projectName(for cwd: String) -> String {
        if cwd == NSHomeDirectory() { return "home" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
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
            Button("Open in First Pane") {
                model.selectSession(session.id, in: .primary)
            }
            .disabled(model.primarySessionID == session.id)

            Button("Open in Second Pane") {
                model.selectSession(session.id, in: .secondary)
            }
            .disabled(model.secondarySessionID == session.id)

            Divider()

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
