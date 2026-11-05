import Darwin
import Foundation

/// Arguments Fleet should pass when it starts Codex, plus a toast when the
/// managed app-server had to be recovered.
struct CodexLaunch: Equatable, Sendable {
    var arguments: [String]
    var notice: String?
}

/// Codex keeps its control socket as a symlink under `~/.codex` whose target
/// lives in `/private/tmp/codex-daemon-<uid>/`. macOS removes stale `/private/tmp`
/// entries, the symlink dangles, and the daemon process stays up, so every new
/// `codex` waits about 30 seconds and then exits. A missing socket is different:
/// Codex creates the daemon itself on first launch.
enum CodexControlSocket {
    static let restartedNotice = "Codex lost its control socket. Fleet restarted the app-server."
    static let fallbackNotice = "Codex lost its control socket. This session is starting with --no-daemon."

    private static let readyPollInterval: TimeInterval = 0.05
    private static let restartTimeout: TimeInterval = 20

    static func adjustForLaunch(program: String, arguments: [String]) async -> CodexLaunch {
        await adjust(
            program: program,
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: NSHomeDirectory(),
            readyTimeout: 5,
            restart: nil
        )
    }

    static func adjust(
        program: String,
        arguments: [String],
        environment: [String: String],
        homeDirectory: String,
        readyTimeout: TimeInterval,
        restart: (@Sendable (String) async -> Bool)?
    ) async -> CodexLaunch {
        let socket = socketPath(environment: environment, homeDirectory: homeDirectory)
        guard shouldRecover(program: program, arguments: arguments, state: state(at: socket)) else {
            return CodexLaunch(arguments: arguments, notice: nil)
        }

        let restarted: Bool
        if let restart {
            restarted = await restart(program)
        } else {
            restarted = await RestartGate.shared.run {
                await restartManagedDaemon(program)
            }
        }

        if restarted, await waitUntilReady(socket, timeout: readyTimeout) {
            return CodexLaunch(arguments: arguments, notice: restartedNotice)
        }

        var fallback = arguments
        if !fallback.contains("--no-daemon") {
            fallback.insert("--no-daemon", at: 0)
        }
        return CodexLaunch(arguments: fallback, notice: fallbackNotice)
    }

    static func socketPath(environment: [String: String], homeDirectory: String) -> String {
        let root: String
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            root = (codexHome as NSString).expandingTildeInPath
        } else {
            root = (homeDirectory as NSString).appendingPathComponent(".codex")
        }
        return (root as NSString).appendingPathComponent("app-server-control/app-server-control.sock")
    }

    /// `.missing` when nothing is at `path`. `.dangling` when `path` is a symlink
    /// whose target is gone. Anything else is left alone.
    static func state(at path: String) -> CodexSocketState {
        let kind = path.withCString { pointer -> CodexSocketKind? in
            var info = stat()
            if lstat(pointer, &info) != 0 {
                return nil
            }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                return .symlink
            }
            return .other
        }
        switch kind {
        case nil:
            return .missing
        case .other:
            return .ready
        case .symlink:
            let targetMissing = path.withCString { pointer -> Bool in
                if access(pointer, F_OK) == 0 {
                    return false
                }
                return errno == ENOENT
            }
            return targetMissing ? .dangling : .ready
        }
    }

    private static func shouldRecover(
        program: String,
        arguments: [String],
        state: CodexSocketState
    ) -> Bool {
        guard state == .dangling else { return false }
        guard (program as NSString).lastPathComponent == "codex" else { return false }
        return !arguments.contains("--no-daemon")
    }

    private static func waitUntilReady(_ path: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if state(at: path) == .ready {
                return true
            }
            if Date() >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: UInt64(readyPollInterval * 1_000_000_000))
        }
    }

    private static func restartManagedDaemon(_ program: String) async -> Bool {
        let status = await run(
            program: program,
            arguments: ["app-server", "daemon", "restart"],
            timeout: restartTimeout
        )
        return status == 0
    }

    /// Runs `program` off the main thread. A timeout terminates it so a stuck
    /// restart cannot sit for the same 30 seconds Codex would.
    private static func run(program: String, arguments: [String], timeout: TimeInterval) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(program: program, arguments: arguments, timeout: timeout))
            }
        }
    }

    private static func runSync(program: String, arguments: [String], timeout: TimeInterval) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: readyPollInterval)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: readyPollInterval)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            return -1
        }
        return process.terminationStatus
    }
}

enum CodexSocketState: Equatable, Sendable {
    case missing
    case ready
    case dangling
}

private enum CodexSocketKind {
    case symlink
    case other
}

/// Overlapping Codex launches share one restart. The actor suspends at the
/// task, so a second caller observes `current` and waits for the same result.
private actor RestartGate {
    static let shared = RestartGate()
    private var current: Task<Bool, Never>?

    func run(_ body: @escaping @Sendable () async -> Bool) async -> Bool {
        if let current {
            return await current.value
        }
        let task = Task { await body() }
        current = task
        let value = await task.value
        current = nil
        return value
    }
}
