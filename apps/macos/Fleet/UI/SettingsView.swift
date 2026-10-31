import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance
    case terminal
    case workspace
    case daemon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .workspace: return "Workspace"
        case .daemon: return "Daemon"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "circle.lefthalf.filled"
        case .terminal: return "terminal"
        case .workspace: return "rectangle.split.3x1"
        case .daemon: return "point.3.connected.trianglepath.dotted"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var page: SettingsPage = .appearance

    var body: some View {
        HStack(spacing: 0) {
            rail
            DividerLine()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 720, height: 520)
        .background(Palette.windowBackground)
        .tint(Palette.accent)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases) { item in
                Button {
                    page = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 16)
                        Text(item.title)
                            .font(Typography.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(page == item ? Color.primary : Color.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(page == item ? Palette.sidebarSelection : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == item ? .isSelected : [])
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Fleet")
                        .font(Typography.caption)
                    Text(version)
                        .font(Typography.captionRegular)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .padding(10)
        .frame(width: 176)
        .frame(maxHeight: .infinity)
        .background(Palette.sidebarSurface)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(page.title)
                .font(Typography.title)

            ScrollView {
                Group {
                    switch page {
                    case .appearance:
                        AppearanceSettings(model: model)
                    case .terminal:
                        TerminalSettings(model: model)
                    case .workspace:
                        WorkspaceSettings(model: model)
                    case .daemon:
                        DaemonSettings(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(28)
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
