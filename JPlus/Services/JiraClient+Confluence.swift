import Foundation

/// Confluence Cloud's v2 API lives on the same site under `/wiki/api/v2`
/// and takes the same email + API token, so the Jira client serves it too.
extension JiraClient {
    func confluenceFolder(id: String) async throws -> ConfluenceFolder {
        try await get("/wiki/api/v2/folders/\(id)")
    }

    /// Pages and folders directly inside a folder. Confluence pages these at
    /// 250; a priorities folder holds months and a month holds days, so one
    /// page is enough.
    func confluenceFolderChildren(id: String) async throws -> [ConfluenceChild] {
        struct Page: Decodable { let results: [ConfluenceChild] }
        let page: Page = try await get("/wiki/api/v2/folders/\(id)/direct-children", query: [
            URLQueryItem(name: "limit", value: "250"),
        ])
        return page.results
    }

    /// Site-wide content search; `cql` like `type = folder and title = "Daily Priorities"`.
    func confluenceSearch(cql: String, limit: Int = 25) async throws -> [ConfluenceSearchResult] {
        struct Page: Decodable { let results: [ConfluenceSearchResult] }
        let page: Page = try await get("/wiki/rest/api/search", query: [
            URLQueryItem(name: "cql", value: cql),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return page.results
    }

    func confluencePage(id: String) async throws -> ConfluencePage {
        try await get("/wiki/api/v2/pages/\(id)", query: [
            URLQueryItem(name: "body-format", value: "atlas_doc_format"),
        ])
    }

    /// A page's open inline comments (the ones on highlighted text), oldest
    /// first. Replies aren't among them; `confluenceCommentReplies` has those.
    func confluenceInlineComments(pageID: String) async throws -> [ConfluenceComment] {
        struct Page: Decodable { let results: [ConfluenceComment] }
        let page: Page = try await get("/wiki/api/v2/pages/\(pageID)/inline-comments", query: [
            URLQueryItem(name: "body-format", value: "atlas_doc_format"),
            URLQueryItem(name: "resolution-status", value: "open"),
            URLQueryItem(name: "resolution-status", value: "reopened"),
            URLQueryItem(name: "sort", value: "created-date"),
            URLQueryItem(name: "limit", value: "250"),
        ])
        return page.results
    }

    /// The replies to an inline comment, oldest first.
    func confluenceCommentReplies(commentID: String) async throws -> [ConfluenceComment] {
        struct Page: Decodable { let results: [ConfluenceComment] }
        let page: Page = try await get("/wiki/api/v2/inline-comments/\(commentID)/children", query: [
            URLQueryItem(name: "body-format", value: "atlas_doc_format"),
            URLQueryItem(name: "sort", value: "created-date"),
            URLQueryItem(name: "limit", value: "250"),
        ])
        return page.results
    }

    /// Adds a reply to the thread an inline comment starts. A reply hangs on
    /// its parent, so it names no page and highlights no text of its own.
    @discardableResult
    func replyToConfluenceComment(_ commentID: String, document: ADFNode) async throws -> ConfluenceComment {
        try await post("/wiki/api/v2/inline-comments", json: [
            "parentCommentId": commentID,
            "body": try Self.confluenceBody(document),
        ])
    }

    /// Starts an inline comment thread, highlighting text on the page:
    /// the `matchIndex`th (from 0) of the page's `matchCount` copies of
    /// `selection`. Confluence adds the highlight to the page's body.
    @discardableResult
    func createConfluenceInlineComment(pageID: String, document: ADFNode, selection: String, matchIndex: Int, matchCount: Int) async throws -> ConfluenceComment {
        try await post("/wiki/api/v2/inline-comments", json: [
            "pageId": pageID,
            "body": try Self.confluenceBody(document),
            "inlineCommentProperties": [
                "textSelection": selection,
                "textSelectionMatchCount": matchCount,
                "textSelectionMatchIndex": matchIndex,
            ],
        ])
    }

    func createConfluenceFolder(title: String, spaceID: String, parentID: String) async throws -> ConfluenceFolder {
        try await post("/wiki/api/v2/folders", json: [
            "spaceId": spaceID,
            "title": title,
            "parentId": parentID,
        ])
    }

    func createConfluencePage(title: String, spaceID: String, parentID: String, document: ADFNode) async throws -> ConfluencePage {
        try await post("/wiki/api/v2/pages", json: [
            "spaceId": spaceID,
            "status": "current",
            "title": title,
            "parentId": parentID,
            "body": try Self.confluenceBody(document),
        ])
    }

    /// Replaces a page's body. Confluence answers 409 when `version` is no
    /// longer the current one, i.e. someone else saved first.
    func updateConfluencePage(id: String, title: String, version: Int, document: ADFNode, message: String = "") async throws -> ConfluencePage {
        try await put("/wiki/api/v2/pages/\(id)", json: [
            "id": id,
            "status": "current",
            "title": title,
            "body": try Self.confluenceBody(document),
            "version": ["number": version, "message": message],
        ])
    }

    func deleteConfluencePage(id: String) async throws {
        try await delete("/wiki/api/v2/pages/\(id)")
    }

    /// Asks Confluence to archive a page: it leaves its folder for the
    /// space's archive, where it can be restored. That happens in the
    /// background; follow it with `confluenceLongTask` and the returned id.
    /// Takes the space's Archive permission, which can come without Delete.
    func archiveConfluencePage(id: String) async throws -> String {
        struct Accepted: Decodable { let id: String }
        let accepted: Accepted = try await post("/wiki/rest/api/content/archive", json: [
            "pages": [["id": Int(id).map { $0 as Any } ?? id]],
        ])
        return accepted.id
    }

    /// A background job Confluence is running, such as an archive.
    func confluenceLongTask(id: String) async throws -> ConfluenceLongTask {
        try await get("/wiki/rest/api/longtask/\(id)")
    }

    /// Pages and comments take ADF as a JSON string, with the schema version at the root.
    private static func confluenceBody(_ document: ADFNode) throws -> [String: Any] {
        let data = try JSONEncoder().encode(document)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JiraError.invalidResponse
        }
        object["version"] = 1
        let value = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return ["representation": "atlas_doc_format", "value": String(decoding: value, as: UTF8.self)]
    }
}

extension JiraError {
    /// Confluence's answer to saving over a newer page version.
    var isConflict: Bool {
        if case .http(let status, _) = self { return status == 409 }
        return false
    }
}
