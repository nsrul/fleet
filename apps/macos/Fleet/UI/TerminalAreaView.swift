import AppKit
import SwiftUI

struct TerminalAreaView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            Palette.terminal.ignoresSafeArea()

            if !model.connection.isConnected {
                ConnectionView(model: model)
            } else if model.sessions.isEmpty {
                NoSessionsView(model: model)
            } else {
                panes
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if showsChromeToggles {
                sidebarToggle
                    .padding(.leading, model.showSidebar ? 14 : 78)
                    .padding(.top, WorkspaceChrome.controlTopInset)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsChromeToggles {
                contextToggle
                    .padding(.trailing, WorkspaceChrome.trailingInset)
                    .padding(.top, WorkspaceChrome.controlTopInset)
            }
        }
    }

    /// Session panes draw their own toggles. The connection and empty states do not.
    private var showsChromeToggles: Bool {
        !model.connection.isConnected || model.sessions.isEmpty
    }

    private var sidebarToggle: some View {
        PanelToggleButton(
            systemImage: "sidebar.left",
            help: model.showSidebar ? "Hide sidebar" : "Show sidebar",
            isOn: model.showSidebar,
            action: model.toggleSidebar
        )
    }

    private var contextToggle: some View {
        PanelToggleButton(
            systemImage: "sidebar.right",
            help: model.showContext ? "Hide context panel" : "Show context panel",
            isOn: model.showContext,
            action: model.toggleContext
        )
    }

    private var panes: some View {
        WorkspaceSplit(model: model)
    }
}

private struct NoSessionsView: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)

            VStack(spacing: 5) {
                Text("No agents running")
                    .font(Typography.title)
                    .foregroundStyle(Palette.terminalTitle)
                Text("Start an agent to open a live terminal pane.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.terminalSecondary)
            }

            HStack(spacing: 10) {
                Button("New agent") {
                    model.showNewAgent = true
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("Settings") {
                    openSettings()
                }
                .buttonStyle(TerminalSecondaryButtonStyle())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.terminal)
    }
}
