import AppKit

/// Downloads issue attachments once and keeps them as files in the app's
/// temporary directory (which the system clears over time), so images draw
/// from disk on later visits and Quick Look can preview any attachment.
final class AttachmentStore {
    static let shared = AttachmentStore()

    private var downloads: [URL: Task<URL, Error>] = [:]
    private let images = NSCache<NSURL, NSImage>()

    /// Local copy of an attachment, downloaded the first time it's asked for.
    func file(for attachment: JiraIssue.Attachment, using client: JiraClient) async throws -> URL {
        let file = Self.location(of: attachment, site: client.credentials.siteHost)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        if let download = downloads[file] { return try await download.value }

        let download = Task {
            let data = try await client.attachmentContent(id: attachment.id)
            try await Task.detached {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            }.value
            return file
        }
        downloads[file] = download
        defer { downloads[file] = nil }
        return try await download.value
    }

    /// An image attachment, decoded.
    func image(for attachment: JiraIssue.Attachment, using client: JiraClient) async throws -> NSImage {
        let file = try await file(for: attachment, using: client)
        if let image = images.object(forKey: file as NSURL) { return image }
        guard let image = NSImage(contentsOf: file), image.isValid else { throw AttachmentError.unreadableImage }
        images.setObject(image, forKey: file as NSURL)
        return image
    }

    /// `…/Attachments/<site>/<attachment id>/<file name>`. The real file name
    /// is kept because Quick Look shows it as the title.
    private static func location(of attachment: JiraIssue.Attachment, site: String) -> URL {
        let name = attachment.filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return FileManager.default.temporaryDirectory
            .appending(path: "Attachments", directoryHint: .isDirectory)
            .appending(path: site, directoryHint: .isDirectory)
            .appending(path: attachment.id, directoryHint: .isDirectory)
            .appending(path: name.isEmpty ? "attachment" : name, directoryHint: .notDirectory)
    }
}

enum AttachmentError: LocalizedError {
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "The image couldn't be read."
        }
    }
}
