import PhotosUI
import QuickLook
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// An item's photos, small, under its text. Each opens full size in Quick
/// Look, and its menu takes it off the page. Photos still uploading show
/// from the picked image, dimmed, with a spinner.
struct PriorityPhotoStrip: View {
    let photos: [PriorityPhoto]
    let uploads: [PriorityPhotoUpload]
    let item: PriorityItem
    let day: PriorityDay
    let model: PrioritiesModel
    /// Not while the item is saving or moving.
    let canRemove: Bool

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(photos) { photo in
                PriorityPhotoThumbnail(photo: photo, item: item, day: day, model: model, canRemove: canRemove)
            }
            ForEach(uploads) { upload in
                PriorityUploadThumbnail(upload: upload)
            }
        }
    }
}

/// How big photos show under a priority: a fixed height, and the width
/// their shape gives, within limits.
private enum PhotoThumbnailSize {
    #if os(iOS)
    static let height: CGFloat = 100
    #else
    static let height: CGFloat = 120
    #endif
    static let minWidth: CGFloat = 60
    static let maxWidth: CGFloat = 260
    /// Pixels on the long side of the copy decoded for one: enough for a
    /// Retina screen at the largest it shows.
    static let previewPixels = 600

    static func width(for aspectRatio: CGFloat) -> CGFloat {
        min(max(height * aspectRatio, minWidth), maxWidth)
    }
}

/// One photo on the page, downloaded once and shown small.
private struct PriorityPhotoThumbnail: View {
    let photo: PriorityPhoto
    let item: PriorityItem
    let day: PriorityDay
    let model: PrioritiesModel
    let canRemove: Bool

    @State private var image: PlatformImage?
    @State private var failure: String?
    @State private var isOpening = false
    @Environment(PriorityDrafts.self) private var drafts

    private var aspectRatio: CGFloat {
        if let ratio = photo.aspectRatio { return ratio }
        if let image, image.size.height > 0 { return image.size.width / image.size.height }
        return 4 / 3
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failure != nil {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .imageScale(.large)
                    Text(photo.filename ?? "Photo")
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
            } else {
                ProgressView().controlSize(.small)
            }
            if isOpening {
                Rectangle().fill(.black.opacity(0.25))
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: PhotoThumbnailSize.width(for: aspectRatio), height: PhotoThumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: open)
        .contextMenu {
            Button("Open", systemImage: "eye", action: open)
            Divider()
            Button("Remove Photo", systemImage: "trash", role: .destructive) {
                model.removePhoto(photo, from: item, in: day)
            }
            .disabled(!canRemove)
        }
        .help(failure ?? photo.filename ?? "Photo")
        .accessibilityElement()
        .accessibilityLabel(photo.filename.map { "Photo, \($0)" } ?? "Photo")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open", open)
        .task(id: photo.fileID) { await load() }
    }

    private func load() async {
        do {
            image = try await model.preview(of: photo, onPage: day.pageID, maxPixels: PhotoThumbnailSize.previewPixels)
            failure = nil
        } catch where error.isCancellation {
            return
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Downloads it full size, if it isn't already, and opens it in Quick Look.
    private func open() {
        guard !isOpening else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            do {
                drafts.previewURL = try await model.file(of: photo, onPage: day.pageID)
            } catch where error.isCancellation {
                return
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// A photo uploading: the picked image, dimmed, with a spinner.
private struct PriorityUploadThumbnail: View {
    let upload: PriorityPhotoUpload

    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.5)
            }
            ProgressView().controlSize(.small)
        }
        .frame(width: PhotoThumbnailSize.width(for: upload.aspectRatio), height: PhotoThumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .help("Uploading \(upload.filename)…")
        .accessibilityElement()
        .accessibilityLabel("Uploading photo, \(upload.filename)")
        .task(id: upload.id) {
            image = upload.preview.flatMap(PlatformImage.decoded(from:))
        }
    }
}

/// The pickers an item's Add Photo opens, and Quick Look for opening one,
/// once for the whole pane: a row asks through the drafts, naming itself.
struct PriorityPhotoPickers: ViewModifier {
    let model: PrioritiesModel
    let drafts: PriorityDrafts

    /// The item the open picker is for. Kept after the picker closes, which
    /// can come before its result does.
    @State private var target: PriorityPhotoPick?
    #if os(iOS)
    @State private var libraryPicks: [PhotosPickerItem] = []
    #endif

    func body(content: Content) -> some View {
        content
            .onChange(of: drafts.photoPick) {
                if let pick = drafts.photoPick { target = pick }
            }
            .fileImporter(isPresented: isPicking(from: .files), allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                guard let target, case .success(let urls) = result else { return }
                var images: [(data: Data, filename: String)] = []
                for url in urls {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) { images.append((data, url.lastPathComponent)) }
                }
                Task { await model.addPhotos(images, skipped: urls.count - images.count, to: target.item, in: target.day) }
            }
            #if os(iOS)
            .photosPicker(isPresented: isPicking(from: .library), selection: $libraryPicks, maxSelectionCount: 10,
                          selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .compatible)
            .onChange(of: libraryPicks) {
                guard !libraryPicks.isEmpty, let target else { return }
                let picked = libraryPicks
                libraryPicks = []
                Task {
                    var images: [(data: Data, filename: String)] = []
                    for (index, item) in picked.enumerated() {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        images.append((data, Self.photoName(extension: ext, index: index)))
                    }
                    await model.addPhotos(images, skipped: picked.count - images.count, to: target.item, in: target.day)
                }
            }
            .fullScreenCover(isPresented: isPicking(from: .camera)) {
                PriorityCameraPicker { image in
                    drafts.photoPick = nil
                    guard let target, let data = image?.jpegData(compressionQuality: 0.9) else { return }
                    Task { await model.addPhotos([(data, Self.photoName(extension: "jpg", index: 0))], to: target.item, in: target.day) }
                }
                .ignoresSafeArea()
            }
            #endif
            .quickLookPreview(Binding(get: { drafts.previewURL }, set: { drafts.previewURL = $0 }))
    }

    /// Whether the picker for `source` is open; closing it ends the pick.
    private func isPicking(from source: PriorityPhotoPick.Source) -> Binding<Bool> {
        Binding(
            get: { drafts.photoPick?.source == source },
            set: { open in
                if !open, drafts.photoPick?.source == source { drafts.photoPick = nil }
            }
        )
    }

    /// A name for a photo that came without one, as Confluence names an
    /// image pasted into its editor: `photo-20261106-142530.jpg`.
    private static func photoName(extension ext: String, index: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = index > 0 ? "-\(index + 1)" : ""
        return "photo-\(formatter.string(from: Date()))\(suffix).\(ext)"
    }
}

#if os(iOS)
/// The camera, for a photo to put under a priority. It hands back the photo,
/// or nil when cancelled.
struct PriorityCameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let onFinish: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (UIImage?) -> Void

        init(onFinish: @escaping (UIImage?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
#endif
