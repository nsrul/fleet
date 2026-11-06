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

                if model.draggingTab != nil, !panes.isEmpty {
                    edgeTargets
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

    private var edgeTargets: some View {
        ZStack {
            edge(.leading, title: "Open left", axis: .horizontal, placeFirst: true)
            edge(.trailing, title: "Open right", axis: .horizontal, placeFirst: false)
            edge(.top, title: "Open above", axis: .vertical, placeFirst: true)
            edge(.bottom, title: "Open below", axis: .vertical, placeFirst: false)
        }
        .allowsHitTesting(true)
    }

    private func edge(
        _ alignment: Alignment,
        title: String,
        axis: SplitAxis,
        placeFirst: Bool
    ) -> some View {
        EdgeDropZone(title: title) { drag in
            model.dropTab(drag, axis: axis, placeFirst: placeFirst)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .padding(alignment == .leading || alignment == .trailing ? .horizontal : .vertical, 0)
    }
}

private struct EdgeDropZone: View {
    let title: String
    let onDrop: (TabDrag) -> Void
    @State private var targeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.accent.opacity(targeted ? 0.32 : 0.16))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.accent.opacity(targeted ? 1 : 0.55), lineWidth: 1.5)
            Text(title)
                .font(Typography.caption)
                .foregroundStyle(Palette.terminalTitle)
        }
        .frame(width: 148, height: 72)
        .padding(18)
        .background {
            TabDropTarget(onTargeted: { targeted = $0 }) { drag in
                onDrop(drag)
                return true
            }
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
    var onTargeted: (Bool) -> Void
    var onDrop: (TabDrag) -> Bool

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
        context.coordinator.onDrop = onDrop
        view.coordinator = context.coordinator
    }

    final class Coordinator {
        var onTargeted: (Bool) -> Void = { _ in }
        var onDrop: (TabDrag) -> Bool = { _ in false }
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
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { coordinator?.onTargeted(true) }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { coordinator?.onTargeted(false) }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        MainActor.assumeIsolated { coordinator?.onTargeted(false) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let drag = TabDrag.read(sender.draggingPasteboard) else { return false }
        return MainActor.assumeIsolated {
            coordinator?.onDrop(drag) ?? false
        }
    }
}
