import AppKit
import SwiftUI

struct NewAgentSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var presetID = "claude"
    @State private var customProgram = ""
    @State private var name = ""
    @State private var cwd = AppModel.defaultWorkingDirectory
    @State private var errorMessage: String?
    @State private var isCreating = false

    private var preset: AgentPreset { AgentCatalog.preset(for: presetID) }
    private var program: String? {
        preset.isCustom
            ? AgentCatalog.resolveProgram(customProgram)
            : AgentCatalog.resolveProgram(preset.binary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(alignment: .leading, spacing: 8) {
                Text("AGENT")
                    .font(Typography.section)
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                    spacing: 8
                ) {
                    ForEach(AgentPreset.all) { item in
                        presetTile(item)
                    }
                }
            }

            if preset.isCustom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROGRAM")
                        .font(Typography.section)
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                    TextField("/path/to/agent", text: $customProgram)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            programStatus

            VStack(alignment: .leading, spacing: 6) {
                Text("SESSION NAME")
                    .font(Typography.section)
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                TextField("Optional; defaults to the agent name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.body)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WORKING DIRECTORY")
                    .font(Typography.section)
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    TextField("~/code/project", text: $cwd)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Choose…") {
                        chooseDirectory()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(Typography.captionRegular)
                    .foregroundStyle(Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Text("The agent runs in its own PTY. Closing Director leaves it running.")
                    .font(Typography.captionRegular)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)

                Spacer(minLength: 8)

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button {
                    create()
                } label: {
                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 88)
                    } else {
                        Text("Create agent")
                            .frame(width: 88)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canCreate)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("New agent")
                    .font(.system(size: 19, weight: .semibold))
                Text("Launch a local CLI in a live terminal pane.")
                    .font(Typography.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func presetTile(_ item: AgentPreset) -> some View {
        let selected = presetID == item.id
        return Button {
            presetID = item.id
            errorMessage = nil
        } label: {
            VStack(spacing: 5) {
                Image(systemName: item.symbol)
                    .font(.system(size: 15, weight: .regular))
                    .frame(height: 17)
                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(selected ? Palette.accent : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Palette.accent.opacity(0.10) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Palette.accent : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var programStatus: some View {
        if preset.isCustom && customProgram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Enter the full path to an executable.")
                .font(Typography.captionRegular)
                .foregroundStyle(.tertiary)
        } else if let program {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.success)
                Text(program)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.attention)
                Text("\(preset.title) was not found in PATH.")
                    .font(Typography.captionRegular)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canCreate: Bool {
        guard !isCreating, program != nil else { return false }
        let path = NSString(string: cwd).expandingTildeInPath
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func create() {
        guard let program else { return }
        let expanded = NSString(string: cwd).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = "The working directory does not exist."
            return
        }

        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                _ = try await model.createSession(
                    program: program,
                    arguments: preset.arguments,
                    cwd: expanded,
                    requestedName: name
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: NSString(string: cwd).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            cwd = url.path
        }
    }
}
