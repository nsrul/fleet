import AppKit
import FleetAPI
import SwiftUI

enum Palette {
    static let accent = Color(hex: 0x007AFF)
    static let attention = Color(hex: 0xFF9F0A)
    static let error = Color(hex: 0xFF3B30)
    static let success = Color(hex: 0x34C759)

    static let terminal = Color(hex: 0x18181A)
    static let terminalText = Color(hex: 0xE5E5EA)
    static let terminalSecondary = Color(hex: 0x8E8E93)
    static let terminalTitle = Color(hex: 0xF5F5F7)
    static let terminalDivider = Color.white.opacity(0.08)
    static let terminalBorder = Color.white.opacity(0.22)
    static let terminalSelection = Color(hex: 0x007AFF).opacity(0.35)

    static let terminalNS = NSColor(srgbRed: 0x18 / 255, green: 0x18 / 255, blue: 0x1A / 255, alpha: 1)
    static let terminalTextNS = NSColor(
        srgbRed: 0xE5 / 255,
        green: 0xE5 / 255,
        blue: 0xEA / 255,
        alpha: 1
    )
    static let accentNS = NSColor(srgbRed: 0x00, green: 0x7A / 255, blue: 1, alpha: 1)
    static let terminalSelectionNS = NSColor(
        srgbRed: 0x00,
        green: 0x7A / 255,
        blue: 1,
        alpha: 0.35
    )

    static let terminalStatusBar = Color(hex: 0x121214)
    static let sidebarSelection = Color.primary.opacity(0.07)
    static let sidebarHover = Color.primary.opacity(0.04)

    static let sidebarSurface = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 1)
            : NSColor(srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255, alpha: 1)
    })

    static var windowBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var contextBackground: Color { Color(nsColor: .textBackgroundColor) }
    static var sidebarTint: Color { Color(nsColor: .windowBackgroundColor).opacity(0.35) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Shared metrics for the top chrome so the sidebar tools, pane toggles, and
/// context tabs share one row height and control size.
enum WorkspaceChrome {
    static let barHeight: CGFloat = 38
    static let controlSize: CGFloat = 28
    static let controlRadius: CGFloat = 7
    static let trailingInset: CGFloat = 8
    static var controlTopInset: CGFloat { (barHeight - controlSize) / 2 }
}

enum Typography {
    static let largeTitle = Font.system(size: 26, weight: .bold)
    static let title = Font.system(size: 17, weight: .semibold)
    static let headline = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let callout = Font.system(size: 12, weight: .regular)
    static let calloutMedium = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11, weight: .medium)
    static let captionRegular = Font.system(size: 11, weight: .regular)
    static let section = Font.system(size: 10, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let monoBranch = Font.system(size: 13, design: .monospaced)
}

struct DividerLine: View {
    var color: Color = Color.primary.opacity(0.12)
    var body: some View {
        Rectangle().fill(color).frame(width: 1)
    }
}

struct HorizontalDivider: View {
    var color: Color = Color.primary.opacity(0.07)
    var body: some View {
        Rectangle().fill(color).frame(height: 1)
    }
}

struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        Group {
            switch status {
            case .running:
                Circle().fill(Palette.accent)
            case .exited(let exit):
                Circle().fill(exit.success ? Palette.success : Palette.error)
            }
        }
        .frame(width: 7, height: 7)
    }
}

/// Brand mark for an agent preset. Custom is a template image, so it picks up
/// the surrounding foreground style. The others keep their own colors.
struct AgentMark: View {
    let preset: AgentPreset

    init(preset: AgentPreset) {
        self.preset = preset
    }

    init(program: String) {
        self.preset = AgentCatalog.preset(forProgram: program)
            ?? AgentPreset(
                id: "custom",
                title: AgentCatalog.displayName(for: program),
                binary: program,
                arguments: [],
                symbol: "terminal"
            )
    }

    var body: some View {
        Image(resource)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }

    private var resource: ImageResource {
        switch preset.id {
        case "claude": .agentClaude
        case "codex": .agentCodex
        case "cursor": .agentCursor
        case "gemini": .agentGemini
        case "opencode": .agentOpenCode
        case "shell": .agentShell
        default: .agentCustom
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.calloutMedium)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.accent.opacity(configuration.isPressed ? 0.82 : 1))
            )
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.calloutMedium)
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.06))
            )
    }
}

struct PlainTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.calloutMedium)
            .foregroundStyle(Palette.accent.opacity(configuration.isPressed ? 0.7 : 1))
    }
}

struct TerminalSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.calloutMedium)
            .foregroundStyle(Palette.terminalText)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.06 : 0.1))
            )
    }
}

struct PanelToggleButton: View {
    let systemImage: String
    let help: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? Palette.terminalTitle : Palette.terminalSecondary.opacity(0.65))
                .frame(width: WorkspaceChrome.controlSize, height: WorkspaceChrome.controlSize)
                .background(
                    RoundedRectangle(cornerRadius: WorkspaceChrome.controlRadius, style: .continuous)
                        .fill(Color.white.opacity(isOn ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct TerminalHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typography.calloutMedium)
            .foregroundStyle(
                Palette.terminalSecondary.opacity(configuration.isPressed ? 0.55 : 1)
            )
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0))
            )
            .contentShape(Rectangle())
    }
}

/// A subtle rounded container used by cards and empty states.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
    }
}

extension View {
    func cardBackground(radius: CGFloat = 10) -> some View {
        modifier(CardBackground(radius: radius))
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

/// Side-panel fill. Solidity 0 is liquid glass. Solidity 1 is the solid color.
struct PanelSurface: View {
    var solid: Color
    var solidity: Double

    private var showsGlass: Bool { solidity < 0.999 }

    var body: some View {
        ZStack {
            if showsGlass {
                LiquidGlassPlate()
            }
            solid.opacity(showsGlass ? solidity : 1)
        }
        .accessibilityHidden(true)
    }
}

/// Clears the window while the side panels are glass, so the effect samples
/// the desktop instead of an opaque window fill. Solid mode restores it.
struct WindowOpacity: NSViewRepresentable {
    var transparent: Bool

    func makeNSView(context: Context) -> WindowOpacityView {
        let view = WindowOpacityView()
        view.transparent = transparent
        return view
    }

    func updateNSView(_ nsView: WindowOpacityView, context: Context) {
        nsView.transparent = transparent
    }
}

final class WindowOpacityView: NSView {
    var transparent = false {
        didSet {
            if transparent != oldValue { apply() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func apply() {
        guard let window else { return }
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : .windowBackgroundColor
        window.invalidateShadow()
    }
}

private struct LiquidGlassPlate: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            let content = NSView()
            content.autoresizingMask = [.width, .height]
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        return effect
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26, *), let glass = nsView as? NSGlassEffectView {
            glass.style = .regular
            glass.cornerRadius = 0
        }
    }
}

/// Socket field shared by Settings and the connection card.
struct SocketPathEditor: View {
    @Binding var draft: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("~/.fleet/daemon.sock", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(Typography.monoSmall)
            if let message = SocketPath.validationMessage(for: draft) {
                Text(message)
                    .font(Typography.captionRegular)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
