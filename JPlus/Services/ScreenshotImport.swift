import AppKit
import UniformTypeIdentifiers

/// An image ready to attach to a ticket, plus a downscaled PNG for analysis.
struct Screenshot: Hashable, Sendable {
    let data: Data
    let filename: String
    let mimeType: String
    let pixelSize: CGSize

    var image: NSImage? { NSImage(data: data) }

    /// Builds from raw bytes. Formats Jira and browsers handle natively are
    /// kept as-is; anything else (TIFF from the pasteboard, HEIC, …) is
    /// re-encoded as PNG.
    init?(data: Data, filename: String) {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let ext = (filename as NSString).pathExtension.lowercased()
        let keepAsIs: [String: String] = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]

        if let mime = keepAsIs[ext] {
            self.data = data
            self.filename = filename
            self.mimeType = mime
        } else {
            guard let png = ScreenshotImport.pngData(from: cgImage, maxDimension: nil) else { return nil }
            self.data = png
            self.filename = ((filename as NSString).deletingPathExtension) + ".png"
            self.mimeType = "image/png"
        }
        self.pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
    }

    /// PNG no larger than 1568px on its long edge, which is what vision
    /// models work best with and keeps the upload small.
    func pngForAnalysis() -> Data? {
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return ScreenshotImport.pngData(from: cgImage, maxDimension: 1568)
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

    static func pngData(from cgImage: CGImage, maxDimension: CGFloat?) -> Data? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        var scale: CGFloat = 1
        if let maxDimension, max(width, height) > maxDimension {
            scale = maxDimension / max(width, height)
        }

        let target: CGImage
        if scale < 1 {
            let newWidth = Int(width * scale)
            let newHeight = Int(height * scale)
            guard let context = CGContext(
                data: nil, width: newWidth, height: newHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
            guard let scaled = context.makeImage() else { return nil }
            target = scaled
        } else {
            target = cgImage
        }
        return NSBitmapImageRep(cgImage: target).representation(using: .png, properties: [:])
    }

    private static func defaultFilename(for type: UTType) -> String {
        let stamp = Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "/", with: "-")
        let ext = type.preferredFilenameExtension ?? "png"
        return "Screenshot \(stamp).\(ext)"
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
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

    private static func loadData(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
