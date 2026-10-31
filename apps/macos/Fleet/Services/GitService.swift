import Foundation

struct GitChange: Identifiable, Equatable, Sendable {
    let path: String
    let status: String
    var added: Int?
    var deleted: Int?

    var id: String { path + status }

    var diffLabel: String? {
        guard let added, let deleted, added + deleted > 0 else { return nil }
        return "+\(added) −\(deleted)"
    }

    var label: String {
        switch status {
        case "??": return "U"
        case "A": return "A"
        case "D": return "D"
        case "R": return "R"
        case "C": return "C"
        case "M": return "M"
        default: return status
        }
    }

    var isUntracked: Bool { status == "??" }
}

struct GitFileDiff: Equatable, Sendable {
    var text: String
    var truncated: Bool
    var binary: Bool

    static let empty = GitFileDiff(text: "", truncated: false, binary: false)
}

struct GitSnapshot: Equatable, Sendable {
    var cwd: String
    var branch: String?
    var baseBranch: String?
    var changes: [GitChange] = []
    var remoteURL: URL?
    var error: String?

    var isRepository: Bool { error == nil }
    var isClean: Bool { changes.isEmpty }

    var additions: Int {
        changes.compactMap(\.added).reduce(0, +)
    }

    var deletions: Int {
        changes.compactMap(\.deleted).reduce(0, +)
    }

    var diffSummary: String? {
        guard additions + deletions > 0 else { return nil }
        return "+\(additions) −\(deletions)"
    }

    var summary: String {
        if let error {
            return error
        }
        guard let branch else {
            return "no branch"
        }
        if !isClean {
            return changes.count == 1 ? "1 changed file" : "\(changes.count) changed files"
        }
        let base = baseBranch ?? "main"
        if branch == base {
            return "on \(branch) · clean"
        }
        return "from \(base) · clean"
    }

    static func unavailable(cwd: String, message: String) -> GitSnapshot {
        GitSnapshot(cwd: cwd, error: message)
    }
}

enum GitService {
    /// Reads branch, base branch, origin, and porcelain status for a directory.
    ///
    /// This runs `git` as a child process and must be called off the main actor.
    static func snapshot(cwd: String) -> GitSnapshot {
        guard FileManager.default.fileExists(atPath: cwd) else {
            return .unavailable(cwd: cwd, message: "directory not found")
        }

        let status = runGit(["-C", cwd, "status", "--porcelain=v1", "-b"])
        guard status.exitCode == 0 else {
            let message = status.stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n")
                .last
                .map(String.init) ?? "not a git repository"
            return .unavailable(cwd: cwd, message: message)
        }

        let remote = runGit(["-C", cwd, "remote", "get-url", "origin"])
        let remoteURL = remote.exitCode == 0
            ? webURL(from: remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil

        var stats: [String: (added: Int, deleted: Int)] = [:]
        for arguments in [
            ["-C", cwd, "diff", "--numstat"],
            ["-C", cwd, "diff", "--cached", "--numstat"],
        ] {
            let result = runGit(arguments)
            guard result.exitCode == 0 else { continue }
            for line in result.stdout.split(separator: "\n") {
                let fields = line.split(separator: "\t", maxSplits: 2)
                guard fields.count == 3,
                      let added = Int(fields[0]),
                      let deleted = Int(fields[1]) else { continue }
                stats[String(fields[2])] = (added, deleted)
            }
        }

        return parse(status: status.stdout, cwd: cwd, remoteURL: remoteURL, stats: stats)
    }

    /// Unified diff for one path. Exit code 1 from git means the file differs.
    ///
    /// Tracked files prefer the working tree, then the index. Untracked files
    /// diff against `/dev/null`. Output is capped at 400 lines.
    static func diff(cwd: String, path: String, status: String) -> GitFileDiff {
        if status.contains("?") {
            return format(runGit([
                "-C", cwd, "diff", "--no-color", "--no-index", "--", "/dev/null", path,
            ]))
        }

        let working = runGit(["-C", cwd, "diff", "--no-color", "--", path])
        let workingDiff = format(working)
        if working.exitCode == 0 || working.exitCode == 1 {
            if workingDiff.binary || !workingDiff.text.isEmpty {
                return workingDiff
            }
            return format(runGit(["-C", cwd, "diff", "--no-color", "--cached", "--", path]))
        }
        return workingDiff
    }

    static func parse(
        status: String,
        cwd: String,
        remoteURL: URL?,
        stats: [String: (added: Int, deleted: Int)] = [:]
    ) -> GitSnapshot {
        var snapshot = GitSnapshot(cwd: cwd, remoteURL: remoteURL)
        var sawHeader = false

        for rawLine in status.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("## ") {
                sawHeader = true
                let header = String(line.dropFirst(3))
                snapshot.branch = branchName(from: header)
                snapshot.baseBranch = baseBranch(from: header)
                continue
            }
            guard line.count >= 3 else { continue }
            let statusCode = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let range = path.range(of: " -> ") {
                path = String(path[range.upperBound...])
            }
            let normalized = statusCode.replacingOccurrences(of: " ", with: "")
            let fileStats = stats[path]
            snapshot.changes.append(
                GitChange(
                    path: path,
                    status: normalized.isEmpty ? "M" : normalized,
                    added: fileStats?.added,
                    deleted: fileStats?.deleted
                )
            )
        }

        if !sawHeader {
            snapshot.error = "not a git repository"
        }
        snapshot.changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return snapshot
    }

    private static func branchName(from header: String) -> String? {
        var value = header
        if let range = value.range(of: "...") {
            value = String(value[..<range.lowerBound])
        } else if value.hasPrefix("No commits yet on ") {
            value = String(value.dropFirst("No commits yet on ".count))
        } else if let space = value.firstIndex(of: " ") {
            value = String(value[..<space])
        }
        if value == "HEAD" || value.hasPrefix("HEAD ") { return nil }
        return value.isEmpty ? nil : value
    }

    private static func baseBranch(from header: String) -> String? {
        guard let range = header.range(of: "...") else { return nil }
        var value = String(header[range.upperBound...])
        if let space = value.firstIndex(of: " ") {
            value = String(value[..<space])
        }
        if value.hasPrefix("origin/") {
            value = String(value.dropFirst("origin/".count))
        }
        return value.isEmpty ? nil : value
    }

    private static func webURL(from remote: String) -> URL? {
        guard !remote.isEmpty else { return nil }
        var value = remote
        if value.hasSuffix(".git") {
            value.removeLast(4)
        }

        if !value.contains("://"), let colon = value.firstIndex(of: ":"),
           let at = value.firstIndex(of: "@"), at < colon {
            let host = String(value[value.index(after: at)..<colon])
            let path = String(value[value.index(after: colon)...])
            value = "https://\(host)/\(path)"
        } else if value.hasPrefix("ssh://git@") {
            value = "https://" + value.dropFirst("ssh://git@".count)
        }

        guard let url = URL(string: value), url.host != nil else { return nil }
        return url
    }

    private static let diffLineCap = 400

    private static func format(
        _ result: (exitCode: Int32, stdout: String, stderr: String)
    ) -> GitFileDiff {
        guard result.exitCode == 0 || result.exitCode == 1 else {
            return GitFileDiff(text: "unavailable", truncated: false, binary: false)
        }
        let output = result.stdout
        if output.contains("Binary files ") || output.contains("GIT binary patch") {
            return GitFileDiff(text: "binary", truncated: false, binary: true)
        }
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard lines.count > diffLineCap else {
            return GitFileDiff(text: lines.joined(separator: "\n"), truncated: false, binary: false)
        }
        var kept = Array(lines.prefix(diffLineCap - 1))
        kept.append("truncated")
        return GitFileDiff(text: kept.joined(separator: "\n"), truncated: true, binary: false)
    }

    private static func runGit(_ arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(decoding: outputData, as: UTF8.self),
            String(decoding: errorData, as: UTF8.self)
        )
    }
}

/// Which working-tree path the context panel should show.
enum ChangeFollow {
    /// While following, the path whose status or line counts changed the most.
    /// While pinned, the current path when it is still in the tree.
    static func selection(
        previous: [GitChange],
        next: [GitChange],
        selected: String?,
        following: Bool
    ) -> String? {
        if !following {
            guard let selected, next.contains(where: { $0.path == selected }) else { return nil }
            return selected
        }

        var prior: [String: GitChange] = [:]
        prior.reserveCapacity(previous.count)
        for change in previous {
            prior[change.path] = change
        }

        var bestPath: String?
        var bestDelta = -1
        for change in next {
            let old = prior[change.path]
            let changed = old == nil
                || old?.status != change.status
                || old?.added != change.added
                || old?.deleted != change.deleted
            guard changed else { continue }
            let delta = (change.added ?? 0) + (change.deleted ?? 0)
            if delta > bestDelta {
                bestDelta = delta
                bestPath = change.path
            }
        }
        if let bestPath { return bestPath }
        if let selected, next.contains(where: { $0.path == selected }) { return selected }
        return next.first?.path
    }
}
