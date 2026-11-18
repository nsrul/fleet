import Foundation

/// Picks the agent tile a New Agent sheet opens on.
///
/// A Mac usually has one or two agents installed. Opening on one that is not
/// installed leaves Create disabled and hides the agents this machine can
/// actually run, so the sheet starts from what is available.
enum AgentChoice {
    /// The tile to select, in preference order:
    ///
    /// 1. the preset that last started a session, while it is still installed;
    /// 2. the first installed preset in the order the sheet shows them;
    /// 3. the custom tile, which needs no program until the user types one.
    ///
    /// The custom tile is never preselected through the first two rules: its
    /// program is empty until the user fills it in, so it would open the sheet
    /// on a disabled Create button.
    static func initialPresetID(
        candidates: [String],
        available: Set<String>,
        lastUsed: String?,
        customID: String
    ) -> String? {
        if let lastUsed,
           lastUsed != customID,
           candidates.contains(lastUsed),
           available.contains(lastUsed) {
            return lastUsed
        }
        if let installed = candidates.first(where: { $0 != customID && available.contains($0) }) {
            return installed
        }
        if candidates.contains(customID) {
            return customID
        }
        return candidates.first
    }
}
