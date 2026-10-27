import AppKit
import SwiftUI

@main
struct DirectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Director", id: "main") {
            RootView(model: model)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            DirectorCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let raw = UserDefaults.standard.string(forKey: "appearance")
            ?? AppAppearance.light.rawValue
        NSApplication.shared.appearance = (AppAppearance(rawValue: raw) ?? .light).nsAppearance
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct DirectorCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Agent…") {
                model.showNewAgent = true
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Session") {
            Button("Focus First Pane") {
                model.focusPane(.primary)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Focus Second Pane") {
                model.focusPane(.secondary)
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(!model.isSplit)

            Divider()

            Button(model.isSplit ? "Unsplit" : "Split") {
                model.toggleSplit()
            }
            .keyboardShortcut("\\", modifiers: .command)

            Button("Stacked Layout") {
                model.setSplitLayout(.stacked)
                model.setSplit(true)
            }

            Button("Side-by-Side Layout") {
                model.setSplitLayout(.sideBySide)
                model.setSplit(true)
            }

            Divider()

            Button("Clear Terminal") {
                model.clearFocusedTerminal()
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("Stop Session…") {
                model.requestStopFocused()
            }
            .disabled(model.focusedSession == nil)
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button(model.showContext ? "Hide Context Panel" : "Show Context Panel") {
                model.toggleContext()
            }
            .keyboardShortcut("0", modifiers: .command)

            Button("Refresh Git Status") {
                model.refreshGitNow()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandGroup(after: .appInfo) {
            Button("Reconnect to Daemon") {
                Task { await model.reconnect() }
            }
        }
    }
}
