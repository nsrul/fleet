import SwiftUI

struct ContextDiffView: View {
    @Bindable var model: AppModel
    let cwd: String
    let path: String
    let status: String

    @State private var diff = GitFileDiff.empty
    @State private var shownPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(path)
                    .font(Typography.monoSmall)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if AgentCatalog.resolveProgram("hx") != nil {
                    Button("Edit") {
                        Task { await model.editInScratch(path) }
                    }
                    .buttonStyle(PlainTextButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 36)

            diffBody
        }
        .task(id: "\(model.contextRevision)|\(cwd)|\(path)|\(status)") {
            let requested = path
            let directory = cwd
            let fileStatus = status
            if shownPath != requested {
                diff = .empty
                shownPath = requested
            }
            let loaded = await Task.detached(priority: .utility) {
                GitService.diff(cwd: directory, path: requested, status: fileStatus)
            }.value
            guard !Task.isCancelled else { return }
            diff = loaded
        }
    }

    @ViewBuilder
    private var diffBody: some View {
        if diff.binary {
            word("binary")
        } else if diff.text == "unavailable" {
            word("unavailable")
        } else if diff.text.isEmpty {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(Typography.monoSmall)
                            .foregroundStyle(lineStyle(line))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var lines: [String] {
        diff.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func word(_ text: String) -> some View {
        Text(text)
            .font(Typography.monoSmall)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
    }

    private func lineStyle(_ line: String) -> AnyShapeStyle {
        if line == "truncated" || line == "binary" || line == "unavailable" {
            return AnyShapeStyle(.secondary)
        }
        if line.hasPrefix("@@")
            || line.hasPrefix("+++")
            || line.hasPrefix("---")
            || line.hasPrefix("diff ")
            || line.hasPrefix("index ") {
            return AnyShapeStyle(.tertiary)
        }
        if line.hasPrefix("+") { return AnyShapeStyle(Palette.success) }
        if line.hasPrefix("-") { return AnyShapeStyle(Palette.error) }
        return AnyShapeStyle(.primary)
    }
}
