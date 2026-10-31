import SwiftUI

struct ContextTerminalView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let session = model.scratchSession, session.isRunning {
                TerminalHostView(controller: model.controller(for: session.id))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.terminal)
            } else {
                VStack(spacing: 10) {
                    Text(model.abbreviate(directory))
                        .font(Typography.monoSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("New shell") {
                        Task { await model.newScratchShell() }
                    }
                    .buttonStyle(PlainTextButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
            }
        }
        .task(id: model.contextShowsTerminal) {
            guard model.contextShowsTerminal else { return }
            await model.openScratchTerminal()
        }
    }

    private var directory: String {
        if let cwd = model.scratchSession?.cwd, !cwd.isEmpty { return cwd }
        if let cwd = model.focusedSession?.cwd, !cwd.isEmpty { return cwd }
        return AppModel.defaultWorkingDirectory
    }
}
