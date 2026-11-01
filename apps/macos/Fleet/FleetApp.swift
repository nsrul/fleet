import AppKit
import SwiftUI

@main
struct FleetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    private static let previewLaunch = ProcessInfo.processInfo.environment["FLEET_PREVIEW"] == "1"

    var body: some Scene {
        // A separate window id so a screenshot launch does not restore, or
        // overwrite, the frame saved for a normal Fleet window.
        Window("Fleet", id: Self.previewLaunch ? "preview" : "main") {
            RootView(model: model)
        }
        .defaultSize(
            width: Self.previewLaunch ? 1520 : 1440,
            height: Self.previewLaunch ? 980 : 900
        )
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            FleetCommands(model: model)
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

struct FleetCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Agent…") {
                model.showNewAgent = true
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Session") {
            Button("Focus Terminal") {
                model.focusPane(.primary)
            }
            .keyboardShortcut("1", modifiers: .command)

            Divider()

            Button("Clear Terminal") {
                model.clearFocusedTerminal()
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("Stop Session…") {
                model.requestStopFocused()
            }
            .disabled(model.focusedSession == nil)

            Button("Delete Session…") {
                model.requestDeleteFocused()
            }
            .disabled(model.focusedSession == nil)
            .keyboardShortcut(.delete, modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button(model.showSidebar ? "Hide Sidebar" : "Show Sidebar") {
                model.toggleSidebar()
            }
            .keyboardShortcut("b", modifiers: .command)

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
