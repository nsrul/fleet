import AppKit
import FleetAPI
import Foundation
import SwiftUI

/// Sizes the screenshot window without writing over the frame Fleet restores
/// for a normal launch.
struct PreviewWindowFrame: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SizerView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SizerView)?.schedule()
    }

    /// Applies the screenshot frame after SwiftUI restores the saved window size.
    final class SizerView: NSView {
        private var attempts = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule()
        }

        func schedule() {
            guard window != nil, attempts == 0 else { return }
            attempts = 1
            for delay in [0.0, 0.2, 0.6, 1.2] {
                perform(#selector(applyFrame), with: nil, afterDelay: delay)
            }
        }

        @objc private func applyFrame() {
            guard let window else { return }
            window.setFrameAutosaveName("FleetPreview")
            window.isRestorable = false
            let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            guard screen.width > 400, screen.height > 400 else { return }
            let size = NSSize(
                width: min(1520, screen.width - 32),
                height: min(980, screen.height - 32)
            )
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin.x = screen.midX - frame.width / 2
            frame.origin.y = screen.midY - frame.height / 2
            window.setFrame(frame, display: true)
        }
    }
}

/// Static workspace used by `scripts/preview.sh` so a screenshot can be taken
/// without starting the daemon or any agent process.
enum ClaudePreview {
    struct Fixture {
        var sessions: [SessionInfo]
        var names: [String: String]
        var focusID: String
        var activeIDs: Set<String>
        var attentionIDs: Set<String>
    }

    private struct Agent {
        var id: String
        var name: String
        var directory: String
        var suggestion: String
        var status: SessionStatus
        var active: Bool = false
        var needsYou: Bool = false
    }

    private static let home = NSHomeDirectory()

    private static let agents: [Agent] = [
        Agent(
            id: "fleet-01-preview",
            name: "Preview screenshots",
            directory: "\(home)/Desktop/fleet",
            suggestion: "add a screenshot preview",
            status: .running,
            active: true
        ),
        Agent(
            id: "fleet-02-sidebar",
            name: "Sidebar groups",
            directory: "\(home)/Desktop/fleet",
            suggestion: "group agents by folder",
            status: .running
        ),
        Agent(
            id: "fleet-03-scrollback",
            name: "Terminal scrollback",
            directory: "\(home)/Desktop/fleet",
            suggestion: "keep scrollback when a pane moves",
            status: .running
        ),
        Agent(
            id: "fleet-04-context",
            name: "Context diff",
            directory: "\(home)/Desktop/fleet",
            suggestion: "follow the latest edited file",
            status: .running
        ),
        Agent(
            id: "fleet-05-settings",
            name: "Settings window",
            directory: "\(home)/Desktop/fleet",
            suggestion: "open settings with command comma",
            status: .running
        ),
        Agent(
            id: "fleet-06-daemon",
            name: "Daemon lifecycle",
            directory: "\(home)/Desktop/fleet",
            suggestion: "leave sessions running when the window closes",
            status: .exited(SessionExit(success: true, code: 0))
        ),
        Agent(
            id: "locus-01-search",
            name: "Place search",
            directory: "\(home)/Desktop/Personal/locus",
            suggestion: "search places as you type",
            status: .running,
            active: true
        ),
        Agent(
            id: "locus-02-tiles",
            name: "Offline tiles",
            directory: "\(home)/Desktop/Personal/locus",
            suggestion: "cache map tiles for offline use",
            status: .running
        ),
        Agent(
            id: "locus-03-gestures",
            name: "Map gestures",
            directory: "\(home)/Desktop/Personal/locus",
            suggestion: "fix the pinch zoom jump",
            status: .exited(SessionExit(success: true, code: 0))
        ),
        Agent(
            id: "momentum-01-streaks",
            name: "Habit streaks",
            directory: "\(home)/Desktop/Personal/momentum",
            suggestion: "count a streak across midnight",
            status: .running
        ),
        Agent(
            id: "momentum-02-chart",
            name: "Week chart",
            directory: "\(home)/Desktop/Personal/momentum",
            suggestion: "draw the week as a bar chart",
            status: .running
        ),
        Agent(
            id: "momentum-03-copy",
            name: "Notification copy",
            directory: "\(home)/Desktop/Personal/momentum",
            suggestion: "shorten the reminder text",
            status: .exited(SessionExit(success: false, code: 1)),
            needsYou: true
        ),
        Agent(
            id: "momentum-04-onboarding",
            name: "Onboarding",
            directory: "\(home)/Desktop/Personal/momentum",
            suggestion: "skip onboarding on a second launch",
            status: .running
        ),
        Agent(
            id: "pettoo-01-booking",
            name: "Booking API",
            directory: "\(home)/Desktop/Freelance/pettoo",
            suggestion: "add a cancel endpoint",
            status: .running,
            active: true
        ),
        Agent(
            id: "pettoo-02-photos",
            name: "Photo upload",
            directory: "\(home)/Desktop/Freelance/pettoo",
            suggestion: "resize photos before upload",
            status: .running,
            needsYou: true
        ),
        Agent(
            id: "pettoo-03-map",
            name: "Walker map",
            directory: "\(home)/Desktop/Freelance/pettoo",
            suggestion: "show walkers near the booking",
            status: .running
        ),
        Agent(
            id: "pettoo-04-profile",
            name: "Profile edit",
            directory: "\(home)/Desktop/Freelance/pettoo",
            suggestion: "validate the phone field",
            status: .running
        ),
        Agent(
            id: "trace-01-timeline",
            name: "Player timeline",
            directory: "\(home)/Desktop/Personal/trace",
            suggestion: "scrub the timeline while audio plays",
            status: .running,
            active: true
        ),
        Agent(
            id: "trace-02-export",
            name: "Clip export",
            directory: "\(home)/Desktop/Personal/trace",
            suggestion: "export a clip without re-encoding",
            status: .running
        ),
        Agent(
            id: "trace-03-waveform",
            name: "Waveform cache",
            directory: "\(home)/Desktop/Personal/trace",
            suggestion: "cache the waveform for a file",
            status: .running
        ),
        Agent(
            id: "trace-04-share",
            name: "Share sheet",
            directory: "\(home)/Desktop/Personal/trace",
            suggestion: "add a share sheet for the current clip",
            status: .exited(SessionExit(success: true, code: 0))
        ),
    ]

    static func make() -> Fixture {
        let size = TerminalSize(rows: 40, cols: 100)
        var sessions: [SessionInfo] = []
        var names: [String: String] = [:]
        var active: Set<String> = []
        var attention: Set<String> = []
        for (index, agent) in agents.enumerated() {
            let running = agent.status == .running
            sessions.append(
                SessionInfo(
                    id: agent.id,
                    pid: running ? UInt32(41000 + index) : nil,
                    program: "claude",
                    cwd: agent.directory,
                    size: size,
                    status: agent.status
                )
            )
            names[agent.id] = agent.name
            if agent.active { active.insert(agent.id) }
            if agent.needsYou { attention.insert(agent.id) }
        }
        return Fixture(
            sessions: sessions,
            names: names,
            focusID: "fleet-01-preview",
            activeIDs: active,
            attentionIDs: attention
        )
    }

    /// Fullscreen frame from Claude Code 2.1.
    ///
    /// Column positions match a capture of `claude` 2.1.316: logo, model line,
    /// composer rules, and the auto-mode footer. The transcript uses that
    /// build's own marks: `>` for a user turn and `Wrote N lines to path`
    /// for a finished edit. The chrome itself sends no colors.
    static func screen(sessionID: String, columns: Int, rows: Int, title: String) -> Data {
        let columns = max(columns, 1)
        let rows = max(rows, 1)
        let agent = agents.first { $0.id == sessionID }
        let suggestion = agent?.suggestion ?? "fix the typecheck errors"
        let directory = agent?.directory ?? home
        var ansi = ANSI()
        ansi.command("?25l")
        ansi.command("H")
        ansi.command("2J")

        if rows >= 8 {
            ansi.at(2, 2, "▐▛███▛█")
            ansi.at(2, 12, clipped("Claude Code v\(claudeVersion)", columns: columns - 11))
            ansi.at(3, 1, "▝▜██████▀")
            ansi.at(3, 12, clipped("Opus 5.5 · API Usage Billing", columns: columns - 11))
            ansi.at(4, 2, "▝▝")
            ansi.at(4, 7, "▝▝")
            ansi.at(4, 12, clipped(displayPath(directory), columns: columns - 11))
            paintTranscript(
                &ansi,
                sessionID: sessionID,
                suggestion: suggestion,
                directory: directory,
                columns: columns,
                rows: rows
            )
            let effort = "◐ medium · /effort"
            let effortColumn = columns - 19
            if effortColumn >= 1 {
                ansi.at(rows - 4, effortColumn, effort)
            }
            ansi.at(rows - 3, 1, String(repeating: "─", count: columns))
            ansi.at(rows - 2, 1, clipped("❯\u{00A0}Try \"\(suggestion)\"", columns: columns))
            ansi.at(rows - 1, 1, String(repeating: "─", count: columns))
            ansi.at(rows, 1, clipped("  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents", columns: columns))
            ansi.command("\(rows - 2);3H")
        }

        let safeTitle = String(title.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })
        ansi.raw += "\u{1b}]0;\(safeTitle)\u{7}"
        ansi.command("?25h")
        return Data(ansi.raw.utf8)
    }

    private static var claudeVersion: String {
        let raw = ProcessInfo.processInfo.environment["FLEET_PREVIEW_CLAUDE_VERSION"] ?? ""
        let token = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return token.isEmpty ? "2.1.316" : token
    }

    private static func displayPath(_ path: String) -> String {
        if path == home { return "~" }
        let prefix = home + "/"
        if path.hasPrefix(prefix) {
            return "~/" + path.dropFirst(prefix.count)
        }
        return path
    }

    /// Conversation between the logo and the composer. Short threads stay
    /// under the logo. A thread taller than the pane keeps its latest lines.
    private static func paintTranscript(
        _ ansi: inout ANSI,
        sessionID: String,
        suggestion: String,
        directory: String,
        columns: Int,
        rows: Int
    ) {
        let top = 6
        let bottom = rows - 5
        guard bottom >= top else { return }
        let lines = transcriptLines(
            sessionID: sessionID,
            suggestion: suggestion,
            directory: directory,
            columns: columns
        )
        let height = bottom - top + 1
        let visible = lines.count > height ? Array(lines.suffix(height)) : lines
        for (offset, line) in visible.enumerated() where !line.isEmpty {
            ansi.at(top + offset, 1, line)
        }
    }

    private enum Turn {
        case user(String)
        case body(String)
        case tool(String)
    }

    private static func transcriptLines(
        sessionID: String,
        suggestion: String,
        directory: String,
        columns: Int
    ) -> [String] {
        var lines: [String] = []
        for (index, turn) in turns(sessionID: sessionID, suggestion: suggestion, directory: directory).enumerated() {
            if index > 0 { lines.append("") }
            switch turn {
            case .user(let text):
                lines.append(contentsOf: wrap(text, columns: columns, first: "> ", next: "  ").map {
                    "\u{1b}[1m\($0)\u{1b}[22m"
                })
            case .body(let text):
                lines.append(contentsOf: wrap(text, columns: columns, first: "", next: ""))
            case .tool(let text):
                lines.append(contentsOf: wrap(text, columns: columns, first: "  ", next: "    ").map {
                    "\u{1b}[2m\($0)\u{1b}[22m"
                })
            }
        }
        return lines
    }

    private static func turns(sessionID: String, suggestion: String, directory: String) -> [Turn] {
        if sessionID == "fleet-01-preview" {
            return [
                .user("add a screenshot preview"),
                .body("The window can open on its own. The sidebar should be full of Claude Code sessions, and this pane should be the Claude Code screen."),
                .tool("Read scripts/demo.sh"),
                .body("scripts/demo.sh starts fleet-daemon and two live agents. A screenshot launch needs a separate script."),
                .tool("Wrote 51 lines to apps/macos/scripts/preview.sh"),
                .body("scripts/preview.sh builds Fleet and opens it with FLEET_PREVIEW=1. The sidebar stays on these sessions. This pane is the Claude Code screen."),
            ]
        }
        let project = URL(fileURLWithPath: directory).lastPathComponent
        return [
            .user(suggestion),
            .body("I'll do that in \(project) and keep the change inside this session."),
            .tool("Read \(project)"),
            .body("The current code is in place. Next I'll make the change and leave the rest of \(project) alone."),
        ]
    }

    /// Wraps on spaces. `first` is the prefix of the opening line and `next`
    /// is the prefix of every continuation.
    private static func wrap(_ text: String, columns: Int, first: String, next: String) -> [String] {
        guard columns > 0 else { return [] }
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return [clipped(first, columns: columns)] }
        var lines: [String] = []
        var prefix = first
        var current = prefix
        for word in words {
            let gap = current == prefix ? "" : " "
            if current.count + gap.count + word.count <= columns {
                current += gap + word
                continue
            }
            if current != prefix {
                lines.append(current)
                prefix = next
                current = prefix
            }
            var rest = word
            while !rest.isEmpty {
                let room = columns - current.count
                if room <= 0 {
                    lines.append(clipped(current, columns: columns))
                    current = next
                    continue
                }
                if rest.count <= room {
                    current += rest
                    rest = ""
                } else {
                    current += rest.prefix(room)
                    rest.removeFirst(room)
                    lines.append(current)
                    current = next
                }
            }
        }
        if current != prefix || lines.isEmpty {
            lines.append(clipped(current, columns: columns))
        }
        return lines
    }

    private static func clipped(_ text: String, columns: Int) -> String {
        guard columns > 0 else { return "" }
        guard text.count > columns else { return text }
        return String(text.prefix(columns))
    }

    private struct ANSI {
        var raw = ""

        mutating func command(_ body: String) {
            raw += "\u{1b}[\(body)"
        }

        mutating func at(_ row: Int, _ column: Int, _ text: String) {
            guard row >= 1, column >= 1, !text.isEmpty else { return }
            command("\(row);\(column)H")
            raw += text
        }
    }
}
