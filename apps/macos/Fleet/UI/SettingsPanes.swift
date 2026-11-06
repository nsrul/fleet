import AppKit
import SwiftUI

struct AppearanceSettings: View {
    @Bindable var model: AppModel
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.light.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsLabel(text: "Theme")
                HStack(spacing: 12) {
                    ForEach(AppAppearance.allCases) { appearance in
                        themeButton(appearance)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsLabel(text: "Panels")
                PanelDiagram(solidity: model.panelSolidity)
                HStack(spacing: 8) {
                    Text("Liquid")
                        .frame(width: 48, alignment: .leading)
                    Slider(value: $model.panelSolidity, in: 0...1)
                        .accessibilityLabel("Glass")
                    Text("Opaque")
                        .frame(width: 52, alignment: .trailing)
                }
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onChange(of: appearanceRaw) { _, newValue in
            model.applyAppearance(newValue)
        }
    }

    private func themeButton(_ appearance: AppAppearance) -> some View {
        let selected = appearanceRaw == appearance.rawValue
        return Button {
            appearanceRaw = appearance.rawValue
        } label: {
            VStack(spacing: 6) {
                ThemeSwatch(appearance: appearance)
                    .frame(width: 76, height: 52)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                selected ? Palette.accent : Color.primary.opacity(0.08),
                                lineWidth: selected ? 1.5 : 1
                            )
                    )
                Text(appearance.title)
                    .font(Typography.caption)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(appearance.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct TerminalSettings: View {
    @Bindable var model: AppModel
    @State private var faces: [TerminalFont.Face] = [
        TerminalFont.Face(id: TerminalFont.systemID, title: "System")
    ]

    private let shapes: [(id: String, title: String)] = [
        ("block", "Block"),
        ("underline", "Line"),
        ("bar", "Bar"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            specimen

            VStack(alignment: .leading, spacing: 8) {
                SettingsLabel(text: "Font")
                fontList
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsLabel(text: "Size")
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { model.terminal.fontSize },
                            set: { model.terminal.fontSize = $0 }
                        ),
                        in: 10...18,
                        step: 1
                    )
                    .accessibilityLabel("Font size")
                    Text("\(Int(model.terminal.fontSize.rounded())) pt")
                        .font(Typography.monoSmall)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsLabel(text: "Cursor")
                HStack(spacing: 8) {
                    ForEach(shapes, id: \.id) { shape in
                        cursorButton(shape.id, title: shape.title)
                    }
                    Spacer(minLength: 12)
                    Toggle("Blink", isOn: blinks)
                        .font(Typography.body)
                        .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsLabel(text: "Spacing")
                Picker("Spacing", selection: spacing) {
                    Text("Tight").tag(TerminalPreferences.spacings[0])
                    Text("Normal").tag(TerminalPreferences.spacings[1])
                    Text("Room").tag(TerminalPreferences.spacings[2])
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Spacing")
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsLabel(text: "Scrollback")
                Picker("Scrollback", selection: scrollback) {
                    Text("5k").tag(TerminalPreferences.scrollbacks[0])
                    Text("20k").tag(TerminalPreferences.scrollbacks[1])
                    Text("50k").tag(TerminalPreferences.scrollbacks[2])
                    Text("100k").tag(TerminalPreferences.scrollbacks[3])
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Scrollback")
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsLabel(text: "Keyboard")
                SettingsRow {
                    Toggle("Option is Meta", isOn: optionIsMeta)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsLabel(text: "Bell")
                SettingsRow {
                    Toggle("Sound", isOn: bellSound)
                }
            }
        }
        .onAppear {
            faces = TerminalFont.installed()
        }
    }

    private var specimen: some View {
        let font = TerminalFont.resolve(
            id: model.terminal.fontID,
            size: CGFloat(model.terminal.fontSize)
        )
        let shape = TerminalPreferences.shape(of: model.terminal.cursorTag)
        return VStack(alignment: .leading, spacing: 6) {
            Text("~/code")
                .font(Font(TerminalFont.resolve(id: model.terminal.fontID, size: max(11, font.pointSize * 0.82))))
                .foregroundStyle(Palette.terminalSecondary)
            HStack(alignment: .center, spacing: 2) {
                Text("❯ café 日本語")
                    .font(Font(font))
                    .foregroundStyle(Palette.terminalText)
                    .lineLimit(1)
                SpecimenCursor(shape: shape, size: font.pointSize)
                    .foregroundStyle(Palette.terminalText)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .frame(height: 92)
        .background(Palette.terminal)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Terminal preview")
    }

    private var fontList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(faces) { face in
                    fontRow(face)
                }
            }
        }
        .frame(height: 168)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func fontRow(_ face: TerminalFont.Face) -> some View {
        let selected = model.terminal.fontID == face.id
        return Button {
            model.terminal.fontID = face.id
        } label: {
            HStack(spacing: 8) {
                Text(face.title)
                    .font(Font(TerminalFont.resolve(id: face.id, size: 13)))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.accent.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(face.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func cursorButton(_ shape: String, title: String) -> some View {
        let selected = TerminalPreferences.shape(of: model.terminal.cursorTag) == shape
        return Button {
            model.terminal.cursorTag = TerminalPreferences.tag(shape: shape, blinks: blinks.wrappedValue)
        } label: {
            VStack(spacing: 4) {
                SpecimenCursor(shape: shape, size: 14)
                    .frame(width: 28, height: 16)
                Text(title)
                    .font(Typography.caption)
            }
            .foregroundStyle(selected ? Palette.accent : Color.primary)
            .frame(width: 64, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Palette.accent.opacity(0.1) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Palette.accent : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var blinks: Binding<Bool> {
        Binding(
            get: { TerminalPreferences.blinks(model.terminal.cursorTag) },
            set: { blink in
                let shape = TerminalPreferences.shape(of: model.terminal.cursorTag)
                model.terminal.cursorTag = TerminalPreferences.tag(shape: shape, blinks: blink)
            }
        )
    }

    private var spacing: Binding<Double> {
        Binding(
            get: { model.terminal.lineSpacing },
            set: { model.terminal.lineSpacing = $0 }
        )
    }

    private var scrollback: Binding<Int> {
        Binding(
            get: { model.terminal.scrollback },
            set: { model.terminal.scrollback = $0 }
        )
    }

    private var optionIsMeta: Binding<Bool> {
        Binding(
            get: { model.terminal.optionIsMeta },
            set: { model.terminal.optionIsMeta = $0 }
        )
    }

    private var bellSound: Binding<Bool> {
        Binding(
            get: { model.terminal.bellSound },
            set: { model.terminal.bellSound = $0 }
        )
    }
}

struct WorkspaceSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsLabel(text: "Keyboard split")
                HStack(spacing: 8) {
                    splitButton(.stacked, symbol: "rectangle.split.1x2", title: "Stacked")
                    splitButton(.sideBySide, symbol: "rectangle.split.2x1", title: "Side by side")
                }
            }

            SettingsRow {
                Toggle("Confirm before stopping", isOn: $model.confirmStop)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsLabel(text: "New agent folder")
                HStack(spacing: 8) {
                    Text(folderLabel)
                        .font(model.pinnedWorkingDirectory.isEmpty ? Typography.body : Typography.monoSmall)
                        .foregroundStyle(model.pinnedWorkingDirectory.isEmpty ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if !model.pinnedWorkingDirectory.isEmpty {
                        Button("Clear") {
                            model.pinnedWorkingDirectory = ""
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Button("Choose") {
                        model.choosePinnedDirectory()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var folderLabel: String {
        model.pinnedWorkingDirectory.isEmpty ? "Last used" : model.pinnedWorkingDirectory
    }

    private func splitButton(_ layout: SplitLayout, symbol: String, title: String) -> some View {
        let selected = model.defaultSplitLayout == layout
        return Button {
            model.defaultSplitLayout = layout
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 20)
                Text(title)
                    .font(Typography.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Palette.accent : Color.primary)
            .frame(width: 108, height: 58)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Palette.accent.opacity(0.1) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Palette.accent : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DaemonSettings: View {
    @Bindable var model: AppModel
    @State private var socketPath = ""
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 6, height: 6)
                Text(statusWord)
                    .font(Typography.bodyMedium)
                if let version = daemonVersion {
                    Text(version)
                        .font(Typography.monoSmall)
                        .foregroundStyle(.secondary)
                }
                if model.isStartingDaemon {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer(minLength: 0)
            }

            if let failure = model.connection.failure {
                NoticeCopy(notice: failure, selectable: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsLabel(text: "Socket")
                TextField("~/.fleet/daemon.sock", text: $socketPath)
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.monoSmall)
            }

            Toggle("Start with Fleet", isOn: $model.autoStartDaemon)
                .font(Typography.body)

            HStack(spacing: 10) {
                Button("Apply & Reconnect") {
                    Task { await model.connectUsingPath(socketPath) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.connection.isConnecting)

                if model.daemonExecutable != nil {
                    Button("Start daemon") {
                        Task { await model.startDaemonUsingPath(socketPath) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isStartingDaemon)
                }

                Button("Open log") {
                    NSWorkspace.shared.open(logURL)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!logExists)

                Spacer(minLength: 0)
            }
        }
        .onAppear {
            guard !didLoad else { return }
            socketPath = model.socketPath
            didLoad = true
        }
    }

    private var statusWord: String {
        switch model.connection {
        case .idle, .failed: return "Offline"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        }
    }

    private var daemonVersion: String? {
        if case .connected(let welcome) = model.connection {
            return welcome.daemonVersion
        }
        return nil
    }

    private var connectionColor: Color {
        switch model.connection {
        case .connected: return Palette.success
        case .connecting: return Palette.attention
        case .idle, .failed: return Palette.error
        }
    }

    private var logURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Fleet/daemon.log")
    }

    private var logExists: Bool {
        FileManager.default.fileExists(atPath: logURL.path)
    }
}

struct SettingsLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Typography.caption)
            .foregroundStyle(.secondary)
    }
}

private struct SettingsRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .font(Typography.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ThemeSwatch: View {
    var appearance: AppAppearance

    private static let light = Color(hex: 0xF2F2F4)
    private static let dark = Color(hex: 0x1C1C1E)
    private static let lightBar = Color(hex: 0xE6E6EA)
    private static let darkBar = Color(hex: 0x2C2C2E)

    var body: some View {
        HStack(spacing: 2) {
            bar(leading)
            Palette.terminal
            bar(trailing)
        }
        .padding(4)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var leading: Color {
        switch appearance {
        case .dark: return Self.darkBar
        case .light, .system: return Self.lightBar
        }
    }

    private var trailing: Color {
        switch appearance {
        case .light: return Self.lightBar
        case .dark, .system: return Self.darkBar
        }
    }

    @ViewBuilder
    private var background: some View {
        switch appearance {
        case .light:
            Self.light
        case .dark:
            Self.dark
        case .system:
            HStack(spacing: 0) {
                Self.light
                Self.dark
            }
        }
    }

    private func bar(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: 14)
    }
}

private struct PanelDiagram: View {
    var solidity: Double

    var body: some View {
        HStack(spacing: 3) {
            pane.frame(width: 18)
            Palette.terminal
            pane.frame(width: 22)
        }
        .padding(4)
        .frame(width: 120, height: 36)
        .background(
            LinearGradient(
                colors: [
                    Color(hex: 0x8E8E93).opacity(0.28),
                    Color(hex: 0xD1D1D6).opacity(0.45),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }

    private var pane: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(solidity))
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1)
            )
    }
}

private struct SpecimenCursor: View {
    var shape: String
    var size: CGFloat

    var body: some View {
        let height = max(8, size * 0.92)
        let width: CGFloat = shape == "bar" ? 2 : max(6, size * 0.55)
        let mark = shape == "underline" ? 2.0 : height
        Rectangle()
            .frame(width: width, height: mark)
            .frame(height: height, alignment: shape == "underline" ? .bottom : .center)
    }
}
