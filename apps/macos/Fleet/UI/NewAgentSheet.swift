import AppKit
import SwiftUI

struct NewAgentSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var presetID: String?
    @State private var customProgram = ""
    @State private var name = ""
    @State private var cwd = AppModel.defaultWorkingDirectory
    @State private var notice: UserNotice?
    @State private var isCreating = false

    /// The selected tile, or the one the sheet should open on. Availability is
    /// read when the sheet is presented, so the first choice is an installed
    /// agent instead of a hardcoded one.
    private var selectedPresetID: String {
        presetID ?? AgentChoice.initialPresetID(
            candidates: AgentPreset.all.map(\.id),
            available: model.agentAvailability,
            lastUsed: model.lastAgentPresetID.isEmpty ? nil : model.lastAgentPresetID,
            customID: AgentPreset.customID
        ) ?? AgentPreset.all[0].id
    }

    private var preset: AgentPreset { AgentCatalog.preset(for: selectedPresetID) }
    /// The custom tile has no program of its own until the user types one.
    private func isInstalled(_ item: AgentPreset) -> Bool {
        item.isCustom || model.agentAvailability.contains(item.id)
    }

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
                        .accessibilityLabel("Program")
                        .accessibilityIdentifier("new-agent.program")
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
                    .accessibilityLabel("Session name")
                    .accessibilityIdentifier("new-agent.name")
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
                        .accessibilityLabel("Working directory")
                        .accessibilityIdentifier("new-agent.directory")
                    Button("Choose…") {
                        chooseDirectory()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel("Choose working directory")
                    .accessibilityIdentifier("new-agent.choose-directory")
                }
            }

            if let notice {
                NoticeCopy(
                    notice: notice,
                    titleColor: Palette.error,
                    selectable: true
                )
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("new-agent.cancel")

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
                .accessibilityLabel("Create agent")
                .accessibilityIdentifier("new-agent.create")
            }
        }
        .padding(24)
        .frame(width: 500, height: 560)
        .onChange(of: cwd) { _, _ in notice = nil }
        .onChange(of: name) { _, _ in notice = nil }
        .onChange(of: customProgram) { _, _ in notice = nil }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        Text("New agent")
            .font(.system(size: 15, weight: .semibold))
    }

    private func presetTile(_ item: AgentPreset) -> some View {
        let selected = selectedPresetID == item.id
        let installed = isInstalled(item)
        let tint = selected ? Palette.accent : (installed ? Color.primary : Color.secondary)
        return Button {
            presetID = item.id
            notice = nil
        } label: {
            HStack(spacing: 8) {
                AgentMark(preset: item)
                    .frame(width: 16, height: 16)
                    .opacity(installed ? 1 : 0.4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(tint)
                    if !installed {
                        Text("Not installed")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 36)
            .foregroundStyle(tint)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Palette.accent.opacity(0.10) : Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(helpText(for: item, installed: installed))
        .accessibilityIdentifier("new-agent.preset.\(item.id)")
        .accessibilityLabel(item.title)
        .accessibilityValue(installed ? "Available" : "Not installed")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func helpText(for item: AgentPreset, installed: Bool) -> String {
        if !installed {
            return "\(item.title) was not found in PATH."
        }
        return item.isCustom ? "Type the path to an executable." : item.binary
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
            notice = AgentNotices.missingFolder(expanded)
            return
        }

        isCreating = true
        notice = nil
        let requested = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = requested.isEmpty ? (program as NSString).lastPathComponent : requested
        Task {
            defer { isCreating = false }
            do {
                _ = try await model.createSession(
                    program: program,
                    arguments: preset.arguments,
                    cwd: expanded,
                    requestedName: name
                )
                if !preset.isCustom {
                    model.lastAgentPresetID = preset.id
                }
                dismiss()
            } catch {
                notice = AgentNotices.explain(
                    error,
                    action: .create,
                    agent: AppModel.displayTitle(forSessionID: label),
                    exit: nil
                )
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
