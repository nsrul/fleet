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
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var panes: some View {
        if model.isSplit {
            if model.splitLayout == .stacked {
                VSplitView {
                    TerminalPaneView(model: model, slot: .primary)
                        .frame(minHeight: 140)
                    TerminalPaneView(model: model, slot: .secondary)
                        .frame(minHeight: 140)
                }
            } else {
                HSplitView {
                    TerminalPaneView(model: model, slot: .primary)
                        .frame(minWidth: 260)
                    TerminalPaneView(model: model, slot: .secondary)
                        .frame(minWidth: 260)
                }
            }
        } else {
            TerminalPaneView(model: model, slot: .primary)
        }
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
