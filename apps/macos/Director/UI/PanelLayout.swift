import AppKit
import SwiftUI

/// Width limits for the sidebar and context panel. Defaults match the original
/// fixed layout. Max widths stop either panel from taking over a wide window.
enum PanelMetrics {
    static let sidebarMin: Double = 220
    static let sidebarDefault: Double = 256
    static let sidebarMax: Double = 360

    static let contextMin: Double = 320
    static let contextDefault: Double = 504
    static let contextMax: Double = 640

    static let terminalMin: Double = 320

    struct Widths: Equatable {
        var sidebar: Double
        var context: Double
        var terminal: Double
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        let value = value.isFinite ? value : lower
        let upper = max(lower, upper)
        return min(max(value, lower), upper)
    }

    /// Visible widths for the current window. Preferences are kept; a short
    /// window borrows from the context panel first, then the sidebar.
    static func fitted(
        total: Double,
        showSidebar: Bool,
        showContext: Bool,
        sidebar: Double,
        context: Double
    ) -> Widths {
        guard total.isFinite, total > 0 else {
            return Widths(
                sidebar: showSidebar ? sidebarDefault : 0,
                context: showContext ? contextDefault : 0,
                terminal: terminalMin
            )
        }

        var sidebar = showSidebar ? clamp(sidebar, sidebarMin, sidebarMax) : 0
        var context = showContext ? clamp(context, contextMin, contextMax) : 0
        let terminal = total - sidebar - context
        if terminal < terminalMin {
            var deficit = terminalMin - terminal
            if showContext {
                let give = min(deficit, max(0, context - contextMin))
                context -= give
                deficit -= give
            }
            if deficit > 0, showSidebar {
                let give = min(deficit, max(0, sidebar - sidebarMin))
                sidebar -= give
            }
        }
        return pack(total: total, sidebar: sidebar, context: context)
    }

    /// Drag the sidebar. The context panel gives up width only after the
    /// terminal is at its minimum.
    static func resizeSidebar(
        proposed: Double,
        total: Double,
        showContext: Bool,
        context: Double
    ) -> (sidebar: Double, context: Double) {
        let contextStored = clamp(context, contextMin, contextMax)
        guard total.isFinite, total > 0 else {
            return (clamp(proposed, sidebarMin, sidebarMax), showContext ? contextStored : context)
        }
        if !showContext {
            let upper = min(sidebarMax, total - terminalMin)
            return (clamp(proposed, sidebarMin, upper).rounded(), context)
        }
        let upper = min(sidebarMax, total - terminalMin - contextMin)
        let sidebar = clamp(proposed, sidebarMin, upper)
        var resolvedContext = contextStored
        if total - sidebar - resolvedContext < terminalMin {
            resolvedContext = max(contextMin, total - sidebar - terminalMin)
        }
        let packed = pack(total: total, sidebar: sidebar, context: resolvedContext)
        return (packed.sidebar, packed.context)
    }

    /// Drag the context panel. The sidebar gives up width only after the
    /// terminal is at its minimum.
    static func resizeContext(
        proposed: Double,
        total: Double,
        showSidebar: Bool,
        sidebar: Double
    ) -> (sidebar: Double, context: Double) {
        let sidebarStored = showSidebar ? clamp(sidebar, sidebarMin, sidebarMax) : 0
        guard total.isFinite, total > 0 else {
            return (sidebar, clamp(proposed, contextMin, contextMax))
        }
        if !showSidebar {
            let upper = min(contextMax, total - terminalMin)
            return (sidebar, clamp(proposed, contextMin, upper).rounded())
        }
        let upper = min(contextMax, total - terminalMin - sidebarMin)
        let context = clamp(proposed, contextMin, upper)
        var resolvedSidebar = sidebarStored
        if total - resolvedSidebar - context < terminalMin {
            resolvedSidebar = max(sidebarMin, total - context - terminalMin)
        }
        let packed = pack(total: total, sidebar: resolvedSidebar, context: context)
        return (packed.sidebar, packed.context)
    }

    private static func pack(total: Double, sidebar: Double, context: Double) -> Widths {
        var sidebar = sidebar.rounded()
        var context = context.rounded()
        if sidebar + context > total {
            if context > 0 {
                context = max(0, total - sidebar)
            }
            if sidebar + context > total {
                sidebar = min(sidebar, max(0, total))
                context = max(0, total - sidebar)
            }
        }
        return Widths(
            sidebar: sidebar,
            context: context,
            terminal: max(0, total - sidebar - context)
        )
    }
}

struct WorkspaceColumns: View {
    @Bindable var model: AppModel

    @AppStorage("director.sidebarWidth") private var sidebarWidth = PanelMetrics.sidebarDefault
    @AppStorage("director.contextWidth") private var contextWidth = PanelMetrics.contextDefault
    @State private var sidebarOrigin: Double?
    @State private var contextOrigin: Double?

    var body: some View {
        GeometryReader { geo in
            let total = Double(geo.size.width)
            let showSidebar = model.showSidebar
            let showContext = model.showContext && model.connection.isConnected
            let widths = PanelMetrics.fitted(
                total: total,
                showSidebar: showSidebar,
                showContext: showContext,
                sidebar: sidebarWidth,
                context: contextWidth
            )

            HStack(spacing: 0) {
                if showSidebar {
                SidebarView(model: model)
                    .frame(width: CGFloat(widths.sidebar), height: geo.size.height)
                    .overlay(alignment: .trailing) {
                        PanelResizeHandle(
                            label: "Sidebar width",
                            value: widths.sidebar,
                            growsTowardTrailingEdge: true,
                            onDrag: { growth in
                                resizeSidebar(by: growth, total: total, showContext: showContext)
                            },
                            onDragEnd: { growth in
                                resizeSidebar(by: growth, total: total, showContext: showContext)
                                clearDrag()
                            },
                            onStep: { step in
                                let resized = PanelMetrics.resizeSidebar(
                                    proposed: sidebarWidth + step,
                                    total: total,
                                    showContext: showContext,
                                    context: contextWidth
                                )
                                sidebarWidth = resized.sidebar
                                if showContext { contextWidth = resized.context }
                            },
                            onReset: { sidebarWidth = PanelMetrics.sidebarDefault }
                        )
                    }
                }

                TerminalAreaView(model: model)
                    .frame(width: CGFloat(widths.terminal), height: geo.size.height)

                if showContext {
                    ContextPanelView(model: model)
                        .frame(width: CGFloat(widths.context), height: geo.size.height)
                        .overlay(alignment: .leading) {
                            PanelResizeHandle(
                                label: "Context panel width",
                                value: widths.context,
                                growsTowardTrailingEdge: false,
                                onDrag: { growth in
                                    resizeContext(by: growth, total: total)
                                },
                                onDragEnd: { growth in
                                    resizeContext(by: growth, total: total)
                                    clearDrag()
                                },
                                onStep: { step in
                                    let resized = PanelMetrics.resizeContext(
                                        proposed: contextWidth + step,
                                        total: total,
                                        showSidebar: showSidebar,
                                        sidebar: sidebarWidth
                                    )
                                    if showSidebar { sidebarWidth = resized.sidebar }
                                    contextWidth = resized.context
                                },
                                onReset: { contextWidth = PanelMetrics.contextDefault }
                            )
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .animation(.easeInOut(duration: 0.18), value: showSidebar)
            .animation(.easeInOut(duration: 0.18), value: showContext)
        }
        .onAppear {
            sidebarWidth = PanelMetrics.clamp(
                sidebarWidth,
                PanelMetrics.sidebarMin,
                PanelMetrics.sidebarMax
            )
            contextWidth = PanelMetrics.clamp(
                contextWidth,
                PanelMetrics.contextMin,
                PanelMetrics.contextMax
            )
        }
    }

    private func resizeSidebar(by growth: Double, total: Double, showContext: Bool) {
        if sidebarOrigin == nil {
            sidebarOrigin = sidebarWidth
            contextOrigin = contextWidth
        }
        let resized = PanelMetrics.resizeSidebar(
            proposed: (sidebarOrigin ?? sidebarWidth) + growth,
            total: total,
            showContext: showContext,
            context: contextOrigin ?? contextWidth
        )
        sidebarWidth = resized.sidebar
        if showContext {
            contextWidth = resized.context
        }
    }

    private func resizeContext(by growth: Double, total: Double) {
        if contextOrigin == nil {
            sidebarOrigin = sidebarWidth
            contextOrigin = contextWidth
        }
        let resized = PanelMetrics.resizeContext(
            proposed: (contextOrigin ?? contextWidth) + growth,
            total: total,
            showSidebar: model.showSidebar,
            sidebar: sidebarOrigin ?? sidebarWidth
        )
        if model.showSidebar {
            sidebarWidth = resized.sidebar
        }
        contextWidth = resized.context
    }

    private func clearDrag() {
        sidebarOrigin = nil
        contextOrigin = nil
    }
}

private struct PanelResizeHandle: View {
    var label: String
    var value: Double
    var growsTowardTrailingEdge: Bool
    var onDrag: (Double) -> Void
    var onDragEnd: (Double) -> Void
    var onStep: (Double) -> Void
    var onReset: () -> Void

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.001))
            .frame(width: 10)
            .frame(maxHeight: .infinity)
            .overlay(alignment: growsTowardTrailingEdge ? .trailing : .leading) {
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: 2)
                    .opacity(hovering || dragging ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    hovering = true
                    NSCursor.resizeLeftRight.set()
                case .ended:
                    hovering = false
                    if !dragging {
                        NSCursor.arrow.set()
                    }
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if !dragging { dragging = true }
                        NSCursor.resizeLeftRight.set()
                        let growth = growsTowardTrailingEdge
                            ? value.translation.width
                            : -value.translation.width
                        onDrag(Double(growth))
                    }
                    .onEnded { value in
                        dragging = false
                        if hovering {
                            NSCursor.resizeLeftRight.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                        let growth = growsTowardTrailingEdge
                            ? value.translation.width
                            : -value.translation.width
                        onDragEnd(Double(growth))
                    }
            )
            .onTapGesture(count: 2, perform: onReset)
            .onDisappear { NSCursor.arrow.set() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(value.rounded())) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onStep(24)
                case .decrement: onStep(-24)
                @unknown default: break
                }
            }
            .accessibilityHint("Drag to resize. Double-click to reset.")
    }
}
