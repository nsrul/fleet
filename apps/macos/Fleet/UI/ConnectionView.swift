import AppKit
import SwiftUI

struct ConnectionView: View {
    @Bindable var model: AppModel
    @State private var path: String

    init(model: AppModel) {
        self.model = model
        _path = State(initialValue: model.socketPath)
    }

    var body: some View {
        ZStack {
            Palette.terminal.ignoresSafeArea()

            if model.connection.isConnecting || model.connection == .idle {
                connecting
            } else {
                card
            }
        }
    }

    private var connecting: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(Palette.terminalText)
            Text(model.isStartingDaemon ? "Starting fleet-daemon…" : "Connecting to the daemon…")
                .font(Typography.bodyMedium)
                .foregroundStyle(Palette.terminalTitle)
            Text(model.socketPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Palette.terminalSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Fleet")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Local agent sessions")
                        .font(Typography.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text("OFFLINE")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }

            Text("Connect to the local daemon to attach live terminal sessions.")
                .font(Typography.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("SOCKET")
                    .font(Typography.section)
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                SocketPathEditor(draft: $path)
            }

            Toggle("Start the daemon automatically", isOn: $model.autoStartDaemon)
                .toggleStyle(.checkbox)
                .font(Typography.callout)

            if let failure = model.connection.failure {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.error)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    NoticeCopy(notice: failure, selectable: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Palette.error.opacity(0.08))
                )
            }

            HStack(spacing: 10) {
                Button("Connect") {
                    Task { await model.connectUsingPath(path) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!SocketPath.canSubmit(path))
                .keyboardShortcut(.defaultAction)

                if model.daemonExecutable != nil {
                    Button("Start daemon") {
                        Task { await model.startDaemonUsingPath(path) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!SocketPath.canSubmit(path) || model.isStartingDaemon)
                }

                Spacer()

                if model.isStartingDaemon {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            daemonHint
        }
        .padding(26)
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        )
    }

    @ViewBuilder
    private var daemonHint: some View {
        if let executable = model.daemonExecutable {
            Text("Daemon binary: \(executable)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(AgentNotices.daemonBinaryMissing().paragraph)
                .font(Typography.captionRegular)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
