import AppKit
import DirectorAPI
import Observation
import SwiftTerm

/// A terminal view that reports when it becomes the keyboard focus.
///
/// SwiftTerm's `becomeFirstResponder` is public but not open, so focus is
/// reported from mouse interaction and from explicit pane focus instead.
final class DirectorTerminalView: TerminalView {
    var onFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocus?()
        super.mouseDown(with: event)
    }
}

/// Owns one SwiftTerm view for one daemon session.
///
/// The controller survives pane reassignment so scrollback is not lost when a
/// session moves between the primary and secondary panes.
@MainActor
@Observable
final class TerminalController: TerminalViewDelegate {
    let sessionID: String

    @ObservationIgnored let view: DirectorTerminalView
    @ObservationIgnored var onInput: ((Data) -> Void)?
    @ObservationIgnored var onResize: ((TerminalSize) -> Void)?
    @ObservationIgnored var onFocus: (() -> Void)?

    var title: String = ""
    var cwd: String?
    var status: SessionStatus = .running
    var reportedSize: TerminalSize?

    @ObservationIgnored private var lastSize: TerminalSize?
    @ObservationIgnored private var fontSize: CGFloat

    init(sessionID: String, fontSize: CGFloat = 12) {
        self.sessionID = sessionID
        self.fontSize = fontSize

        var options = TerminalOptions.default
        options.scrollback = 20_000
        options.termName = "xterm-256color"
        options.cursorStyle = .blinkBlock

        let view = DirectorTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            options: options
        )
        self.view = view

        view.terminalDelegate = self
        view.onFocus = { [weak self] in self?.onFocus?() }
        view.nativeBackgroundColor = Palette.terminalNS
        view.nativeForegroundColor = Palette.terminalTextNS
        view.caretColor = Palette.terminalTextNS
        view.selectedTextBackgroundColor = Palette.terminalSelectionNS
        view.wantsLayer = true
        view.layer?.backgroundColor = Palette.terminalNS.cgColor
    }

    var displayTitle: String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return sessionID }
        // Agents commonly report a task title through OSC 0/2. Shells report
        // their own name, which is less useful than the session identifier.
        let lowered = value.lowercased()
        let shellNames = ["zsh", "bash", "sh", "fish", "login", "tmux"]
        if shellNames.contains(where: { lowered == $0 || lowered.hasPrefix("\($0) ") }) {
            return sessionID
        }
        return value
    }

    var currentSize: TerminalSize? {
        let dimensions = view.terminalDimensions
        guard dimensions.cols > 0, dimensions.rows > 0 else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        return TerminalSize(
            rows: UInt16(clamping: dimensions.rows),
            cols: UInt16(clamping: dimensions.cols),
            pixelWidth: UInt16(clamping: Int(view.bounds.width * scale)),
            pixelHeight: UInt16(clamping: Int(view.bounds.height * scale))
        )
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        view.feed(byteArray: [UInt8](data)[...])
    }

    func reset() {
        view.resetToInitialState()
        view.clearScrollback()
        title = ""
        lastSize = nil
    }

    func clear() {
        view.clearScrollback()
        onInput?(Data([0x0C]))
    }

    func focus() {
        if let window = view.window {
            window.makeFirstResponder(view)
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard let self, let window = self.view.window else { return }
            window.makeFirstResponder(self.view)
        }
    }

    func setFontSize(_ size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func update(status: SessionStatus) {
        self.status = status
    }

    // MARK: - TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        let scale = source.window?.backingScaleFactor ?? 2
        let size = TerminalSize(
            rows: UInt16(clamping: newRows),
            cols: UInt16(clamping: newCols),
            pixelWidth: UInt16(clamping: Int(source.bounds.width * scale)),
            pixelHeight: UInt16(clamping: Int(source.bounds.height * scale))
        )
        guard size != lastSize else { return }
        lastSize = size
        reportedSize = size
        onResize?(size)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        cwd = directory
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" || scheme == "mailto"
            || (scheme == "file" && FileManager.default.fileExists(atPath: url.path)) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let string = String(data: content, encoding: .utf8) {
            pasteboard.setString(string, forType: .string)
        } else {
            pasteboard.setData(content, forType: .string)
        }
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.data(forType: .string)
    }

    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
        []
    }

    func kittyClipboardAvailableMimeTypes(
        source: TerminalView,
        location: KittyClipboardLocation
    ) -> [String]? {
        nil
    }

    func kittyClipboardRead(
        source: TerminalView,
        location: KittyClipboardLocation,
        mimeType: String
    ) -> KittyClipboardReadResult? {
        nil
    }

    func kittyClipboardWrite(
        source: TerminalView,
        location: KittyClipboardLocation,
        content: KittyClipboardWriteContent
    ) -> KittyClipboardWriteResult {
        .unsupported
    }

    func kittyClipboardRequestPermission(
        source: TerminalView,
        request: KittyClipboardPermissionRequest
    ) -> KittyClipboardPermissionResult {
        .deny
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
