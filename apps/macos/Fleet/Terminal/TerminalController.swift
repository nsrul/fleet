import AppKit
import FleetAPI
import Observation
import SwiftTerm

/// A terminal view that reports when it becomes the keyboard focus.
///
/// SwiftTerm's `becomeFirstResponder` is public but not open, so focus is
/// reported from mouse interaction, file drops, and explicit pane focus instead.
final class FleetTerminalView: TerminalView {
    var onFocus: (() -> Void)?

    /// True while a valid drag hovers, so the pane shows a drop target.
    private var isDropTarget = false {
        didSet { layer?.borderWidth = isDropTarget ? 2 : 0 }
    }

    override init(frame frameRect: NSRect, font: NSFont?, options: TerminalOptions) {
        super.init(frame: frameRect, font: font, options: options)
        registerForDraggedTypes([.fileURL, .string])
        layer?.borderColor = Palette.accentNS.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .string])
        layer?.borderColor = Palette.accentNS.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Tab zones live behind this view. Step aside so a tab drop can land.
        if TabDragSession.active { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocus?()
        super.mouseDown(with: event)
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        TerminalDrop.text(from: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let text = TerminalDrop.text(from: sender.draggingPasteboard) else {
            return false
        }
        // Insert at this pane's prompt, not the one that had focus before.
        window?.makeFirstResponder(self)
        onFocus?()
        pasteText(text)
        return true
    }

    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard TerminalDrop.text(from: sender.draggingPasteboard) != nil else {
            isDropTarget = false
            return []
        }
        isDropTarget = true
        return .copy
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

    @ObservationIgnored let view: FleetTerminalView
    @ObservationIgnored var onInput: ((Data) -> Void)?
    @ObservationIgnored var onResize: ((TerminalSize) -> Void)?
    @ObservationIgnored var onFocus: (() -> Void)?

    var title: String = ""
    var cwd: String?
    var status: SessionStatus = .running
    var reportedSize: TerminalSize?
    /// True while output arrived in the last few seconds.
    var recentlyActive = false
    /// True after a bell, until the user types or focuses the pane.
    var needsAttention = false

    @ObservationIgnored var onPresence: (() -> Void)?
    @ObservationIgnored private var lastSize: TerminalSize?
    @ObservationIgnored private var preferences: TerminalPreferences
    @ObservationIgnored private var activityToken = 0

    init(sessionID: String, preferences: TerminalPreferences) {
        self.sessionID = sessionID
        let preferences = preferences.clamped()
        self.preferences = preferences

        var options = TerminalOptions.default
        options.scrollback = preferences.scrollback
        options.termName = "xterm-256color"
        options.cursorStyle = Self.cursorStyle(for: preferences.cursorTag)

        let view = FleetTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            font: TerminalFont.resolve(id: preferences.fontID, size: CGFloat(preferences.fontSize)),
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
        // `.sound` is what calls the delegate, which is how a session gets marked.
        // The beep itself follows `preferences.bellSound`.
        view.bellStyle = .sound
        view.optionAsMetaKey = preferences.optionIsMeta
        if abs(preferences.lineSpacing - 1) > 0.001 {
            view.lineSpacing = CGFloat(preferences.lineSpacing)
        }
    }

    private static let shellNames = ["zsh", "bash", "sh", "fish", "login", "tmux"]

    /// OSC title when it names the task. Shell names are not a task.
    private var usefulTitle: String? {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let lowered = value.lowercased()
        if Self.shellNames.contains(where: { lowered == $0 || lowered.hasPrefix("\($0) ") }) {
            return nil
        }
        return value
    }

    var displayTitle: String {
        // Agents commonly report a task title through OSC 0/2. Shells report
        // their own name, which is less useful than the session identifier.
        usefulTitle ?? sessionID
    }

    /// Task title for the context panel. Nil when the terminal has no real title.
    var taskTitle: String? { usefulTitle }

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
        markRecentlyActive()
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
        noteUserEngaged()
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

    func apply(_ incoming: TerminalPreferences) {
        let next = incoming.clamped()
        let previous = preferences
        preferences = next

        if previous.fontID != next.fontID || previous.fontSize != next.fontSize {
            view.font = TerminalFont.resolve(id: next.fontID, size: CGFloat(next.fontSize))
        }
        if previous.cursorTag != next.cursorTag {
            view.setCursorStyle(Self.cursorStyle(for: next.cursorTag))
        }
        if abs(previous.lineSpacing - next.lineSpacing) > 0.001 {
            view.lineSpacing = CGFloat(next.lineSpacing)
        }
        if previous.scrollback != next.scrollback {
            view.changeScrollback(next.scrollback)
        }
        if previous.optionIsMeta != next.optionIsMeta {
            view.optionAsMetaKey = next.optionIsMeta
        }
    }

    private static func cursorStyle(for tag: String) -> CursorStyle {
        CursorStyle(tagName: tag) ?? .blinkBlock
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
        noteUserEngaged()
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
        if !needsAttention {
            needsAttention = true
            onPresence?()
        }
        if preferences.bellSound {
            NSSound.beep()
        }
    }

    private func markRecentlyActive() {
        activityToken += 1
        let token = activityToken
        if !recentlyActive {
            recentlyActive = true
            onPresence?()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.activityToken == token else { return }
            guard self.recentlyActive else { return }
            self.recentlyActive = false
            self.onPresence?()
        }
    }

    private func noteUserEngaged() {
        guard needsAttention else { return }
        needsAttention = false
        onPresence?()
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
