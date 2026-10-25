import Foundation

/// What the main window was showing, saved so the app reopens there: the
/// sidebar item, plus the issues and versions opened on top of it.
struct SavedPlace: Codable, Equatable {
    enum Screen: Codable, Equatable {
        case myIssues, mentions, account, search, versions, newTicket, priorities, productQuestions
        case issue(String)
        /// Saved by id and looked up again on launch, so its counts are current.
        case version(projectKey: String, versionID: String)
        /// A Jira space under Spaces, by project key.
        case space(String)
    }

    var sidebar: Screen
    /// Bottom first.
    var stack: [Screen]

    /// Deeper stacks keep only their top screens.
    static let maxStackDepth = 20
}
