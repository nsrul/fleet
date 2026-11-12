import Foundation

/// Rebuilds the launch of an existing session for a new process.
///
/// The daemon reports the exact arguments and environment a session started
/// with, including the ones Fleet adds to connect the agent to its plugin.
/// Those belong to the old session: the app builds fresh ones for the new
/// session, so a fork keeps only what the user asked for.
public enum SessionFork {
    /// Arguments that belong to the user, with the trailing Fleet plugin flags
    /// for `presetID` removed. `FleetPluginLaunch` appends those last, so a
    /// user argument that happens to share a name is left alone.
    public static func arguments(_ args: [String], presetID: String?) -> [String] {
        switch presetID {
        case "claude"?:
            return droppingTail(args, count: 2) { tail in
                tail.first == "--mcp-config"
            }
        case "codex"?:
            // Fleet adds `--no-daemon` when the app-server is unreachable, and
            // the next launch decides again whether it is needed.
            let args = args.first == "--no-daemon" ? Array(args.dropFirst()) : args
            return droppingTail(args, count: 2) { tail in
                tail.first == "-c" && tail.last?.hasPrefix("mcp_servers.fleet.url=") == true
            }
        case "opencode"?:
            return droppingTail(args, count: 1) { $0 == ["--standalone"] }
        default:
            return args
        }
    }

    /// Environment the session needs that Fleet does not own. The terminal
    /// variables, the session ID, and the plugin configuration are rebuilt for
    /// the new session.
    public static func environment(_ env: [String: String]) -> [String: String] {
        env.filter { key, _ in
            !key.hasPrefix("FLEET_") && !reservedEnvironmentKeys.contains(key)
        }
    }

    private static let reservedEnvironmentKeys: Set<String> = [
        "TERM",
        "COLORTERM",
        FleetPluginFiles.geminiSystemSettingsEnvironmentKey,
        FleetPluginFiles.opencodeConfigEnvironmentKey,
    ]

    private static func droppingTail(
        _ args: [String],
        count: Int,
        matching predicate: ([String]) -> Bool
    ) -> [String] {
        guard args.count >= count else { return args }
        guard predicate(Array(args.suffix(count))) else { return args }
        return Array(args.dropLast(count))
    }
}
