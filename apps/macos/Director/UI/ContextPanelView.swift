import AppKit
import DirectorAPI
import SwiftUI

struct ContextPanelView: View {
    @Bindable var model: AppModel
    @State private var hoveredChangeID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.contextBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
        }
    }

    private var session: SessionInfo? { model.contextSession }
    private var snapshot: GitSnapshot? { model.contextSnapshot }
    private var hasChanges: Bool { !(snapshot?.changes.isEmpty ?? true) }

    @ViewBuilder
    private var header: some View {
        if hasChanges {
            tabs
            HorizontalDivider(color: Color.primary.opacity(0.07))
            summaryBlock
            HorizontalDivider(color: Color.primary.opacity(0.07))
        } else {
            simpleHeader
            HorizontalDivider(color: Color.primary.opacity(0.07))
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            tab(title: "Changes", count: snapshot?.changes.count ?? 0, selected: true)
            tab(title: "Artifacts", count: 0, selected: false)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private func tab(title: String, count: Int, selected: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(Typography.calloutMedium)
            Text("\(count)")
                .font(Typography.callout)
                .foregroundStyle(selected ? Color.secondary : Color.secondary.opacity(0.55))
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
    }

    private var simpleHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(branchTitle)
                .font(Typography.monoBranch)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(cleanSummary)
                .font(Typography.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(branchTitle)
                    .font(Typography.monoBranch)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(snapshot?.diffSummary ?? "")
                    .font(Typography.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text("Uncommitted · based on \(snapshot?.baseBranch ?? "main")")
                .font(Typography.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let session, let snapshot {
            if let error = snapshot.error {
                emptyState(
                    title: "Not a git repository",
                    subtitle: error,
                    symbol: "questionmark.folder"
                )
                .overlay(alignment: .bottom) {
                    Text(model.abbreviate(session.cwd))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 24)
                }
            } else if snapshot.changes.isEmpty {
                emptyState(
                    title: "No changes yet",
                    subtitle: "Files \(AgentCatalog.displayName(for: session.program)) edits will appear here.",
                    symbol: "checkmark.circle"
                )
            } else {
                changes(snapshot, session: session)
            }
        } else if session != nil {
            emptyState(
                title: "Reading repository…",
                subtitle: "Collecting branch and working tree state.",
                symbol: "arrow.triangle.2.circlepath"
            )
        } else {
            emptyState(
                title: "No agent selected",
                subtitle: "Choose an agent from the sidebar.",
                symbol: "sidebar.left"
            )
        }
    }

    private func emptyState(title: String, subtitle: String, symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(Typography.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func changes(_ snapshot: GitSnapshot, session: SessionInfo) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(snapshot.changes) { change in
                    changeRow(change, cwd: session.cwd)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func changeRow(_ change: GitChange, cwd: String) -> some View {
        Button {
            open(change, cwd: cwd)
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
                    .fill(Color.primary.opacity(hoveredChangeID == change.id ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredChangeID = hovering ? change.id : nil
        }
        .contextMenu {
            Button("Reveal in Finder") {
                reveal(change, cwd: cwd)
            }
            Button("Copy Path") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(change.path, forType: .string)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            HorizontalDivider(color: Color.primary.opacity(0.07))
            HStack(spacing: 12) {
                Button("Link issue") {
                    if let url = issueURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(PlainTextButtonStyle())
                .disabled(issueURL == nil)

                Spacer()

                Button {
                    model.refreshGitNow()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Refresh")
                    }
                    .font(Typography.captionRegular)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
    }

    private var branchTitle: String {
        guard let snapshot, let branch = snapshot.branch else { return "—" }
        if !snapshot.changes.isEmpty, let base = snapshot.baseBranch, base != branch {
            return "\(branch) → \(base)"
        }
        return branch
    }

    private var cleanSummary: String {
        guard let snapshot, snapshot.error == nil else {
            return "not a repository"
        }
        if let base = snapshot.baseBranch, base != snapshot.branch {
            return "from \(base) · clean"
        }
        return "clean"
    }

    private var issueURL: URL? {
        guard let remote = snapshot?.remoteURL else { return nil }
        return remote.appendingPathComponent("issues/new")
    }

    private func open(_ change: GitChange, cwd: String) {
        let url = URL(fileURLWithPath: cwd).appendingPathComponent(change.path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            reveal(change, cwd: cwd)
        }
    }

    private func reveal(_ change: GitChange, cwd: String) {
        let url = URL(fileURLWithPath: cwd).appendingPathComponent(change.path)
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
