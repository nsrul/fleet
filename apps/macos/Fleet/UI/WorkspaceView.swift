import AppKit
import FleetAPI
import SwiftUI

struct WorkspaceSplit: View {
    @Bindable var model: AppModel
    @State private var dragOrigin: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let panes = model.workspace.panes
            ZStack {
                if panes.isEmpty {
                    emptyWorkspace
                } else if panes.count == 1 || model.workspace.split == nil {
                    pane(panes[0], index: 0)
                } else {
                    split(panes, in: geo.size)
                }
            }
        }
    }

    private var emptyWorkspace: some View {
        ZStack {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Palette.terminalSecondary)
                Text("Nothing open")
                    .font(Typography.headline)
                    .foregroundStyle(Palette.terminalTitle)
                Text("Choose an agent in the sidebar, or start a new one.")
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
        }
        .overlay(alignment: .topLeading) {
            PanelToggleButton(
                systemImage: "sidebar.left",
                help: model.showSidebar ? "Hide sidebar" : "Show sidebar",
                isOn: model.showSidebar,
                action: model.toggleSidebar
            )
            .padding(.leading, model.showSidebar ? 14 : 78)
            .padding(.top, WorkspaceChrome.controlTopInset)
        }
        .overlay(alignment: .topTrailing) {
            PanelToggleButton(
                systemImage: "sidebar.right",
                help: model.showContext ? "Hide context panel" : "Show context panel",
                isOn: model.showContext,
                action: model.toggleContext
            )
            .padding(.trailing, WorkspaceChrome.trailingInset)
            .padding(.top, WorkspaceChrome.controlTopInset)
        }
    }

    private func split(_ panes: [WorkspacePane], in size: CGSize) -> some View {
        let horizontal = model.workspace.split != .vertical
        let total = horizontal ? size.width : size.height
        let minimum: CGFloat = horizontal ? 280 : 160
        let fraction = clampedFraction(total: total, minimum: minimum)
        let leading = max(0, total * fraction - 4)

        return Group {
            if horizontal {
                HStack(spacing: 0) {
                    pane(panes[0], index: 0)
                        .frame(width: leading)
                    divider(horizontal: true, total: total, minimum: minimum)
                    pane(panes[1], index: 1)
                }
            } else {
                VStack(spacing: 0) {
                    pane(panes[0], index: 0)
                        .frame(height: leading)
                    divider(horizontal: false, total: total, minimum: minimum)
                    pane(panes[1], index: 1)
                }
            }
        }
    }

    private func pane(_ pane: WorkspacePane, index: Int) -> some View {
        let vertical = model.workspace.split == .vertical
        let showsSidebar = index == 0
        let showsContext = vertical
            ? index == 0
            : index == model.workspace.panes.count - 1
        return TerminalPaneView(
            model: model,
            pane: pane,
            showsSidebarToggle: showsSidebar,
            showsContextToggle: showsContext
        )
    }

    private func divider(horizontal: Bool, total: CGFloat, minimum: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            .frame(width: horizontal ? 8 : nil, height: horizontal ? nil : 8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragOrigin == nil { dragOrigin = model.splitFraction }
                        let delta = horizontal ? value.translation.width : value.translation.height
                        let proposed = (dragOrigin ?? model.splitFraction) + delta / max(total, 1)
                        model.splitFraction = clampedFraction(
                            total: total,
                            minimum: minimum,
                            proposed: proposed
                        )
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                    }
            )
            .onHover { inside in
                if inside {
                    (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityLabel("Resize panes")
    }

    private func clampedFraction(
        total: CGFloat,
        minimum: CGFloat,
        proposed: CGFloat? = nil
    ) -> CGFloat {
        let value = proposed ?? model.splitFraction
        guard total > minimum * 2 else { return 0.5 }
        let limit = minimum / total
        return min(1 - limit, max(limit, value))
    }

}

/// One translucent half of the pane, following the pointer while a tab is dragged.
struct PaneDropOverlay: View {
    @Bindable var model: AppModel
    let paneID: String
    @State private var hover = DropHover()
    @State private var edge: DropEdge?
    @State private var shownEdge: DropEdge?

    var body: some View {
        GeometryReader { geo in
            let rect = (shownEdge ?? edge)?.preview(in: geo.size)
            ZStack {
                Color.black.opacity(0.34)
                    .allowsHitTesting(false)
                if let rect, let shownEdge {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(edge == nil ? 0 : 0.16), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(edge == nil ? 0 : 1)
                        .allowsHitTesting(false)
                        .animation(.smooth(duration: 0.28), value: shownEdge)
                        .animation(.smooth(duration: 0.16), value: edge == nil)
                }
            }
            .overlay {
                TabDropTarget(
                    onTargeted: { hovering in
                        guard !hovering else { return }
                        hover.edge = nil
                        edge = nil
                    },
                    onEdge: { next in
                        let usable = splitsOnEdge ? next : nil
                        hover.edge = usable
                        if let usable { shownEdge = usable }
                        edge = usable
                    },
                    tracksEdge: true
                ) { drag in
                    let resolved = drag ?? model.draggingTab
                    guard let resolved else { return false }
                    if let target = hover.edge {
                        model.dropTab(resolved, axis: target.axis, placeFirst: target.placeFirst)
                        return true
                    }
                    guard resolved.paneID != paneID,
                          let pane = model.workspace.panes.first(where: { $0.id == paneID })
                    else { return false }
                    model.dropTab(resolved, onPane: paneID, index: pane.tabs.count)
                    return true
                }
            }
        }
        .allowsHitTesting(true)
    }

    /// One pane needs two tabs before an edge can open another pane. Two panes already
    /// accept an edge: the tab moves to that side.
    private var splitsOnEdge: Bool {
        let panes = model.workspace.panes
        if panes.count >= 2 { return true }
        return (panes.first?.tabs.count ?? 0) >= 2
    }
}

/// Latest edge reported by the drop view. A class so the drop reads the pointer, not a stale render.
private final class DropHover {
    var edge: DropEdge?
}

/// The side of a pane the pointer is aiming at.
enum DropEdge: Equatable {
    case left, right, top, bottom

    var axis: SplitAxis {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        }
    }

    var placeFirst: Bool { self == .left || self == .top }

    /// Nil in the middle, where a drop rearranges into the pane instead of splitting.
    static func resolve(_ point: CGPoint, in size: CGSize) -> DropEdge? {
        guard size.width > 1, size.height > 1 else { return nil }
        let x = min(1, max(0, point.x / size.width))
        let y = min(1, max(0, point.y / size.height))
        let dx = min(x, 1 - x)
        let dy = min(y, 1 - y)
        let band: CGFloat = 0.46
        guard dx < band || dy < band else { return nil }
        if dx <= dy { return x < 0.5 ? .left : .right }
        return y < 0.5 ? .top : .bottom
    }

    func preview(in size: CGSize) -> CGRect {
        let inset: CGFloat = 12
        switch self {
        case .left:
            let width = max(0, size.width * 0.5 - inset * 1.5)
            return CGRect(x: inset, y: inset, width: width, height: max(0, size.height - inset * 2))
        case .right:
            let width = max(0, size.width * 0.5 - inset * 1.5)
            return CGRect(x: size.width - inset - width, y: inset, width: width, height: max(0, size.height - inset * 2))
        case .top:
            let height = max(0, size.height * 0.5 - inset * 1.5)
            return CGRect(x: inset, y: inset, width: max(0, size.width - inset * 2), height: height)
        case .bottom:
            let height = max(0, size.height * 0.5 - inset * 1.5)
            return CGRect(x: inset, y: size.height - inset - height, width: max(0, size.width - inset * 2), height: height)
        }
    }
}

struct SplitPickerSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Split pane")
                .font(Typography.title)
                .foregroundStyle(.primary)
            Text(hint)
                .font(Typography.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if candidates.isEmpty {
                Text("Start another agent before splitting this pane.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Button("New agent") {
                    model.showSplitPicker = false
                    model.showNewAgent = true
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(candidates, id: \.id) { session in
                            Button {
                                model.split(with: session.id)
                            } label: {
                                HStack(spacing: 8) {
                                    AgentMark(program: session.program)
                                        .frame(width: 16, height: 16)
                                    Text(model.displayTitle(for: session))
                                        .font(Typography.bodyMedium)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    StatusDot(status: session.status)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 32)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    model.showSplitPicker = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(TerminalSecondaryButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 380, height: 440)
    }

    private var hint: String {
        model.preferredSplitAxis == .horizontal
            ? "Choose the session to open beside the focused pane."
            : "Choose the session to open below the focused pane."
    }

    private var candidates: [SessionInfo] {
        let alone = model.workspace.panes.count == 1
            && model.workspace.panes.first?.tabs.count == 1
        let blocked = alone ? model.workspace.panes.first?.tabs.first?.sessionID : nil
        return model.sessions.filter { $0.id != blocked }
    }
}

struct TabDropTarget: NSViewRepresentable {
    var onTargeted: (Bool) -> Void = { _ in }
    var onEdge: (DropEdge?) -> Void = { _ in }
    var tracksEdge = false
    var onDrop: (TabDrag?) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TabDropNSView {
        let view = TabDropNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: TabDropNSView, context: Context) {
        context.coordinator.onTargeted = onTargeted
        context.coordinator.onEdge = onEdge
        context.coordinator.onDrop = onDrop
        context.coordinator.tracksEdge = tracksEdge
        view.coordinator = context.coordinator
    }

    final class Coordinator {
        var onTargeted: (Bool) -> Void = { _ in }
        var onEdge: (DropEdge?) -> Void = { _ in }
        var onDrop: (TabDrag?) -> Bool = { _ in false }
        var tracksEdge = false
        var edge: DropEdge?
    }
}

final class TabDropNSView: NSView {
    weak var coordinator: TabDropTarget.Coordinator?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([NSPasteboard.PasteboardType(TabDrag.pasteboardType)])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard TabDragSession.active else { return nil }
        return super.hitTest(point)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        publish(sender, hovering: true)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        publish(sender, hovering: true)
        return .move
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated {
            coordinator?.edge = nil
            coordinator?.onEdge(nil)
            coordinator?.onTargeted(false)
        }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        MainActor.assumeIsolated {
            coordinator?.edge = nil
            coordinator?.onEdge(nil)
            coordinator?.onTargeted(false)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let drag = TabDrag.read(sender.draggingPasteboard)
        let edge = edge(for: sender)
        return MainActor.assumeIsolated {
            coordinator?.edge = edge
            coordinator?.onEdge(edge)
            return coordinator?.onDrop(drag) ?? false
        }
    }

    private func publish(_ sender: NSDraggingInfo, hovering: Bool) {
        let edge = edge(for: sender)
        MainActor.assumeIsolated {
            coordinator?.onTargeted(hovering)
            guard coordinator?.edge != edge else { return }
            coordinator?.edge = edge
            coordinator?.onEdge(edge)
        }
    }

    /// Top-left point in this view, matching the SwiftUI preview.
    private func edge(for sender: NSDraggingInfo) -> DropEdge? {
        guard coordinator?.tracksEdge == true, bounds.width > 1, bounds.height > 1 else { return nil }
        let local = convert(sender.draggingLocation, from: nil)
        let point = isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
        return DropEdge.resolve(point, in: bounds.size)
    }
}

/// Drags a tab without letting the hidden title bar move the window.
struct TabGrabber: NSViewRepresentable {
    var drag: TabDrag
    var title: String
    var program: String?
    var onClick: () -> Void
    var onDoubleClick: () -> Void
    var onHover: (Bool) -> Void
    var onReceive: (TabDrag?) -> Bool
    var onDragStart: (TabDrag) -> Void
    var onDragEnd: (TabDrag) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TabGrabNSView {
        let view = TabGrabNSView()
        view.coordinator = context.coordinator
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: TabGrabNSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.drag = drag
        coordinator.title = title
        coordinator.program = program
        coordinator.onClick = onClick
        coordinator.onDoubleClick = onDoubleClick
        coordinator.onHover = onHover
        coordinator.onReceive = onReceive
        coordinator.onDragStart = onDragStart
        coordinator.onDragEnd = onDragEnd
        view.coordinator = coordinator
        view.toolTip = title
    }

    final class Coordinator {
        var drag = TabDrag(tabID: "", paneID: "", sessionID: "")
        var title = ""
        var program: String?
        var onClick: () -> Void = {}
        var onDoubleClick: () -> Void = {}
        var onHover: (Bool) -> Void = { _ in }
        var onReceive: (TabDrag?) -> Bool = { _ in false }
        var onDragStart: (TabDrag) -> Void = { _ in }
        var onDragEnd: (TabDrag) -> Void = { _ in }
    }
}

final class TabGrabNSView: NSView, NSDraggingSource {
    weak var coordinator: TabGrabber.Coordinator?
    private var origin: NSPoint?
    private var moved = false
    private var hoverArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([NSPasteboard.PasteboardType(TabDrag.pasteboardType)])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        guard let event = NSApp.currentEvent else { return self }
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return nil
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return nil
        default:
            return self
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        hoverArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        MainActor.assumeIsolated { coordinator?.onHover(true) }
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { coordinator?.onHover(false) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            origin = nil
            moved = false
            MainActor.assumeIsolated { coordinator?.onDoubleClick() }
            return
        }
        origin = event.locationInWindow
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin, !moved else { return }
        let dx = event.locationInWindow.x - origin.x
        let dy = event.locationInWindow.y - origin.y
        guard dx * dx + dy * dy >= 16 else { return }
        moved = true
        startDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldClick = origin != nil && !moved
        origin = nil
        moved = false
        guard shouldClick else { return }
        MainActor.assumeIsolated { coordinator?.onClick() }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .move }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .move }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let drag = TabDrag.read(sender.draggingPasteboard)
        return MainActor.assumeIsolated {
            coordinator?.onReceive(drag) ?? false
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        guard let data = coordinator?.drag.data else { return }
        session.draggingPasteboard.setData(
            data,
            forType: NSPasteboard.PasteboardType(TabDrag.pasteboardType)
        )
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard let drag = coordinator?.drag else { return }
        MainActor.assumeIsolated {
            coordinator?.onDragEnd(drag)
        }
    }

    func ignoreModifierKeys(for session: NSDraggingSession, mouseDown event: NSEvent) -> Bool {
        true
    }

    private func startDrag(with event: NSEvent) {
        guard let coordinator else { return }
        let drag = coordinator.drag
        let title = coordinator.title
        let program = coordinator.program
        let image = MainActor.assumeIsolated { () -> NSImage in
            coordinator.onDragStart(drag)
            return TabDragPillImage.make(program: program, title: title)
        }
        let writer = NSPasteboardItem()
        writer.setData(drag.data, forType: NSPasteboard.PasteboardType(TabDrag.pasteboardType))
        let item = NSDraggingItem(pasteboardWriter: writer)
        let location = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(
                x: location.x - TabDragPillImage.cursorLead,
                y: location.y - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            ),
            contents: image
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }
}

private enum TabDragPillImage {
    /// Padding around the chip so its shadow is part of the drag image.
    static let shadowPad: CGFloat = 16
    /// Distance from the image's left edge to where the pointer should sit.
    static var cursorLead: CGFloat { shadowPad + 22 }

    @MainActor
    static func make(program: String?, title: String) -> NSImage {
        let renderer = ImageRenderer(
            content: TabDragPill(program: program, title: title).padding(shadowPad)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        renderer.isOpaque = false
        if let image = renderer.nsImage?.copy() as? NSImage, image.size.width > 8 {
            image.isTemplate = false
            return image
        }
        return NSImage(size: NSSize(width: 140, height: 32))
    }
}

private struct TabDragPill: View {
    var program: String?
    var title: String

    var body: some View {
        HStack(spacing: 6) {
            if let program {
                AgentMark(program: program)
                    .frame(width: 14, height: 14)
            }
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.terminalTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Palette.terminalSecondary)
                .frame(width: 10, height: 10)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: 220)
        .fixedSize(horizontal: true, vertical: true)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(hex: 0x2C2C2E))
                .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
    }
}
