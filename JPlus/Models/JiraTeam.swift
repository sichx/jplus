import Foundation

/// A team from Atlassian Teams, as an issue's Team field holds it.
struct JiraTeam: Decodable, Identifiable, Hashable, Sendable {
    /// The bare team id, without the `ari:cloud:identity::team/` prefix.
    let id: String
    let name: String
}

/// An issue's Team field. Team is a custom field, so its id differs by site.
struct IssueTeamField: Hashable, Sendable {
    /// For example "customfield_10001".
    let fieldID: String
    var team: JiraTeam?
}
