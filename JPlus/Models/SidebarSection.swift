import Foundation

/// Sidebar rows that View > Show in Sidebar can hide.
enum SidebarSection: String, CaseIterable, Identifiable {
    case versions, myIssues, mentions, priorities, productQuestions, spaces, recentIssues

    var id: Self { self }

    var title: String {
        switch self {
        case .versions: "Versions"
        case .myIssues: "My Issues"
        case .mentions: "Mentions"
        case .priorities: "Daily Priorities"
        case .productQuestions: "Product Questions"
        case .spaces: "Spaces"
        case .recentIssues: "Recent Issues"
        }
    }

    /// Comma-separated raw values of the hidden sections, kept in the standard
    /// defaults so the choice is the same for every account.
    static let hiddenStorageKey = "sidebarHiddenSections"

    static func hidden(in raw: String) -> Set<SidebarSection> {
        Set(raw.split(separator: ",").compactMap { SidebarSection(rawValue: String($0)) })
    }

    /// `raw` with `section` shown or hidden.
    static func raw(_ raw: String, showing section: SidebarSection, _ isShown: Bool) -> String {
        var hidden = hidden(in: raw)
        if isShown { hidden.remove(section) } else { hidden.insert(section) }
        return allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
    }
}
