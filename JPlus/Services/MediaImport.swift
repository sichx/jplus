#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import CoreTransferable
import ImageIO
import UniformTypeIdentifiers

/// A video ready to attach to a ticket. Videos can be large, so they aren't
/// held in memory: each is copied into the app's temporary folder when
/// picked, which also keeps it readable after a drop or picker has let go of
/// the original, and read from there when uploaded.
nonisolated struct VideoClip: Hashable, Sendable {
    let fileURL: URL
    let filename: String
    let mimeType: String
    let byteCount: Int64
    let duration: TimeInterval?
    let pixelSize: CGSize?
    /// PNG of the first frame, small enough for a thumbnail.
    let posterPNG: Data?

    /// Copies the video at `url` into the temporary folder (or moves it there
    /// when `moving`, for a file the app already owns) and reads its length,
    /// size and first frame. Nil if it isn't a video the system can read.
    @concurrent
    static func make(from url: URL, filename: String? = nil, moving: Bool = false) async -> VideoClip? {
        let name = filename ?? url.lastPathComponent
        let folder = MediaImport.pendingFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(path: name.isEmpty ? "Video.mov" : name, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if moving {
                try FileManager.default.moveItem(at: url, to: file)
            } else {
                try FileManager.default.copyItem(at: url, to: file)
            }
        } catch {
            return nil
        }

        let asset = AVURLAsset(url: file)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        let duration = try? await asset.load(.duration)
        var pixelSize: CGSize?
        if let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let upright = size.applying(transform)
            pixelSize = CGSize(width: abs(upright.width), height: abs(upright.height))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let poster = try? await generator.image(at: .zero).image

        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        let ext = file.pathExtension
        return VideoClip(
            fileURL: file,
            filename: file.lastPathComponent,
            mimeType: UTType(filenameExtension: ext)?.preferredMIMEType ?? "video/quicktime",
            byteCount: bytes,
            duration: duration.map(\.seconds).flatMap { $0.isFinite ? $0 : nil },
            pixelSize: pixelSize,
            posterPNG: poster.flatMap(ScreenshotImport.pngData(from:))
        )
    }

    /// Deletes the temporary copy.
    func discard() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    /// "0:42"
    var durationDescription: String? {
        guard let duration else { return nil }
        return Duration.seconds(duration.rounded()).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// An image or video waiting to be attached to a ticket.
struct PendingAttachment: Identifiable, Hashable, Sendable {
    enum Media: Hashable, Sendable {
        case image(Screenshot)
        case video(VideoClip)
    }

    let id = UUID()
    let media: Media

    var filename: String {
        switch media {
        case .image(let shot): shot.filename
        case .video(let clip): clip.filename
        }
    }

    var mimeType: String {
        switch media {
        case .image(let shot): shot.mimeType
        case .video(let clip): clip.mimeType
        }
    }

    var isVideo: Bool {
        if case .video = media { return true }
        return false
    }

    /// The image, for drafting with Claude; nil for a video.
    var screenshot: Screenshot? {
        if case .image(let shot) = media { return shot }
        return nil
    }

    /// The image itself, or a video's first frame.
    var thumbnail: PlatformImage? {
        switch media {
        case .image(let shot): shot.image
        case .video(let clip): clip.posterPNG.flatMap(PlatformImage.decoded(from:))
        }
    }

    /// "1920 × 1080 · 2.4 MB", with the length first for a video.
    var detail: String {
        switch media {
        case .image(let shot):
            return shot.sizeDescription
        case .video(let clip):
            var parts: [String] = []
            if let length = clip.durationDescription { parts.append(length) }
            if let size = clip.pixelSize { parts.append("\(Int(size.width)) × \(Int(size.height))") }
            parts.append(ByteCountFormatter.string(fromByteCount: clip.byteCount, countStyle: .file))
            return parts.joined(separator: " · ")
        }
    }

    /// The bytes to upload.
    func contents() async throws -> Data {
        switch media {
        case .image(let shot):
            return shot.data
        case .video(let clip):
            let url = clip.fileURL
            return try await Task.detached { try Data(contentsOf: url, options: .mappedIfSafe) }.value
        }
    }

    /// Deletes any temporary copy, once it's uploaded or no longer wanted.
    func discard() {
        if case .video(let clip) = media { clip.discard() }
    }
}

/// Images and videos from drops, pastes, file pickers and Photos.
enum MediaImport {
    /// What a drop or paste can carry.
    static let acceptedTypes: [UTType] = [.fileURL, .png, .jpeg, .tiff, .image, .movie]
    /// What the file picker offers.
    static let pickableTypes: [UTType] = [.image, .movie]

    /// Where picked videos wait to be uploaded.
    nonisolated static var pendingFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: "PendingUploads", directoryHint: .isDirectory)
    }

    /// Everything readable among dropped or pasted items, in order.
    static func load(from providers: [NSItemProvider]) async -> [PendingAttachment] {
        var found: [PendingAttachment] = []
        for provider in providers {
            if let item = await load(from: provider) { found.append(item) }
        }
        return found
    }

    private static func load(from provider: NSItemProvider) async -> PendingAttachment? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await ScreenshotImport.loadFileURL(from: provider),
           let item = await load(url: url) {
            return item
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
           let clip = await loadMovie(from: provider) {
            return PendingAttachment(media: .video(clip))
        }
        for type in [UTType.png, .jpeg, .tiff, .image] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await ScreenshotImport.loadData(from: provider, type: type),
               let shot = Screenshot(data: data, filename: provider.suggestedName.map { "\($0).\(type.preferredFilenameExtension ?? "png")" }
                                        ?? ScreenshotImport.defaultFilename(for: type)) {
                return PendingAttachment(media: .image(shot))
            }
        }
        return nil
    }

    /// An image or video file. Nil for anything else.
    static func load(url: URL) async -> PendingAttachment? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
            return await VideoClip.make(from: url).map { PendingAttachment(media: .video($0)) }
        }
        return ScreenshotImport.load(url: url).map { PendingAttachment(media: .image($0)) }
    }

    static func load(urls: [URL]) async -> [PendingAttachment] {
        var found: [PendingAttachment] = []
        for url in urls {
            if let item = await load(url: url) { found.append(item) }
        }
        return found
    }

    /// A movie handed over as data rather than as a file on disk. The
    /// provider's copy is deleted when its callback returns, so it's moved
    /// somewhere of our own inside the callback.
    private static func loadMovie(from provider: NSItemProvider) async -> VideoClip? {
        let suggested = provider.suggestedName
        let kept: URL? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                let copy = folder.appending(path: url.lastPathComponent, directoryHint: .notDirectory)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
        guard let kept else { return nil }
        defer { try? FileManager.default.removeItem(at: kept.deletingLastPathComponent()) }
        let name = suggested.map { "\($0).\(kept.pathExtension)" }
        return await VideoClip.make(from: kept, filename: name, moving: true)
    }

    #if os(macOS)
    /// Images and videos on the pasteboard: copied files first, else a
    /// copied image (used by the Paste button and ⌘V).
    static func loadFromPasteboard(_ pasteboard: NSPasteboard = .general) async -> [PendingAttachment] {
        let files = await load(urls: mediaFileURLs(on: pasteboard))
        if !files.isEmpty { return files }
        return ScreenshotImport.loadFromPasteboard(pasteboard).map { [PendingAttachment(media: .image($0))] } ?? []
    }

    /// Whether ⌘V should attach media instead of pasting text. As for
    /// screenshots, plus copied video files.
    static func shouldPaste(from pasteboard: NSPasteboard = .general, isEditingText: Bool) -> Bool {
        !mediaFileURLs(on: pasteboard).isEmpty
            || ScreenshotImport.shouldPasteImage(from: pasteboard, isEditingText: isEditingText)
    }

    private static func mediaFileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video)
        }
    }
    #else
    /// An image or video on the clipboard (used by the Paste button).
    static func loadFromPasteboard(_ pasteboard: UIPasteboard = .general) async -> [PendingAttachment] {
        if let shot = ScreenshotImport.loadFromPasteboard(pasteboard) {
            return [PendingAttachment(media: .image(shot))]
        }
        for type in [UTType.mpeg4Movie, .quickTimeMovie, .movie] {
            guard let data = pasteboard.data(forPasteboardType: type.identifier) else { continue }
            let file = FileManager.default.temporaryDirectory
                .appending(path: "Pasted Video.\(type.preferredFilenameExtension ?? "mov")", directoryHint: .notDirectory)
            guard (try? data.write(to: file)) != nil else { continue }
            if let clip = await VideoClip.make(from: file, moving: true) {
                return [PendingAttachment(media: .video(clip))]
            }
        }
        return []
    }
    #endif
}

/// A video from the Photos picker, delivered as a file.
nonisolated struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            // The received file is deleted afterwards, so keep a copy.
            let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let copy = folder.appending(path: received.file.lastPathComponent, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
