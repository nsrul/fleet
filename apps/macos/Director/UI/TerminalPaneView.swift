import DirectorAPI
import SwiftUI

struct TerminalPaneView: View {
    @Bindable var model: AppModel
    let slot: PaneSlot

    var body: some View {
        Group {
            if let session = model.session(for: slot) {
                pane(session)
            } else {
                EmptyPaneView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pane(_ session: SessionInfo) -> some View {
        let controller = model.controller(for: session.id)

        return VStack(spacing: 0) {
            header(session)
            TerminalHostView(controller: controller)
                .id(session.id)
                .padding(.horizontal, 26)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            statusBar(session, controller: controller)
        }
        .background(Palette.terminal)
        .overlay(alignment: .top) {
            if model.isSplit, model.focusedPane == slot {
                Rectangle()
                    .fill(Palette.accent)
                    .frame(height: 2)
            }
        }
        .onAppear {
            if model.focusedPane == slot {
                controller.focus()
            }
        }
        .onChange(of: model.focusedPane) { _, newValue in
            if newValue == slot {
                controller.focus()
            }
        }
    }

    private func header(_ session: SessionInfo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.paneTitle(for: session))
                    .font(Typography.headline)
                    .foregroundStyle(Palette.terminalTitle)
                    .lineLimit(1)
                Text(model.subtitle(for: session))
                    .font(Typography.captionRegular)
                    .foregroundStyle(Palette.terminalSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Menu {
                Button(model.splitLayout == .stacked ? "✓ Stacked" : "Stacked") {
                    model.setSplitLayout(.stacked)
                    model.setSplit(true)
                }
                Button(model.splitLayout == .sideBySide ? "✓ Side by Side" : "Side by Side") {
                    model.setSplitLayout(.sideBySide)
                    model.setSplit(true)
                }
                Divider()
                Button("Swap Panes") {
                    model.swapPanes()
                }
                .disabled(model.primarySessionID == nil || model.secondarySessionID == nil)
                Button("Unsplit") {
                    model.setSplit(false)
                }
                .disabled(!model.isSplit)
            } label: {
                Text("Split")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change the pane layout")

            Button("Fork") {
                model.forkSession(session.id)
            }
            .buttonStyle(TerminalHeaderButtonStyle())
            .help("Start a new process-level session with the same program and directory")
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.terminalDivider)
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.focusedPane = slot
        }
    }

    private func statusBar(_ session: SessionInfo, controller: TerminalController) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor(session.status))
                .frame(width: 5, height: 5)
            Text(model.statusLabel(for: session))
            if let size = controller.reportedSize {
                Text("\(size.cols)×\(size.rows)")
            }
            Spacer(minLength: 8)
            Text("⌘K clear · ⌘\\ split")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Palette.terminalSecondary.opacity(0.75))
        .padding(.horizontal, 14)
        .frame(height: 22)
        .background(Palette.terminalStatusBar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.terminalDivider)
                .frame(height: 1)
        }
    }

    private func statusColor(_ status: SessionStatus) -> Color {
        switch status {
        case .running: return Palette.accent
        case .exited(let exit): return exit.success ? Palette.success : Palette.error
        }
    }
}

private struct EmptyPaneView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Palette.terminalSecondary)
            Text("Second pane")
                .font(Typography.headline)
                .foregroundStyle(Palette.terminalTitle)
            Text("Open another agent to work beside the first.")
                .font(Typography.captionRegular)
                .foregroundStyle(Palette.terminalSecondary)
            Button("New agent") {
                model.showNewAgent = true
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.terminal)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(0.12),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
                .padding(20)
        }
    }
}
