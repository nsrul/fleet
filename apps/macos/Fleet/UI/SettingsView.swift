import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.light.rawValue
    @State private var socketPath = ""
    @State private var didLoad = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearanceRaw) { _, newValue in
                    model.applyAppearance(newValue)
                }

                Text("The prototype defaults to Light to match the design reference.")
                    .font(Typography.captionRegular)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Glass")
                    HStack(spacing: 8) {
                        Text("Liquid")
                            .frame(width: 48, alignment: .leading)
                        Slider(value: $model.panelSolidity, in: 0...1)
                            .accessibilityLabel("Glass")
                        Text("Opaque")
                            .frame(width: 52, alignment: .trailing)
                    }
                    .font(Typography.captionRegular)
                    .foregroundStyle(.secondary)

                    Text("Left and right panels.")
                        .font(Typography.captionRegular)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Terminal") {
                HStack {
                    Text("Font size")
                    Slider(
                        value: Binding(
                            get: { model.terminalFontSize },
                            set: { model.setTerminalFontSize($0) }
                        ),
                        in: 10...18,
                        step: 1
                    )
                    Text("\(Int(model.terminalFontSize)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }

                Text("café 日本語 · ⬢ agent output")
                    .font(.system(size: model.terminalFontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }

            Section("Daemon") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Socket")
                        .font(Typography.captionRegular)
                        .foregroundStyle(.secondary)
                    TextField("~/.fleet/daemon.sock", text: $socketPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }

                Toggle("Start the daemon automatically", isOn: $model.autoStartDaemon)

                HStack(spacing: 8) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 6, height: 6)
                    Text(model.connectionSummary)
                        .font(Typography.captionRegular)
                        .foregroundStyle(.secondary)
                    if model.isStartingDaemon {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Spacer()
                }

                if let failure = model.connection.failure {
                    NoticeCopy(notice: failure, selectable: true)
                }

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

                    Spacer()

                    Button("Open log") {
                        openLog()
                    }
                    .buttonStyle(.plain)
                    .font(Typography.captionRegular)
                    .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                LabeledContent("Fleet", value: version)
                LabeledContent("Terminal", value: "SwiftTerm 1.99.1")
                LabeledContent("Protocol", value: "Local session API v1")
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 560)
        .onAppear {
            guard !didLoad else { return }
            socketPath = model.socketPath
            didLoad = true
        }
    }

    private var connectionColor: Color {
        switch model.connection {
        case .connected: return Palette.success
        case .connecting: return Palette.attention
        case .idle, .failed: return Palette.error
        }
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func openLog() {
        let log = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Fleet/daemon.log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        }
    }
}
