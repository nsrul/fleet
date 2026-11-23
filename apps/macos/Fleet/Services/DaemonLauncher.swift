import Darwin
import FleetAPI
import Foundation

/// Starts the Rust daemon when the app was built with a bundled or local binary.
@MainActor
enum DaemonLauncher {
    private static var runningProcess: Process?

    static func locate() -> String? {
        var candidates: [String] = []

        if let override = ProcessInfo.processInfo.environment["FLEET_DAEMON"], !override.isEmpty {
            candidates.append(NSString(string: override).expandingTildeInPath)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("fleet-daemon").path)
        }

        let cwd = FileManager.default.currentDirectoryPath
        candidates.append(contentsOf: [
            (cwd as NSString).appendingPathComponent("target/debug/fleet-daemon"),
            (cwd as NSString).appendingPathComponent("target/release/fleet-daemon"),
            "\(NSHomeDirectory())/.fleet/bin/fleet-daemon",
            "/opt/homebrew/bin/fleet-daemon",
            "/usr/local/bin/fleet-daemon",
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
            .appendingPathComponent("Library/Logs/Fleet", isDirectory: true)
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

    /// What to do with a daemon that is already listening on `socketPath`.
    static func handoff(executable: String, socketPath: String) async -> DaemonHandoff {
        let launchFingerprint = DaemonFingerprint.ofFile(at: executable)
        guard !launchFingerprint.isEmpty else { return .keep }

        let client: FleetClient
        do {
            client = try FleetClient(path: socketPath)
        } catch {
            return .absent
        }
        let pid = client.peerProcessID()
        let welcome: Welcome
        do {
            welcome = try await client.connect(clientName: "fleet-macos")
        } catch {
            await client.disconnect()
            return .keep
        }
        let stale = DaemonReplacement.shouldReplace(
            reportedFingerprint: welcome.executableFingerprint,
            launchFingerprint: launchFingerprint
        )
        await client.disconnect()
        guard stale else { return .keep }
        guard let pid, let path = executablePath(pid: pid), isFleetDaemon(path), isRunning(pid) else {
            return .unsafe
        }
        return .replace(pid)
    }

    /// Asks `pid` to exit, then removes a socket it left behind.
    ///
    /// The signal is sent only when that process's executable is `fleet-daemon`.
    static func stop(pid: pid_t, socketPath: String) async throws {
        guard pid > 1, let path = executablePath(pid: pid), isFleetDaemon(path) else {
            throw DaemonLaunchError.refusedToExit
        }
        if kill(pid, SIGTERM) != 0 {
            if errno == ESRCH {
                await retireSocket(socketPath)
                return
            }
            throw DaemonLaunchError.refusedToExit
        }
        if await waitUntilExited(pid, timeout: 8) {
            await retireSocket(socketPath)
            return
        }
        // The pid may have been reused after a quick exit. Signal again only
        // when it is still this daemon.
        guard let path = executablePath(pid: pid), isFleetDaemon(path) else {
            await retireSocket(socketPath)
            return
        }
        _ = kill(pid, SIGKILL)
        guard await waitUntilExited(pid, timeout: 2) else {
            throw DaemonLaunchError.refusedToExit
        }
        await retireSocket(socketPath)
    }

    private static func isFleetDaemon(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == "fleet-daemon"
    }

    private static func executablePath(pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        let capacity = Int(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: capacity)
        let length = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return 0 }
            return proc_pidpath(pid, base, UInt32(capacity))
        }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func isRunning(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private static func waitUntilExited(_ pid: pid_t, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning(pid) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !isRunning(pid)
    }

    /// The daemon unlinks its socket on a clean exit. A forced stop can leave
    /// the file. Remove it only when nothing is accepting connections.
    private static func retireSocket(_ path: String) async {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: path) { return }
            if socketAccepts(path) {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            break
        }
        guard !socketAccepts(path) else { return }
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else { return }
        unlink(path)
    }

    private static func socketAccepts(_ path: String) -> Bool {
        guard let socket = try? UnixSocket.connect(path: path) else { return false }
        socket.close()
        return true
    }
}

enum DaemonHandoff: Equatable {
    /// The listening daemon is the executable this app would start.
    case keep
    /// Nothing is accepting connections on the socket.
    case absent
    /// `pid` is a `fleet-daemon` from a different executable.
    case replace(pid_t)
    /// The listener should be replaced, but its process could not be confirmed.
    case unsafe
}

enum DaemonLaunchError: Error, LocalizedError {
    case exited(code: Int32, log: String)
    case timedOut(log: String)
    case refusedToExit

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
        case .refusedToExit:
            return UserNotice(
                "The previous daemon did not exit.",
                detail: "This version could not take over the socket. Quit fleet-daemon and open Fleet again."
            )
        }
    }

    var errorDescription: String? { notice.paragraph }
}
