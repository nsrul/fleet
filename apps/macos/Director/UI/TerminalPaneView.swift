import DirectorAPI
import SwiftUI

struct TerminalPaneView: View {
    @Bindable var model: AppModel
    let slot: PaneSlot
    var showsSidebarToggle = false
    var showsContextToggle = false

    var body: some View {
        Group {
            if let session = model.session(for: slot) {
                pane(session)
            } else {
                EmptyPaneView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if showsSidebarToggle {
                PanelToggleButton(
                    systemImage: "sidebar.left",
                    help: model.showSidebar ? "Hide sidebar" : "Show sidebar",
                    isOn: model.showSidebar,
                    action: model.toggleSidebar
                )
                .padding(.leading, model.showSidebar ? 14 : 78)
                .padding(.top, 18)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsContextToggle {
                PanelToggleButton(
                    systemImage: "sidebar.right",
                    help: model.showContext ? "Hide context panel" : "Show context panel",
                    isOn: model.showContext,
                    action: model.toggleContext
                )
                .padding(.trailing, 16)
                .padding(.top, 18)
            }
        }
        .ignoresSafeArea(edges: .top)
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
        }
        .background(Palette.terminal)
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

            Button("Fork") {
                model.forkSession(session.id)
            }
            .buttonStyle(TerminalHeaderButtonStyle())
            .help("Start a new process-level session with the same program and directory")
        }
        .padding(.leading, showsSidebarToggle ? (model.showSidebar ? 48 : 112) : 24)
        .padding(.trailing, showsContextToggle ? 52 : 24)
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
