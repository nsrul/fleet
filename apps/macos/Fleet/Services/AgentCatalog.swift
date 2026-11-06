import FleetAPI
import Foundation

struct AgentPreset: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let binary: String
    let arguments: [String]
    let symbol: String

    static let all: [AgentPreset] = [
        AgentPreset(id: "claude", title: "Claude Code", binary: "claude", arguments: [], symbol: "sparkles"),
        AgentPreset(id: "codex", title: "Codex", binary: "codex", arguments: [], symbol: "terminal"),
        AgentPreset(id: "cursor", title: "Cursor Agent", binary: "cursor-agent", arguments: [], symbol: "cursorarrow"),
        AgentPreset(id: "gemini", title: "Gemini CLI", binary: "gemini", arguments: [], symbol: "diamond"),
        AgentPreset(id: "opencode", title: "OpenCode", binary: "opencode", arguments: [], symbol: "chevron.left.forwardslash.chevron.right"),
        AgentPreset(id: "shell", title: "Shell", binary: "/bin/zsh", arguments: ["-l"], symbol: "terminal"),
        AgentPreset(id: "custom", title: "Custom…", binary: "", arguments: [], symbol: "ellipsis"),
    ]

    var isCustom: Bool { id == "custom" }
}

enum AgentCatalog {
    static func preset(for id: String) -> AgentPreset {
        AgentPreset.all.first(where: { $0.id == id }) ?? AgentPreset.all[0]
    }

    static func preset(forProgram program: String) -> AgentPreset? {
        let name = (program as NSString).lastPathComponent
        return AgentPreset.all.first(where: { preset in
            guard !preset.isCustom else { return false }
            return preset.binary == name || (preset.binary as NSString).lastPathComponent == name
        })
    }

    static func displayName(for program: String) -> String {
        if let preset = preset(forProgram: program), !preset.isCustom {
            return preset.title
        }
        let name = (program as NSString).lastPathComponent
        guard !name.isEmpty else { return "Agent" }
        return name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    static func symbol(for program: String) -> String {
        preset(forProgram: program)?.symbol ?? "terminal"
    }

    /// Finds an executable using the small PATH a GUI app actually receives.
    static func resolveProgram(_ binary: String) -> String? {
        let trimmed = binary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("/") {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            return isExecutable(expanded) ? expanded : nil
        }

        var directories: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        let home = NSHomeDirectory()
        directories.append(contentsOf: [
            "\(home)/.local/bin",
            "\(home)/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ])

        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let candidate = (directory as NSString).appendingPathComponent(trimmed)
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    static var pluginPresets: [PluginPreset] {
        AgentPreset.all.filter { !$0.isCustom }.map {
            PluginPreset(id: $0.id, binary: $0.binary, arguments: $0.arguments)
        }
    }

    /// Arguments and environment that point a supported preset at this app's
    /// plugin. Shell, custom commands, and presets without a session-scoped
    /// hook get an empty spec.
    static func pluginLaunch(program: String, endpoint: FleetPluginEndpoint) -> FleetPluginSpec {
        guard let preset = preset(forProgram: program) else { return FleetPluginSpec() }
        return FleetPluginLaunch.spec(presetID: preset.id, endpoint: endpoint)
    }
}
