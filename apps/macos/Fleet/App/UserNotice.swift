import FleetAPI
import SwiftUI

/// A toast or inline error: what happened, then what to do.
struct UserNotice: Equatable {
    var title: String
    var detail: String

    init(_ title: String, detail: String = "") {
        self.title = title
        self.detail = detail
    }

    var paragraph: String {
        detail.isEmpty ? title : "\(title) \(detail)"
    }
}

enum AgentAction: Equatable {
    case sendInput
    case stop
    case delete
    case fork
    case attach
    case create
}

/// App copy for daemon and connection failures.
/// `FleetError.errorDescription` stays technical for the probe.
enum AgentNotices {
    static func explain(
        _ error: Error,
        action: AgentAction,
        agent: String,
        exit: SessionExit?
    ) -> UserNotice {
        if let launch = error as? DaemonLaunchError {
            return launch.notice
        }
        guard let apiError = error as? FleetError else {
            return UserNotice(
                fallbackTitle(action, agent: agent),
                detail: "Try again. If it keeps happening, quit Fleet and open it again."
            )
        }
        return explain(
            apiError,
            action: action,
            agent: agent,
            exit: exit,
            onCard: false,
            fallbackSocket: ""
        )
    }

    static func explainConnection(_ error: Error, socketPath: String) -> UserNotice {
        if let launch = error as? DaemonLaunchError {
            return launch.notice
        }
        guard let apiError = error as? FleetError else {
            let reason = sentence(error.localizedDescription)
            let next = recovery(onCard: true)
            let socket = displayPath(socketPath)
            let lead = reason.isEmpty ? "The socket is \(socket)." : "\(reason) The socket is \(socket)."
            return UserNotice("The daemon could not be started.", detail: "\(lead) \(next)")
        }
        return explain(
            apiError,
            action: nil,
            agent: "The agent",
            exit: nil,
            onCard: true,
            fallbackSocket: socketPath
        )
    }

    static func code(of error: Error) -> String? {
        switch error {
        case let FleetError.api(error), let FleetError.rejected(error):
            return error.code
        default:
            return nil
        }
    }

    static func isTransport(_ error: Error) -> Bool {
        guard let apiError = error as? FleetError else { return false }
        switch apiError {
        case .socketClosed, .invalidFrame, .frameTooLarge, .connectFailed,
             .socketPathTooLong, .protocolMismatch, .timeout:
            return true
        case .api, .rejected, .unexpectedResponse, .daemonUnavailable:
            return false
        }
    }

    static func notConnected() -> UserNotice {
        UserNotice(
            "Fleet is not connected.",
            detail: "Choose Reconnect to Daemon in the Fleet menu, then try again."
        )
    }

    static func daemonBinaryMissing() -> UserNotice {
        UserNotice(
            "No daemon binary was found.",
            detail: "In the project directory, run cargo build -p fleet-daemon, or set FLEET_DAEMON to the binary."
        )
    }

    static func deleteNeedsNewerDaemon() -> UserNotice {
        UserNotice(
            "Deleting agents needs a newer daemon.",
            detail: "Quit fleet-daemon, then open Fleet again. The app starts the current daemon if none is running."
        )
    }

    static func missingFolder(_ path: String) -> UserNotice {
        UserNotice(
            "That working directory does not exist.",
            detail: "\(displayPath(path)) is not a folder. Choose a working directory before starting the agent."
        )
    }

    static func daemonClosedConnection() -> UserNotice {
        UserNotice(
            "The daemon closed the connection.",
            detail: "Choose Connect to attach again. Agents that were still running may still be there."
        )
    }

    static func daemonShuttingDown() -> UserNotice {
        UserNotice(
            "The daemon is shutting down.",
            detail: "Choose Connect once it is running again. Agents that were still running may still be there."
        )
    }

    /// The daemon dropped this window for falling behind on one session's
    /// output. Fleet reconnects and replays a snapshot on its own.
    static func streamRestarted(ordering: Bool) -> UserNotice {
        UserNotice(
            "Fleet reconnected to the daemon.",
            detail: ordering
                ? "Terminal output arrived out of order, so Fleet refreshed every open agent from a fresh snapshot."
                : "Terminal output arrived faster than this window could read it, so Fleet refreshed every open agent from a fresh snapshot."
        )
    }

    /// The event stream ended without a reason Fleet can attribute. The app
    /// still reconnects and refreshes every pane before reporting anything.
    static func streamRestarted() -> UserNotice {
        UserNotice(
            "Fleet reconnected to the daemon.",
            detail: "The connection ended unexpectedly, so Fleet refreshed every open agent from a fresh snapshot."
        )
    }

    static func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static func explain(
        _ error: FleetError,
        action: AgentAction?,
        agent: String,
        exit: SessionExit?,
        onCard: Bool,
        fallbackSocket: String
    ) -> UserNotice {
        switch error {
        case .api(let api), .rejected(let api):
            return explainAPI(api, action: action, agent: agent, exit: exit, onCard: onCard)
        case .daemonUnavailable:
            return onCard
                ? UserNotice("Fleet is not connected.", detail: recovery(onCard: true))
                : notConnected()
        case .connectFailed(let path, _, let message):
            let reason = sentence(message)
            let socket = displayPath(path.isEmpty ? fallbackSocket : path)
            let lead = reason.isEmpty ? "The socket is \(socket)." : "\(reason) The socket is \(socket)."
            return UserNotice(
                "Fleet could not reach the daemon.",
                detail: "\(lead) \(recovery(onCard: onCard))"
            )
        case .socketClosed:
            if onCard {
                return daemonClosedConnection()
            }
            let title = action == .sendInput || action == nil
                ? "That input was not delivered."
                : fallbackTitle(action ?? .sendInput, agent: agent)
            return UserNotice(
                title,
                detail: "The daemon closed the connection. \(recovery(onCard: false))"
            )
        case .socketPathTooLong(let length):
            return UserNotice(
                "That socket path is too long.",
                detail: "This path is \(length) bytes. Unix sockets allow at most 100. Choose a shorter path in Settings."
            )
        case .protocolMismatch(let expected, let received):
            return UserNotice(
                "Fleet and the daemon are different versions.",
                detail: "This app expects protocol \(expected), and the daemon speaks protocol \(received). Quit fleet-daemon, then open Fleet again so both come from the same build."
            )
        case .frameTooLarge:
            return UserNotice(
                "A message from the daemon was too large to read.",
                detail: persisted(recovery(onCard: onCard))
            )
        case .invalidFrame(let message):
            if let reason = socketFailureReason(message) {
                return UserNotice(
                    "Fleet lost the connection to the daemon.",
                    detail: "\(reason) \(recovery(onCard: onCard))"
                )
            }
            return UserNotice(
                "Fleet received a message it could not read.",
                detail: persisted(recovery(onCard: onCard))
            )
        case .timeout:
            return UserNotice(
                "The daemon did not respond in time.",
                detail: recovery(onCard: onCard)
            )
        case .unexpectedResponse:
            return UserNotice(
                "The daemon sent a reply Fleet did not understand.",
                detail: persisted(recovery(onCard: onCard))
            )
        }
    }

    private static func explainAPI(
        _ error: ApiError,
        action: AgentAction?,
        agent: String,
        exit: SessionExit?,
        onCard: Bool
    ) -> UserNotice {
        switch error.code {
        case "session_closed":
            guard let action else { return connectionFailed(onCard: onCard) }
            return sessionClosed(action: action, agent: agent, exit: exit)
        case "session_not_found":
            guard let action else { return connectionFailed(onCard: onCard) }
            return sessionMissing(action: action, agent: agent)
        case "session_running":
            guard let action else { return connectionFailed(onCard: onCard) }
            return sessionStillRunning(action: action, agent: agent)
        case "spawn_failed":
            guard let action else { return connectionFailed(onCard: onCard) }
            return UserNotice(
                action == .fork ? "\(agent) could not be forked." : "\(agent) could not start.",
                detail: spawnDetail(error.message)
            )
        case "duplicate_session":
            guard let action else { return connectionFailed(onCard: onCard) }
            if action == .fork {
                return UserNotice(
                    "\(agent) could not be forked.",
                    detail: "An agent with that name already exists. Try again."
                )
            }
            let title = agent == "The agent"
                ? "An agent with that name already exists."
                : "An agent named “\(agent)” already exists."
            return UserNotice(title, detail: "Choose another name.")
        case "invalid_program":
            return UserNotice(
                "The program could not be found.",
                detail: "Enter the full path to an executable that is installed on this Mac."
            )
        case "missing_working_directory":
            return UserNotice(
                "Choose a working directory.",
                detail: "The agent needs a folder to start in."
            )
        case "invalid_terminal_size":
            return UserNotice(
                "The terminal size is not valid.",
                detail: "Resize the window, then try again."
            )
        case "invalid_session_id":
            return UserNotice(
                "That agent name is not valid.",
                detail: "Use letters, numbers, hyphens, or underscores."
            )
        case "termination_failed":
            return termination(
                agent: agent,
                message: error.message,
                timedOut: false,
                deleting: action == .delete
            )
        case "termination_timed_out":
            return termination(
                agent: agent,
                message: error.message,
                timedOut: true,
                deleting: action == .delete
            )
        case "input_failed":
            return UserNotice(
                action == nil ? "That input was not delivered." : "\(agent) did not receive that input.",
                detail: inputFailureDetail(error.message)
            )
        case "already_attached":
            return UserNotice(
                "\(agent) is already open.",
                detail: "Select it in the sidebar."
            )
        case "not_attached":
            return UserNotice(
                "\(agent) is not open in this window.",
                detail: "Select it in the sidebar, then try again."
            )
        case "engine_stopped":
            return UserNotice(
                "The daemon has stopped.",
                detail: onCard
                    ? "Choose Start daemon, then Connect."
                    : recovery(onCard: false)
            )
        case "invalid_message":
            if action == .delete, error.message.contains("remove_session") {
                return deleteNeedsNewerDaemon()
            }
            return UserNotice(
                "Fleet received a message it could not read.",
                detail: persisted(recovery(onCard: onCard))
            )
        case "invalid_request":
            let reason = sentence(error.message)
            let next = action == nil ? recovery(onCard: onCard) : "Try again."
            let title = action.map { fallbackTitle($0, agent: agent) }
                ?? "Fleet could not connect to the daemon."
            return UserNotice(title, detail: reason.isEmpty ? next : "\(reason) \(next)")
        case "unsupported_protocol":
            return UserNotice(
                "Fleet and the daemon are different versions.",
                detail: "Quit fleet-daemon, then open Fleet again so both come from the same build."
            )
        case "handshake_required", "handshake_timeout":
            return UserNotice(
                "Fleet could not finish connecting.",
                detail: recovery(onCard: onCard)
            )
        case "slow_client":
            return UserNotice(
                "The daemon dropped the connection.",
                detail: "Fleet was not reading output quickly enough. \(recovery(onCard: onCard))"
            )
        case "resize_failed":
            return UserNotice(
                "\(agent) could not be resized.",
                detail: "Resize the window again."
            )
        default:
            if let action {
                return UserNotice(fallbackTitle(action, agent: agent), detail: persisted("Try again."))
            }
            return connectionFailed(onCard: onCard)
        }
    }

    private static func connectionFailed(onCard: Bool) -> UserNotice {
        UserNotice(
            "Fleet could not connect to the daemon.",
            detail: persisted(recovery(onCard: onCard))
        )
    }

    private static func sessionClosed(
        action: AgentAction,
        agent: String,
        exit: SessionExit?
    ) -> UserNotice {
        let title = "\(agent) has exited."
        switch action {
        case .sendInput:
            return UserNotice(title)
        case .stop:
            return closed(title, exit: exit, then: ["There is nothing left to stop."])
        case .delete:
            return closed(title, exit: exit, then: [
                "It could not be removed from the list.",
                "Try deleting it again.",
            ])
        case .attach:
            return closed(title, exit: exit, then: [
                "Its terminal could not be opened.",
                "Start a new agent to continue.",
            ])
        case .fork:
            return closed(title, exit: exit, then: ["Start a new agent in the same directory instead."])
        case .create:
            return closed(title, exit: exit, then: ["Check the program and the working directory, then try again."])
        }
    }

    private static func sessionMissing(action: AgentAction, agent: String) -> UserNotice {
        switch action {
        case .sendInput:
            return UserNotice(
                "\(agent) is no longer available.",
                detail: "The daemon does not have this agent, so the input was not delivered. Start a new agent to continue."
            )
        case .stop:
            return UserNotice(
                "\(agent) is already gone.",
                detail: "There is nothing left to stop."
            )
        case .delete:
            return UserNotice(
                "\(agent) is already gone.",
                detail: "It is no longer in the daemon. The list will refresh."
            )
        case .attach:
            return UserNotice(
                "\(agent) is no longer available.",
                detail: "The daemon does not have this agent. Start a new one."
            )
        case .fork:
            return UserNotice(
                "\(agent) could not be forked.",
                detail: "Start a new agent in the same directory instead."
            )
        case .create:
            return UserNotice(
                "\(agent) could not be created.",
                detail: "Check the program and the working directory, then try again."
            )
        }
    }

    private static func sessionStillRunning(action: AgentAction, agent: String) -> UserNotice {
        if action == .delete {
            return UserNotice(
                "\(agent) is still running.",
                detail: "It was not removed. Stop it, then delete it again."
            )
        }
        return UserNotice(
            "\(agent) is still running.",
            detail: "The stop request was not accepted. Try again."
        )
    }

    private static func termination(
        agent: String,
        message: String,
        timedOut: Bool,
        deleting: Bool
    ) -> UserNotice {
        let retry = "Try again, or exit it from the terminal."
        if deleting {
            let lead = timedOut
                ? "It did not stop in time, so it is still in the list."
                : "\(cause(in: message).map { "\($0) " } ?? "")It could not be stopped, so it is still in the list."
            return UserNotice("\(agent) was not deleted.", detail: "\(lead) \(retry)")
        }
        if timedOut {
            return UserNotice("\(agent) did not stop in time.", detail: retry)
        }
        let reason = cause(in: message).map { "\($0) " } ?? ""
        return UserNotice("\(agent) could not be stopped.", detail: "\(reason)\(retry)")
    }

    private static func closed(_ title: String, exit: SessionExit?, then sentences: [String]) -> UserNotice {
        var parts: [String] = []
        if let clause = exitClause(exit) {
            parts.append(clause)
        }
        parts.append(contentsOf: sentences)
        return UserNotice(title, detail: parts.joined(separator: " "))
    }

    private static func exitClause(_ exit: SessionExit?) -> String? {
        guard let exit else { return nil }
        if let signal = exit.signal?.trimmingCharacters(in: .whitespacesAndNewlines), !signal.isEmpty {
            return "It was stopped by \(signal)."
        }
        if exit.success { return nil }
        return "It exited with code \(exit.code)."
    }

    private static func spawnDetail(_ message: String) -> String {
        let check = "Check that the program is installed and that the working directory exists."
        if let cause = cause(in: message) {
            return "\(cause) \(check)"
        }
        return check
    }

    private static func inputFailureDetail(_ message: String) -> String {
        let next = "Try again. If the agent has exited, start a new one."
        if let cause = cause(in: message) {
            return "\(cause) \(next)"
        }
        return next
    }

    private static func fallbackTitle(_ action: AgentAction, agent: String) -> String {
        switch action {
        case .sendInput:
            return "\(agent) did not receive that input."
        case .stop:
            return "\(agent) could not be stopped."
        case .delete:
            return "\(agent) could not be deleted."
        case .fork:
            return "\(agent) could not be forked."
        case .attach:
            return "\(agent) could not be opened."
        case .create:
            return "\(agent) could not be created."
        }
    }

    private static func recovery(onCard: Bool) -> String {
        onCard
            ? "Choose Connect to try again, or Start daemon if it is not running."
            : "Choose Reconnect to Daemon in the Fleet menu."
    }

    private static func persisted(_ next: String) -> String {
        "\(next) If it keeps happening, quit fleet-daemon and open Fleet again."
    }

    private static func socketFailureReason(_ message: String) -> String? {
        let prefixes = ["socket read failed: ", "socket write failed: "]
        guard let prefix = prefixes.first(where: { message.hasPrefix($0) }) else { return nil }
        let reason = sentence(String(message.dropFirst(prefix.count)))
        return reason.isEmpty ? nil : reason
    }

    private static func cause(in message: String) -> String? {
        guard let range = message.range(of: ": ", options: .backwards) else { return nil }
        let value = sentence(String(message[range.upperBound...]))
        guard !value.isEmpty, value.count <= 180, !value.contains("\n"), !value.contains("session \"") else {
            return nil
        }
        return value
    }

    private static func sentence(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(
            of: #" \(os error \d+\)"#,
            with: "",
            options: .regularExpression
        )
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if let first = value.first, first.isLowercase {
            value.replaceSubrange(value.startIndex...value.startIndex, with: String(first).uppercased())
        }
        if let last = value.last, last != ".", last != "?" {
            value.append(".")
        }
        return value
    }
}

struct NoticeCopy: View {
    var notice: UserNotice
    var titleColor: Color = .primary
    var detailColor: Color = .secondary
    var selectable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(notice.title)
                .font(Typography.caption)
                .foregroundStyle(titleColor)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if !notice.detail.isEmpty {
                detailText
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var detailText: some View {
        let text = Text(notice.detail)
            .font(Typography.captionRegular)
            .foregroundStyle(detailColor)
            .lineLimit(5)
            .fixedSize(horizontal: false, vertical: true)
        if selectable {
            text.textSelection(.enabled)
        } else {
            text
        }
    }
}
