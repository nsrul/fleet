import FleetAPI
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
            if showsSidebarToggle, model.session(for: slot) == nil {
                sidebarToggleButton
                    .padding(.leading, sidebarToggleLeading)
                    .padding(.top, WorkspaceChrome.controlTopInset)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsContextToggle, model.session(for: slot) == nil {
                contextToggleButton
                    .padding(.trailing, WorkspaceChrome.trailingInset)
                    .padding(.top, WorkspaceChrome.controlTopInset)
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    private var sidebarToggleLeading: CGFloat {
        model.showSidebar ? 14 : 78
    }

    private var headerLeading: CGFloat {
        showsSidebarToggle ? sidebarToggleLeading : 24
    }

    private var headerTrailing: CGFloat {
        showsContextToggle ? WorkspaceChrome.trailingInset : 24
    }

    private var sidebarToggleButton: some View {
        PanelToggleButton(
            systemImage: "sidebar.left",
            help: model.showSidebar ? "Hide sidebar" : "Show sidebar",
            isOn: model.showSidebar,
            action: model.toggleSidebar
        )
    }

    private var contextToggleButton: some View {
        PanelToggleButton(
            systemImage: "sidebar.right",
            help: model.showContext ? "Hide context panel" : "Show context panel",
            isOn: model.showContext,
            action: model.toggleContext
        )
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
            if showsSidebarToggle {
                sidebarToggleButton
            }

            Text(model.paneTitle(for: session))
                .font(Typography.headline)
                .foregroundStyle(Palette.terminalTitle)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 8)

            Button("Fork") {
                model.forkSession(session.id)
            }
            .buttonStyle(TerminalHeaderButtonStyle())
            .help("Start a new process-level session with the same program and directory")

            if showsContextToggle {
                contextToggleButton
            }
        }
        .padding(.leading, headerLeading)
        .padding(.trailing, headerTrailing)
        .frame(height: WorkspaceChrome.barHeight)
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
