import Foundation

/// A design linked to an issue, as listed in Jira's "Designs" panel.
/// These come from the Figma for Jira app.
struct IssueDesign: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    /// The same design in Figma's Dev Mode.
    let inspectURL: URL?
    let isReadyForDev: Bool

    /// "Figma" for Figma links, otherwise the link's host.
    var providerName: String {
        let host = url.host() ?? ""
        if host == "figma.com" || host.hasSuffix(".figma.com") { return "Figma" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Issue data that only Jira's GraphQL gateway has: linked designs, and the
/// media file id of each attachment. ADF media nodes refer to attachments by
/// that media id, not by attachment id.
struct IssueExtras: Sendable {
    var designs: [IssueDesign] = []
    /// Media file id → attachment id.
    var attachmentIDsByMediaID: [String: String] = [:]
}

/// Wire shape of the `JPlusIssueExtras` GraphQL query.
nonisolated struct IssueExtrasResponse: Decodable, Sendable {
    let data: DataField?
    let errors: [GraphQLError]?

    nonisolated struct DataField: Decodable, Sendable {
        let jira: Jira?
        nonisolated struct Jira: Decodable, Sendable {
            let issueByKey: Issue?
        }
    }

    nonisolated struct Issue: Decodable, Sendable {
        let designs: Connection<DesignNode>?
        let attachments: Connection<AttachmentNode>?
    }

    nonisolated struct Connection<Node: Decodable & Sendable>: Decodable, Sendable {
        let edges: [Edge?]?
        nonisolated struct Edge: Decodable, Sendable {
            let node: Node?
        }

        var nodes: [Node] { (edges ?? []).compactMap { $0?.node } }
    }

    /// A `DevOpsDesign`; other kinds of design decode with every field nil.
    nonisolated struct DesignNode: Decodable, Sendable {
        let id: String?
        let displayName: String?
        let url: String?
        let inspectUrl: String?
        /// `READY_FOR_DEVELOPMENT`, `UNKNOWN` or `NONE`.
        let status: String?
    }

    nonisolated struct AttachmentNode: Decodable, Sendable {
        let attachmentId: String?
        let mediaApiFileId: String?
    }

    nonisolated struct GraphQLError: Decodable, Sendable {
        let message: String
    }
}
