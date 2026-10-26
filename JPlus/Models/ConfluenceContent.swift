import Foundation

/// Element of Confluence's `GET /wiki/api/v2/folders/{id}/direct-children`:
/// a page, folder, whiteboard or database directly inside a folder.
nonisolated struct ConfluenceChild: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// `page`, `folder`, `whiteboard`, `database`, …
    let type: String
    let status: String?
}

/// `GET /wiki/api/v2/folders/{id}`.
nonisolated struct ConfluenceFolder: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let spaceId: String
    let parentId: String?
    /// `folder`, `page`, … for what `parentId` points at.
    let parentType: String?
    let _links: ConfluencePage.Links?

    /// Where the folder opens in a browser, on the given site.
    func webURL(on siteURL: URL) -> URL {
        if let webui = _links?.webui, let url = URL(string: (_links?.base ?? siteURL.absoluteString + "/wiki") + webui) {
            return url
        }
        return siteURL.appending(path: "wiki/folders/\(id)")
    }
}

/// Element of Confluence's v1 `GET /wiki/rest/api/search?cql=…`, which is
/// still the only way to search by title across a site. Folders come back
/// with `content.type == "folder"`.
nonisolated struct ConfluenceSearchResult: Decodable, Hashable, Sendable {
    let title: String?
    let content: Content?

    nonisolated struct Content: Decodable, Hashable, Sendable {
        let id: String
        let type: String
        let title: String?
    }
}

/// `GET /wiki/api/v2/pages/{id}?body-format=atlas_doc_format`.
nonisolated struct ConfluencePage: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let spaceId: String
    let parentId: String?
    let version: Version
    let body: Body?
    let _links: Links?

    nonisolated struct Version: Decodable, Hashable, Sendable {
        let number: Int
    }

    nonisolated struct Body: Decodable, Hashable, Sendable {
        let atlas_doc_format: Representation?
    }

    nonisolated struct Representation: Decodable, Hashable, Sendable {
        /// The ADF document as a JSON string.
        let value: String
    }

    nonisolated struct Links: Decodable, Hashable, Sendable {
        let webui: String?
        let base: String?
    }

    /// The page body as an ADF tree, or an empty document when it has none.
    var document: ADFNode {
        guard let value = body?.atlas_doc_format?.value,
              let node = try? JSONDecoder().decode(ADFNode.self, from: Data(value.utf8))
        else { return ADFNode(type: "doc", content: []) }
        return node
    }

    /// Where the page opens in a browser, on the given site.
    func webURL(on siteURL: URL) -> URL {
        if let webui = _links?.webui, let url = URL(string: (_links?.base ?? siteURL.absoluteString + "/wiki") + webui) {
            return url
        }
        return siteURL.appending(path: "wiki/pages/\(id)")
    }
}

/// Element of `GET /wiki/api/v2/pages/{id}/inline-comments` and
/// `…/inline-comments/{id}/children`. An inline comment hangs on a stretch
/// of the page's text, which carries an `annotation` mark whose id is the
/// comment's `inlineMarkerRef`; replies have no marker of their own.
nonisolated struct ConfluenceComment: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let parentCommentId: String?
    /// `open`, `reopened`, `resolved` or `dangling` (its text is gone).
    let resolutionStatus: String?
    let version: Version
    let body: ConfluencePage.Body?
    let properties: Properties?
    let _links: ConfluencePage.Links?

    nonisolated struct Version: Decodable, Hashable, Sendable {
        let authorId: String?
        let createdAt: Date?
    }

    nonisolated struct Properties: Decodable, Hashable, Sendable {
        let inlineMarkerRef: String?
        let inlineOriginalSelection: String?
    }

    var authorID: String? { version.authorId }
    /// When this version was saved: when it was posted, or last edited.
    var date: Date? { version.createdAt }
    var markerRef: String? { properties?.inlineMarkerRef }

    /// The comment's text as an ADF tree, or nil when it has none.
    var document: ADFNode? {
        guard let value = body?.atlas_doc_format?.value else { return nil }
        return try? JSONDecoder().decode(ADFNode.self, from: Data(value.utf8))
    }

    /// The page in a browser, scrolled to this comment. The list's base
    /// isn't on each comment, so the site's `/wiki` stands in for it.
    func webURL(on siteURL: URL) -> URL? {
        guard let webui = _links?.webui else { return nil }
        return URL(string: (_links?.base ?? siteURL.absoluteString + "/wiki") + webui)
    }
}

/// `GET /wiki/rest/api/longtask/{id}`: a background job, such as archiving
/// pages. It waits as `ENQUEUED` until Confluence gets to it.
nonisolated struct ConfluenceLongTask: Decodable, Hashable, Sendable {
    let id: String
    let finished: Bool
    let successful: Bool
    /// What went wrong, when it failed, as Confluence words it.
    let problems: [String]

    nonisolated private struct Message: Decodable {
        let translation: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id, finished, successful, messages, errors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        finished = try container.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        successful = try container.decodeIfPresent(Bool.self, forKey: .successful) ?? false
        // Their shape isn't documented, so they're read only if they're as seen.
        let errors = (try? container.decodeIfPresent([Message].self, forKey: .errors)) ?? []
        let messages = (try? container.decodeIfPresent([Message].self, forKey: .messages)) ?? []
        problems = (errors + messages).compactMap(\.translation).filter { !$0.isEmpty }
    }
}
