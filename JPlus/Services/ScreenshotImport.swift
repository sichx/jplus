#if os(macOS)
import AppKit
#else
import UIKit
#endif
import ImageIO
import UniformTypeIdentifiers

/// An image ready to attach to a ticket, plus a downscaled PNG for analysis.
struct Screenshot: Hashable, Sendable {
    let data: Data
    let filename: String
    let mimeType: String
    let pixelSize: CGSize

    var image: PlatformImage? { PlatformImage(data: data) }

    /// Builds from raw bytes. Formats Jira and browsers handle natively are
    /// kept as-is; anything else (TIFF from the pasteboard, HEIC, …) is
    /// re-encoded as PNG.
    init?(data: Data, filename: String) {
        guard let cgImage = ScreenshotImport.cgImage(from: data) else { return nil }

        let ext = (filename as NSString).pathExtension.lowercased()
        let keepAsIs: [String: String] = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]

        if let mime = keepAsIs[ext] {
            self.data = data
            self.filename = filename
            self.mimeType = mime
        } else {
            guard let png = ScreenshotImport.pngData(from: cgImage) else { return nil }
            self.data = png
            self.filename = ((filename as NSString).deletingPathExtension) + ".png"
            self.mimeType = "image/png"
        }
        self.pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
    }

    /// PNG no larger than 1568px on its long edge, which is what vision
    /// models work best with and keeps the upload small.
    func pngForAnalysis() -> Data? {
        guard let cgImage = ScreenshotImport.cgImage(from: data, maxDimension: 1568) else { return nil }
        return ScreenshotImport.pngData(from: cgImage)
    }

    var sizeDescription: String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        return "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) · \(bytes)"
    }
}

enum ScreenshotImport {
    static let acceptedTypes: [UTType] = [.fileURL, .png, .jpeg, .tiff, .image]

    /// Handles drops and paste commands (Finder files, browser images, ⌘⇧4 captures).
    static func load(from providers: [NSItemProvider]) async -> Screenshot? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadFileURL(from: provider), let shot = load(url: url) {
                return shot
            }
        }
        for provider in providers {
            for type in [UTType.png, .jpeg, .tiff, .image]
            where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let data = await loadData(from: provider, type: type),
                   let shot = Screenshot(data: data, filename: defaultFilename(for: type)) {
                    return shot
                }
            }
        }
        return nil
    }

    static func load(url: URL) -> Screenshot? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Screenshot(data: data, filename: url.lastPathComponent)
    }

    #if os(macOS)
    /// Reads an image from the pasteboard (used by the Paste button and ⌘V).
    static func loadFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Screenshot? {
        for url in imageFileURLs(on: pasteboard) {
            if let shot = load(url: url) { return shot }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type),
               let shot = Screenshot(data: data, filename: defaultFilename(for: type == .png ? .png : .tiff)) {
                return shot
            }
        }
        return nil
    }

    /// Whether ⌘V should attach an image instead of pasting text.
    /// - An image on the clipboard with no real text: take the image.
    /// - An image file copied in Finder (its only text is the filename): take the image.
    /// - Image and real text while typing in a field: leave it to the field.
    static func shouldPasteImage(from pasteboard: NSPasteboard = .general, isEditingText: Bool) -> Bool {
        let hasImageFile = !imageFileURLs(on: pasteboard).isEmpty
        let hasImageData = pasteboard.availableType(from: [.png, .tiff]) != nil
        guard hasImageFile || hasImageData else { return false }
        if hasImageFile { return true }
        let hasText = !(pasteboard.string(forType: .string) ?? "").isEmpty
        return !(hasText && isEditingText)
    }

    private static func imageFileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image)
        }
    }
    #else
    /// Reads an image from the clipboard (used by the Paste button).
    static func loadFromPasteboard(_ pasteboard: UIPasteboard = .general) -> Screenshot? {
        for type in [UTType.png, .jpeg, .heic, .tiff] {
            if let data = pasteboard.data(forPasteboardType: type.identifier),
               let shot = Screenshot(data: data, filename: defaultFilename(for: type)) {
                return shot
            }
        }
        if let png = pasteboard.image?.pngData() {
            return Screenshot(data: png, filename: defaultFilename(for: .png))
        }
        return nil
    }
    #endif

    /// Decodes an image, upright (photos carry their rotation as metadata),
    /// and no larger than `maxDimension` on its long edge if given.
    static func cgImage(from data: Data, maxDimension: CGFloat? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxDimension { options[kCGImageSourceThumbnailMaxPixelSize] = maxDimension }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated static func pngData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func defaultFilename(for type: UTType) -> String {
        let stamp = Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: "-")
        let ext = type.preferredFilenameExtension ?? "png"
        return "Screenshot \(stamp).\(ext)"
    }

    static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    static func loadData(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
