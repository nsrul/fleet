import Foundation

/// Starts the Rust daemon when the app was built with a bundled or local binary.
@MainActor
enum DaemonLauncher {
    private static var runningProcess: Process?

    static func locate() -> String? {
        var candidates: [String] = []

        if let override = ProcessInfo.processInfo.environment["DIRECTOR_DAEMON"], !override.isEmpty {
            candidates.append(NSString(string: override).expandingTildeInPath)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("director-daemon").path)
        }

        let cwd = FileManager.default.currentDirectoryPath
        candidates.append(contentsOf: [
            (cwd as NSString).appendingPathComponent("target/debug/director-daemon"),
            (cwd as NSString).appendingPathComponent("target/release/director-daemon"),
            "\(NSHomeDirectory())/.director/bin/director-daemon",
            "/opt/homebrew/bin/director-daemon",
            "/usr/local/bin/director-daemon",
        ])

        return candidates.first(where: AgentCatalog.isExecutable)
    }

    static func start(executable: String, socketPath: String) async throws {
        let socketURL = URL(fileURLWithPath: socketPath)
        let parent = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let logDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Director", isDirectory: true)
        try FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        let logURL = logDirectory.appendingPathComponent("daemon.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--socket", socketPath]
        process.standardInput = FileHandle.nullDevice

        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()
        process.standardOutput = logHandle
        process.standardError = logHandle

        try process.run()
        runningProcess = process

        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if !process.isRunning {
                throw DaemonLaunchError.exited(code: process.terminationStatus, log: logURL.path)
            }
            if FileManager.default.fileExists(atPath: socketPath) {
                // The socket appears just before the listener accepts. A short
                // settle avoids a connect that races the bind completing.
                try await Task.sleep(for: .milliseconds(80))
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        throw DaemonLaunchError.timedOut(log: logURL.path)
    }
}

enum DaemonLaunchError: Error, LocalizedError {
    case exited(code: Int32, log: String)
    case timedOut(log: String)

    var notice: UserNotice {
        switch self {
        case .exited(let code, let log):
            return UserNotice(
                "The daemon quit while starting.",
                detail: "It exited with code \(code). The log is \(AgentNotices.displayPath(log))."
            )
        case .timedOut(let log):
            return UserNotice(
                "The daemon did not become ready.",
                detail: "It did not open its socket in time. The log is \(AgentNotices.displayPath(log))."
            )
        }
    }

    var errorDescription: String? { notice.paragraph }
}
