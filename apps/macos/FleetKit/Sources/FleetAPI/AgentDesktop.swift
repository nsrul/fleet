import Foundation

/// Environment and state directory for an installed `agent-desktop` binary.
/// Fleet does not talk to the accessibility API. A missing binary is an empty result.
public enum AgentDesktop {
    public static let binaryName = "agent-desktop"
    /// UI tests set this so a machine with the binary installed does not open System Settings.
    public static let skipEnvironmentKey = "FLEET_SKIP_AGENT_DESKTOP"
    public static let binaryEnvironmentKey = "FLEET_AGENT_DESKTOP_BIN"
    public static let sessionEnvironmentKey = "FLEET_AGENT_DESKTOP_SESSION"
    public static let rootEnvironmentKey = "FLEET_AGENT_DESKTOP_ROOT"
    public static let homeEnvironmentKey = "AGENT_DESKTOP_HOME"

    /// An installed binary and the directory that holds one home per session.
    public struct Installation: Equatable, Sendable {
        public var binary: String
        public var root: String

        public init(binary: String, root: String) {
            self.binary = binary
            self.root = root
        }
    }

    public struct Launch: Equatable, Sendable {
        public var environment: [String: String]
        public var home: String
    }

    public struct Permissions: Equatable, Sendable {
        public var accessibilityDenied: Bool
        /// `started`, `already_running`, or `not_needed` when the guide ran.
        public var guide: String?
    }

    public struct Notice: Equatable, Sendable {
        public var title: String
        public var detail: String
    }

    /// `Application Support/Fleet/agent-desktop`, outside any session working tree.
    public static func defaultRoot() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .path ?? NSHomeDirectory()
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("Fleet/agent-desktop", isDirectory: true)
            .path
    }

    /// Nil when the binary path or session id cannot name a private directory.
    public static func launch(binary: String, sessionID: String, root: String) -> Launch? {
        let program = binary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !program.isEmpty, let home = homeDirectory(root: root, sessionID: sessionID) else {
            return nil
        }
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return Launch(
            environment: [
                binaryEnvironmentKey: program,
                sessionEnvironmentKey: id,
                homeEnvironmentKey: home,
            ],
            home: home
        )
    }

    /// Environment for a plan step. The session id does not exist yet, so the
    /// daemon creates the home when it assigns one. No home is created here.
    public static func pendingEnvironment(installation: Installation) -> [String: String]? {
        let program = installation.binary.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = installation.root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !program.isEmpty, root.hasPrefix("/") else { return nil }
        return [
            binaryEnvironmentKey: program,
            rootEnvironmentKey: root,
        ]
    }

    public static func homeDirectory(root: String, sessionID: String) -> String? {
        let id = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeComponent(id) else { return nil }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let home = rootURL.appendingPathComponent(id, isDirectory: true).standardizedFileURL
        guard home.deletingLastPathComponent().path == rootURL.path else { return nil }
        return home.path
    }

    /// Creates the session directory at mode 0700. Refuses a symlink.
    public static func prepareHome(at path: String) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Removes one session directory. A symlink, a missing directory, or a path
    /// outside `root` is left alone.
    public static func removeHome(sessionID: String, root: String) {
        guard let home = homeDirectory(root: root, sessionID: sessionID) else { return }
        let url = URL(fileURLWithPath: home, isDirectory: true)
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isSymbolicLink != true, values?.isDirectory == true else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes state directories whose session is no longer in the daemon.
    public static func pruneHomes(root: String, keeping sessionIDs: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for name in names where !sessionIDs.contains(name) {
            removeHome(sessionID: name, root: root)
        }
    }

    /// Check arguments. `guide` opens the upstream walkthrough and does not prompt.
    /// Screen Recording is never requested: there is no `--request` and no screenshot.
    public static func permissionArguments(guide: Bool) -> [String] {
        guide ? ["permissions", "--guide"] : ["permissions"]
    }

    public static func parsePermissions(_ data: Data) -> Permissions? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true,
              let payload = json["data"] as? [String: Any],
              let accessibility = payload["accessibility"] as? [String: Any],
              let state = accessibility["state"] as? String
        else { return nil }
        return Permissions(
            accessibilityDenied: state == "denied",
            guide: payload["guide"] as? String
        )
    }

    /// Names the app the guide tells the user to enable. That app is the one
    /// that launched `agent-desktop`.
    public static func accessibilityNotice(appName: String, guide: String?) -> Notice {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = trimmed.isEmpty ? "Fleet" : trimmed
        let detail: String
        switch guide {
        case "started", "already_running":
            detail = "System Settings is open. Turn on \(app). This session is still running."
        default:
            detail = "Turn on \(app) in System Settings, Privacy & Security, Accessibility. This session is still running."
        }
        return Notice(title: "\(app) needs Accessibility.", detail: detail)
    }

    private static func isSafeComponent(_ id: String) -> Bool {
        guard !id.isEmpty, id != ".", id != ".." else { return false }
        return !id.contains("/") && !id.contains("\0")
    }
}
