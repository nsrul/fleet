import Foundation

/// Runs `agent-desktop` and keeps its stdout in this process.
/// Nothing from the command is written to the daemon log.
enum AgentDesktopCommand {
    static func output(binary: String, arguments: [String]) async -> Data? {
        await Task.detached(priority: .utility) {
            run(binary: binary, arguments: arguments)
        }.value
    }

    private static func run(binary: String, arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            return nil
        }
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        return stdout.fileHandleForReading.readDataToEndOfFile()
    }
}
