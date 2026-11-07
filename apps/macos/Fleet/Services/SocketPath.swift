import Foundation

/// A daemon socket path typed into Settings or the connection card.
enum SocketPath {
    static let blankMessage = "Enter a socket path."

    enum Decision: Equatable {
        /// Leave the stored path and the connection alone.
        case reject
        case accept(String)
    }

    /// Blank and whitespace-only drafts are rejected. Anything else is trimmed
    /// and tilde-expanded. The caller reconnects only for `.accept`.
    static func decide(_ draft: String) -> Decision {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .reject }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        guard !expanded.isEmpty else { return .reject }
        return .accept(expanded)
    }

    static func canSubmit(_ draft: String) -> Bool {
        if case .accept = decide(draft) { return true }
        return false
    }

    static func validationMessage(for draft: String) -> String? {
        canSubmit(draft) ? nil : blankMessage
    }
}
