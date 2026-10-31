import Darwin
import FleetAPI
import Foundation

@main
struct FleetProbe {
    static func main() async {
        do {
            let options = try Options.parse(CommandLine.arguments.dropFirst())
            if options.help {
                print(Options.usage)
                return
            }
            try await run(options)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            FileHandle.standardError.write(Data("fleet-probe: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ options: Options) async throws {
        let client: FleetClient
        do {
            client = try FleetClient(path: options.socketPath)
        } catch {
            throw ProbeError.message(
                "could not connect to \(options.socketPath). Is fleet-daemon running?\n\(error.localizedDescription)"
            )
        }

        let welcome = try await client.connect(clientName: "fleet-probe")
        print("connected: daemon \(welcome.daemonVersion), protocol \(welcome.protocolVersion)")

        let store = OutputStore()
        let eventTask = Task {
            for await event in client.events {
                switch event {
                case .output(let sessionID, _, let data):
                    await store.append(data, for: sessionID)
                case .status(let sessionID, let status):
                    await store.setStatus(status, for: sessionID)
                case .daemonStopping:
                    await store.markDaemonStopping()
                }
            }
        }
        defer { eventTask.cancel() }

        if options.list {
            let sessions = try await client.listSessions()
            if sessions.isEmpty {
                print("no sessions")
            }
            for session in sessions {
                print(format(session))
            }
            await client.disconnect()
            return
        }

        if !options.stops.isEmpty {
            for id in options.stops {
                let exit = try await client.stopSession(id: id)
                print("stopped: \(id) success=\(exit.success) code=\(exit.code)")
            }
            await client.disconnect()
            return
        }

        let existing = try await client.listSessions()
        let sessions: [SessionInfo]

        if options.noCreate {
            let ids = options.ids.isEmpty ? Array(existing.prefix(2)).map(\.id) : options.ids
            guard !ids.isEmpty else {
                throw ProbeError.message("no sessions exist and --no-create was supplied")
            }
            sessions = try await withThrowingTaskGroup(of: SessionInfo.self) { group in
                for id in ids {
                    group.addTask { try await client.inspectSession(id: id) }
                }
                var result: [SessionInfo] = []
                for try await session in group {
                    result.append(session)
                }
                return result
            }
        } else {
            let programs = options.programs.isEmpty ? ["/bin/sh"] : options.programs
            var created: [SessionInfo] = []
            for (index, program) in programs.enumerated() {
                let baseID = options.ids.indices.contains(index)
                    ? options.ids[index]
                    : defaultID(program: program, index: index, existing: existing + created)
                let id = uniqueID(baseID, existing: existing + created)
                let spec = CreateSession(
                    id: id,
                    program: program,
                    cwd: options.cwd,
                    size: TerminalSize(rows: 24, cols: 80)
                )
                let session = try await client.createSession(spec)
                created.append(session)
                print("created: \(format(session))")
            }
            sessions = created
        }

        if options.keep {
            for session in sessions {
                let attached = try await client.attachSession(id: session.id)
                await store.append(attached.output.data, for: session.id)
                let length = await store.snapshotLength(for: session.id)
                print("attached: \(session.id) pid=\(session.pid.map(String.init) ?? "-") snapshot=\(length)B")
            }
            for session in sessions {
                try? await client.detachSession(id: session.id)
            }
            print("")
            print("sessions left running:")
            for session in sessions {
                print("  \(session.id)\t\(session.program)\t\(session.cwd)")
            }
            print("open the Fleet app to attach.")
            await client.disconnect()
            return
        }

        if options.smoke {
            try await runSmoke(client: client, store: store, sessions: sessions, timeout: options.timeout)
            await client.disconnect()
            return
        }

        for session in sessions {
            let attached = try await client.attachSession(id: session.id)
            await store.append(attached.output.data, for: session.id)
            print("attached: \(session.id) snapshot=\(attached.output.data.count)B")
            try? await client.detachSession(id: session.id)
        }
        await client.disconnect()
    }

    private static func runSmoke(
        client: FleetClient,
        store: OutputStore,
        sessions: [SessionInfo],
        timeout: TimeInterval
    ) async throws {
        for session in sessions {
            let attached = try await client.attachSession(id: session.id)
            await store.append(attached.output.data, for: session.id)

            try await client.input(
                id: session.id,
                data: Data("printf 'FLEET_%s\\n' \"$((40+2))\"\n".utf8)
            )
            try await store.waitFor("FLEET_42", sessionID: session.id, timeout: timeout)
            print("PASS input/output: \(session.id)")

            try await client.input(
                id: session.id,
                data: Data("printf 'caf\\303\\251 \\346\\227\\245\\346\\234\\254\\350\\252\\236\\n'\n".utf8)
            )
            try await store.waitFor("café 日本語", sessionID: session.id, timeout: timeout)
            print("PASS unicode: \(session.id)")

            try await client.resize(id: session.id, size: TerminalSize(rows: 30, cols: 100))
            try await client.input(id: session.id, data: Data("stty size\n".utf8))
            try await store.waitFor("30 100", sessionID: session.id, timeout: timeout)
            print("PASS resize: \(session.id)")

            try await client.input(id: session.id, data: Data("exit\n".utf8))
            let exit = try await store.waitForExit(sessionID: session.id, timeout: timeout)
            guard exit.success else {
                throw ProbeError.failed("session \(session.id) exited with \(exit.code)")
            }
            print("PASS exit: \(session.id)")
        }
        print("PASS all")
    }

    private static func defaultID(program: String, index: Int, existing: [SessionInfo]) -> String {
        let base = (program as NSString).lastPathComponent
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        let candidate = base.isEmpty ? "agent-\(index + 1)" : base
        return uniqueID(candidate, existing: existing)
    }

    private static func uniqueID(_ base: String, existing: [SessionInfo]) -> String {
        let used = Set(existing.map(\.id))
        if !used.contains(base) { return base }
        var suffix = 2
        while used.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    private static func format(_ session: SessionInfo) -> String {
        let pid = session.pid.map(String.init) ?? "-"
        let state: String
        switch session.status {
        case .running:
            state = "running"
        case .exited(let exit):
            state = "exited(\(exit.code))"
        }
        return "\(session.id)\t\(session.program)\tpid=\(pid)\t\(state)\t\(session.cwd)"
    }
}

private struct Options {
    var socketPath = FleetPaths.defaultSocketPath
    var cwd = FileManager.default.currentDirectoryPath
    var programs: [String] = []
    var ids: [String] = []
    var stops: [String] = []
    var keep = false
    var noCreate = false
    var smoke = false
    var list = false
    var help = false
    var timeout: TimeInterval = 10

    static let usage = """
    Usage: fleet-probe [options]

      --socket <path>     daemon socket (default: \(FleetPaths.defaultSocketPath))
      --cwd <path>        working directory for created sessions
      --program <path>    program to launch; repeat for two sessions (default: /bin/sh)
      --id <id>           session id; repeat to match programs
      --stop <id>         stop a session and exit; repeat for several
      --smoke             run input, Unicode, resize, and exit checks (shells)
      --keep              create sessions, attach briefly, and leave them running
      --no-create         attach to existing sessions instead of creating
      --list              list sessions and exit
      --timeout <seconds> per-operation timeout (default: 10)
      --help              show this help
    """

    static func parse(_ arguments: some Sequence<String>) throws -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()

        func value(for flag: String) throws -> String {
            guard let value = iterator.next() else {
                throw ProbeError.message("\(flag) requires a value")
            }
            return value
        }

        while let argument = iterator.next() {
            switch argument {
            case "--socket":
                options.socketPath = try value(for: argument)
            case "--cwd":
                options.cwd = try value(for: argument)
            case "--program":
                options.programs.append(try value(for: argument))
            case "--id":
                options.ids.append(try value(for: argument))
            case "--stop":
                options.stops.append(try value(for: argument))
            case "--timeout":
                let raw = try value(for: argument)
                guard let timeout = TimeInterval(raw), timeout > 0 else {
                    throw ProbeError.message("--timeout must be a positive number")
                }
                options.timeout = timeout
            case "--keep":
                options.keep = true
            case "--no-create":
                options.noCreate = true
            case "--smoke":
                options.smoke = true
            case "--list":
                options.list = true
            case "--help", "-h":
                options.help = true
            default:
                throw ProbeError.message("unknown argument \(argument); use --help")
            }
        }

        options.socketPath = NSString(string: options.socketPath).expandingTildeInPath
        options.cwd = NSString(string: options.cwd).expandingTildeInPath
        if options.keep && options.smoke {
            throw ProbeError.message("--keep and --smoke are mutually exclusive")
        }
        return options
    }
}

private actor OutputStore {
    private var buffers: [String: Data] = [:]
    private var statuses: [String: SessionStatus] = [:]
    private var daemonStopping = false

    func append(_ data: Data, for sessionID: String) {
        buffers[sessionID, default: Data()].append(data)
    }

    func setStatus(_ status: SessionStatus, for sessionID: String) {
        statuses[sessionID] = status
    }

    func markDaemonStopping() {
        daemonStopping = true
    }

    func snapshotLength(for sessionID: String) -> Int {
        buffers[sessionID]?.count ?? 0
    }

    func waitFor(_ marker: String, sessionID: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = buffers[sessionID],
               String(decoding: data, as: UTF8.self).contains(marker) {
                return
            }
            if daemonStopping {
                throw ProbeError.failed("daemon stopped while waiting for \(marker)")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let tail = buffers[sessionID].map { String(decoding: $0.suffix(500), as: UTF8.self) } ?? ""
        throw ProbeError.timeout(
            "waiting for \(marker) in \(sessionID); recent output:\n\(tail)"
        )
    }

    func waitForExit(sessionID: String, timeout: TimeInterval) async throws -> SessionExit {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .exited(let exit)? = statuses[sessionID] {
                return exit
            }
            if daemonStopping {
                throw ProbeError.failed("daemon stopped while waiting for \(sessionID) to exit")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ProbeError.timeout("waiting for \(sessionID) to exit")
    }
}

private enum ProbeError: Error, LocalizedError {
    case message(String)
    case timeout(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .message(let message), .timeout(let message), .failed(let message):
            return message
        }
    }
}
