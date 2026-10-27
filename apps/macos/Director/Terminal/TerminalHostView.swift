import SwiftUI

/// Bridges the persistent SwiftTerm view owned by a `TerminalController` into SwiftUI.
struct TerminalHostView: NSViewRepresentable {
    let controller: TerminalController

    func makeNSView(context: Context) -> DirectorTerminalView {
        controller.view
    }

    func updateNSView(_ nsView: DirectorTerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: DirectorTerminalView, coordinator: ()) {
        // The controller owns the terminal view so its scrollback survives a
        // move between panes. Do not tear it down with the representable.
    }
}
