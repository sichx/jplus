#if os(macOS)
import AppKit
#else
import UIKit
#endif
import ImageIO
import UniformTypeIdentifiers

/// Downloads the photos on priority pages once and keeps them as files
/// beside the issue attachments (which Settings can clear), so they draw
/// from disk on later visits and Quick Look can open them. A photo just
/// uploaded is kept from the bytes sent, so it shows without downloading.
final class PriorityPhotoStore {
    static let shared = PriorityPhotoStore()

    private var downloads: [URL: Task<URL, Error>] = [:]
    private let previews = NSCache<NSString, PlatformImage>()

    /// Local copy of a page's attachment, downloaded the first time it's asked for.
    func file(for attachment: ConfluenceAttachment, using client: JiraClient) async throws -> URL {
        let file = Self.location(of: attachment, site: client.credentials.siteHost)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        if let download = downloads[file] { return try await download.value }
        guard let path = attachment.sitePath else { throw PriorityPhotoError.notDownloadable }

        let download = Task {
            let data = try await client.siteData(at: path)
            try await Self.write(data, to: file)
            return file
        }
        downloads[file] = download
        defer { downloads[file] = nil }
        return try await download.value
    }

    /// Keeps the bytes just uploaded as an attachment's local copy.
    func keep(_ data: Data, for attachment: ConfluenceAttachment, site: String) async {
        try? await Self.write(data, to: Self.location(of: attachment, site: site))
    }

    /// A small copy of a photo, no more than `maxPixels` on its long side,
    /// for showing under its priority. Decoding a phone photo takes a while,
    /// so it's done off the main thread and kept in memory.
    func preview(for attachment: ConfluenceAttachment, using client: JiraClient, maxPixels: Int) async throws -> PlatformImage {
        let key = "\(client.credentials.siteHost)/\(attachment.fileId ?? attachment.id)/\(maxPixels)" as NSString
        if let image = previews.object(forKey: key) { return image }
        let file = try await file(for: attachment, using: client)
        guard let image = await PhotoImaging.preview(of: file, maxPixels: maxPixels) else { throw AttachmentError.unreadableImage }
        previews.setObject(image, forKey: key)
        return image
    }

    @concurrent
    private static func write(_ data: Data, to file: URL) async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    /// `…/Attachments/<site>/confluence-<file id>/<file name>`, beside the
    /// issue attachments. The real file name is kept for Quick Look's title.
    private static func location(of attachment: ConfluenceAttachment, site: String) -> URL {
        let name = attachment.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return AttachmentStore.folder
            .appending(path: site, directoryHint: .isDirectory)
            .appending(path: "confluence-\(attachment.fileId ?? attachment.id)", directoryHint: .isDirectory)
            .appending(path: name.isEmpty ? "photo" : name, directoryHint: .notDirectory)
    }
}

enum PriorityPhotoError: LocalizedError {
    case notDownloadable
    case notFound
    case unreadable
    case cantAdd

    var errorDescription: String? {
        switch self {
        case .notDownloadable: "Confluence didn't say where this photo downloads from."
        case .notFound: "This photo isn't attached to the page any more."
        case .unreadable: "That isn't an image the app can read."
        case .cantAdd: "Photos can't go under an indented priority, or one with priorities indented under it."
        }
    }
}

/// A photo as it's uploaded: bytes in a format every browser shows, its
/// upright size, and a small copy to show while it uploads.
nonisolated struct PreparedPhoto: Sendable {
    let data: Data
    let filename: String
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let preview: Data?
}

/// Image work for priority photos, off the main thread.
nonisolated enum PhotoImaging {
    /// Formats every browser shows, kept as they are when they're not huge,
    /// with their MIME type and the file extension that goes with it.
    private static let webTypes: [(type: UTType, mime: String, extensions: [String])] = [
        (.png, "image/png", ["png"]),
        (.jpeg, "image/jpeg", ["jpg", "jpeg"]),
        (.gif, "image/gif", ["gif"]),
    ]
    /// Past this many bytes, or pixels on the long side, a photo is
    /// re-encoded smaller: a phone photo can be 5 MB and 4000 px.
    private static let largestKeptBytes = 4_000_000
    private static let largestKeptSide = 4096
    /// The long side of a photo that was too big as it was.
    private static let reducedSide = 3072

    /// Readies an image for upload: PNG, JPEG and GIF stay as they are
    /// unless they're huge; anything else (HEIC from the phone, TIFF from
    /// the clipboard) and anything huge becomes a JPEG, upright.
    @concurrent
    static func prepare(_ data: Data, filename: String) async -> PreparedPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // Orientations 5–8 turn the picture on its side.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension.lowercased()
        let preview = previewData(from: source)
        // By what the bytes are, not the name, which can say HEIC for a JPEG.
        let format = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)
        if let format, let web = webTypes.first(where: { format.conforms(to: $0.type) }),
           data.count <= largestKeptBytes, max(width, height) <= largestKeptSide {
            let name = web.extensions.contains(ext) ? filename : (base.isEmpty ? "photo" : base) + "." + web.extensions[0]
            return PreparedPhoto(data: data, filename: name, mimeType: web.mime, pixelWidth: width, pixelHeight: height, preview: preview)
        }
        let longest = min(max(width, height), reducedSide)
        guard let image = upright(source, maxPixels: longest),
              let jpeg = encode(image, as: .jpeg, quality: 0.85) else { return nil }
        return PreparedPhoto(data: jpeg, filename: (base.isEmpty ? "photo" : base) + ".jpg", mimeType: "image/jpeg",
                             pixelWidth: image.width, pixelHeight: image.height, preview: preview)
    }

    /// A file's image, upright and no more than `maxPixels` on its long side.
    @concurrent
    static func preview(of file: URL, maxPixels: Int) async -> PlatformImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = upright(source, maxPixels: maxPixels) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        #else
        return UIImage(cgImage: image)
        #endif
    }

    /// Small JPEG of an image, to show while it uploads.
    private static func previewData(from source: CGImageSource) -> Data? {
        upright(source, maxPixels: 600).flatMap { encode($0, as: .jpeg, quality: 0.8) }
    }

    private static func upright(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
