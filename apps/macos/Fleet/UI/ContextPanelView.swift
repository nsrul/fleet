import AppKit
import FleetAPI
import SwiftUI

struct ContextPanelView: View {
    @Bindable var model: AppModel
    @State private var hoveredChangeID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            HorizontalDivider()
            if model.contextShowsTerminal {
                ContextTerminalView(model: model)
            } else {
                review
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            PanelSurface(solid: Palette.contextBackground, solidity: model.panelSolidity)
                .ignoresSafeArea()
        }
    }

    private var session: SessionInfo? { model.contextSession }
    private var snapshot: GitSnapshot? { model.contextSnapshot }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(headerTitle)
                    .font(Typography.monoBranch)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                headerSummary

                if model.contextShowsTerminal {
                    terminalActions
                } else {
                    reviewActions
                }
            }
            .frame(minHeight: WorkspaceChrome.barHeight)

            if model.contextShowsTerminal, let agent = driftedAgentDirectory {
                HStack(spacing: 8) {
                    Text(model.abbreviate(agent))
                        .font(Typography.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Here") {
                        model.jumpScratchToAgent()
                    }
                    .buttonStyle(PlainTextButtonStyle())
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 6)
            } else if !model.contextShowsTerminal, let task = agentTaskTitle {
                Text(task)
                    .font(Typography.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var headerSummary: some View {
        if !model.contextShowsTerminal, let snapshot {
            if let error = snapshot.error {
                Text(repositoryStatus(error))
                    .font(Typography.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(repositoryHelp(error))
            } else if snapshot.additions + snapshot.deletions > 0 {
                HStack(spacing: 6) {
                    Text("+\(snapshot.additions)")
                        .foregroundStyle(Palette.success)
                    Text("−\(snapshot.deletions)")
                        .foregroundStyle(Palette.error)
                }
                .font(Typography.callout)
                .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var reviewActions: some View {
        if !model.contextFollowsEdits {
            Button("Follow") {
                model.contextFollowsEdits = true
                model.contextSelection = model.contextLatestPath
            }
            .buttonStyle(PlainTextButtonStyle())
        }
        headerAction("Terminal", help: "Open a shell in this panel") {
            model.contextShowsTerminal = true
        }
    }

    @ViewBuilder
    private var terminalActions: some View {
        headerAction("Changes", help: "Show the files and diff") {
            model.contextShowsTerminal = false
        }
        if model.scratchSession?.isRunning == true {
            headerAction("Move to middle", help: "Move this shell into the middle pane and the sidebar") {
                model.promoteScratch()
            }
        }
    }

    private var headerTitle: String {
        if model.contextShowsTerminal {
            return model.abbreviate(shellDirectory)
        }
        guard let session else { return "—" }
        if let snapshot {
            if snapshot.error != nil {
                return model.abbreviate(session.cwd)
            }
            if let branch = snapshot.branch, !branch.isEmpty {
                return branch
            }
            return "HEAD"
        }
        return model.abbreviate(session.cwd)
    }

    /// OSC title of the focused agent, when it is a task rather than a shell name.
    private var agentTaskTitle: String? {
        guard let id = session?.id else { return nil }
        return model.existingController(for: id)?.taskTitle
    }

    private var shellDirectory: String {
        if let scratch = model.scratchSession {
            let live = model.existingController(for: scratch.id)?.cwd
            let raw = (live?.isEmpty == false) ? live ?? scratch.cwd : scratch.cwd
            return AppModel.normalizeDirectory(raw)
        }
        if let cwd = session?.cwd {
            return AppModel.normalizeDirectory(cwd)
        }
        return AppModel.normalizeDirectory(AppModel.defaultWorkingDirectory)
    }

    /// The focused agent's directory when the panel shell is somewhere else.
    private var driftedAgentDirectory: String? {
        guard model.scratchSession?.isRunning == true, let cwd = session?.cwd else { return nil }
        let agent = AppModel.normalizeDirectory(cwd)
        guard agent != shellDirectory else { return nil }
        return agent
    }

    @ViewBuilder
    private var review: some View {
        if let session, let snapshot, snapshot.error == nil, !snapshot.changes.isEmpty {
            GeometryReader { geo in
                let selected = snapshot.changes.first { $0.path == model.contextSelection }
                VStack(spacing: 0) {
                    if selected == nil {
                        ScrollView {
                            rows(snapshot, cwd: session.cwd)
                        }
                        .scrollIndicators(.hidden)
                        .frame(maxHeight: .infinity)
                    } else if let selected {
                        BoundedScroll(maxHeight: geo.size.height * 0.4) {
                            rows(snapshot, cwd: session.cwd)
                        }
                        HorizontalDivider()
                        ContextDiffView(
                            model: model,
                            cwd: session.cwd,
                            path: selected.path,
                            status: selected.status
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        } else {
            Spacer(minLength: 0)
        }
    }

    private func rows(_ snapshot: GitSnapshot, cwd: String) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(snapshot.changes) { change in
                changeRow(change, cwd: cwd)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func changeRow(_ change: GitChange, cwd: String) -> some View {
        let selected = model.contextSelection == change.path
        return Button {
            model.contextFollowsEdits = false
            model.contextSelection = change.path
        } label: {
            HStack(spacing: 10) {
                Text(change.label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor(change.status))
                    .frame(width: 16, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(statusColor(change.status).opacity(0.12))
                    )

                Text(change.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if let diff = change.diffLabel {
                    Text(diff)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.08 : (hoveredChangeID == change.id ? 0.05 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredChangeID = hovering ? change.id : (hoveredChangeID == change.id ? nil : hoveredChangeID)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                reveal(change, cwd: cwd)
            }
            Button("Copy Path") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(AppModel.absolutePath(cwd, change.path), forType: .string)
            }
        }
    }

    private func repositoryStatus(_ error: String) -> String {
        let lowered = error.lowercased()
        if lowered.contains("not found") { return "missing" }
        return "no repository"
    }

    private func repositoryHelp(_ error: String) -> String {
        let lowered = error.lowercased()
        if lowered.contains("not found") { return "That folder is not on disk" }
        return "This folder is not a git repository"
    }

    private func headerAction(
        _ title: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(HeaderActionStyle())
            .help(help)
            .accessibilityLabel(help)
    }

    private func reveal(_ change: GitChange, cwd: String) {
        let url = URL(fileURLWithPath: AppModel.absolutePath(cwd, change.path))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "??", "A": return Palette.success
        case "D": return Palette.error
        case "R", "C": return Palette.accent
        default: return Palette.attention
        }
    }
}

/// Scrolls a short list at its content height, and caps a long one.
private struct BoundedScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                }
        }
        .scrollIndicators(.hidden)
        .frame(height: contentHeight > 1 ? min(contentHeight, maxHeight) : nil)
        .frame(maxHeight: maxHeight)
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct HeaderActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.calloutMedium)
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: WorkspaceChrome.controlRadius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08))
            )
            .contentShape(Rectangle())
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
