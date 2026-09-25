import Foundation

/// Subset of `GET /rest/api/3/project/{key}` used when creating issues.
struct JiraProjectDetail: Decodable, Sendable {
    let id: String
    let key: String
    let name: String
    let issueTypes: [JiraIssueType]
}

struct JiraIssueType: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let subtask: Bool
    let hierarchyLevel: Int?
}

/// Response of `POST /rest/api/3/issue`.
struct CreatedIssue: Decodable, Sendable {
    let id: String
    let key: String
}

/// Element of the `POST /rest/api/3/issue/{key}/attachments` response.
struct JiraAttachment: Decodable, Identifiable, Sendable {
    let id: String
    let filename: String
    let size: Int?
    let mimeType: String?
}

/// Builds Atlassian Document Format from plain text so descriptions written
/// in the app (or drafted by Claude) render with real paragraphs and lists.
enum ADFBuilder {
    static func document(from text: String) -> [String: Any] {
        var blocks: [[String: Any]] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            var content: [[String: Any]] = []
            for (index, line) in paragraph.enumerated() {
                if index > 0 { content.append(["type": "hardBreak"]) }
                content.append(["type": "text", "text": line])
            }
            blocks.append(["type": "paragraph", "content": content])
            paragraph = []
        }
        func flushLists() {
            if !bullets.isEmpty {
                blocks.append(list("bulletList", bullets))
                bullets = []
            }
            if !numbered.isEmpty {
                blocks.append(list("orderedList", numbered))
                numbered = []
            }
        }
        func list(_ type: String, _ items: [String]) -> [String: Any] {
            ["type": type, "content": items.map { item in
                ["type": "listItem", "content": [["type": "paragraph", "content": [["type": "text", "text": item]]]]]
            }]
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph(); flushLists()
            } else if let heading = headingLevel(line) {
                flushParagraph(); flushLists()
                blocks.append([
                    "type": "heading", "attrs": ["level": heading.level],
                    "content": [["type": "text", "text": heading.text]],
                ])
            } else if let item = listItem(line, markers: ["- ", "* ", "• "]) {
                flushParagraph()
                if !numbered.isEmpty { flushLists() }
                bullets.append(item)
            } else if let item = numberedItem(line) {
                flushParagraph()
                if !bullets.isEmpty { flushLists() }
                numbered.append(item)
            } else {
                flushLists()
                paragraph.append(line)
            }
        }
        flushParagraph(); flushLists()

        if blocks.isEmpty {
            blocks.append(["type": "paragraph", "content": []])
        }
        return ["type": "doc", "version": 1, "content": blocks]
    }

    private static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index] == " " else { return nil }
        let text = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (min(level + 1, 4), text) // "# " maps to level 2 in Jira's scale
    }

    private static func listItem(_ line: String, markers: [String]) -> String? {
        for marker in markers where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> String? {
        guard let match = line.wholeMatch(of: /(\d{1,3})[.)]\s+(.+)/) else { return nil }
        return String(match.2)
    }
}
