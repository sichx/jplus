#if os(iOS)
import PhotosUI
#endif
import SwiftUI
import UniformTypeIdentifiers

/// Photos (iOS), Choose… and Paste buttons that pick images and videos,
/// several at a time. Meant to sit in an `HStack`.
struct AddMediaButtons: View {
    /// Called with what was picked; never with an empty list.
    let onAdd: ([PendingAttachment]) -> Void
    let onFailure: (String) -> Void
    /// Gives Paste ⇧⌘V; only one screen at a time should.
    var pasteShortcut = false

    @State private var showingFileImporter = false
    #if os(iOS)
    @State private var photoItems: [PhotosPickerItem] = []
    #endif

    var body: some View {
        #if os(iOS)
        PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos])) {
            Label("Photos", systemImage: "photo")
        }
        .help("Add photos or videos from Photos")
        .onChange(of: photoItems) {
            guard !photoItems.isEmpty else { return }
            let items = photoItems
            photoItems = []
            Task { await importPhotos(items) }
        }
        #endif
        Button("Choose…", systemImage: "folder") { showingFileImporter = true }
            .help("Add images or videos from files")
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: MediaImport.pickableTypes,
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task {
                    deliver(await MediaImport.load(urls: urls),
                            failureMessage: urls.count == 1 ? "That file isn't an image or video the app can read."
                                                            : "None of those files are images or videos the app can read.")
                }
            }
        pasteButton
    }

    @ViewBuilder
    private var pasteButton: some View {
        let button = Button("Paste", systemImage: "doc.on.clipboard") {
            Task {
                deliver(await MediaImport.loadFromPasteboard(),
                        failureMessage: "The clipboard doesn't contain an image or video.")
            }
        }
        .help("Add an image or video from the clipboard")
        if pasteShortcut {
            button.keyboardShortcut("v", modifiers: [.command, .shift])
        } else {
            button
        }
    }

    private func deliver(_ items: [PendingAttachment], failureMessage: String) {
        if items.isEmpty {
            onFailure(failureMessage)
        } else {
            onAdd(items)
        }
    }

    #if os(iOS)
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var found: [PendingAttachment] = []
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self),
                   let clip = await VideoClip.make(from: movie.url, moving: true) {
                    found.append(PendingAttachment(media: .video(clip)))
                }
            } else {
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
                if let data = try? await item.loadTransferable(type: Data.self),
                   let shot = Screenshot(data: data, filename: "Photo.\(ext)") {
                    found.append(PendingAttachment(media: .image(shot)))
                }
            }
        }
        deliver(found, failureMessage: items.count == 1 ? "That photo or video couldn't be read." : "Those photos and videos couldn't be read.")
    }
    #endif
}

/// One image or video waiting to be attached: a thumbnail with its name,
/// size and a remove button.
struct PendingAttachmentTile: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    @State private var thumbnail: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle().fill(.quaternary.opacity(0.5))
                if let thumbnail {
                    Image(platformImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: attachment.isVideo ? "film" : "photo")
                        .scaledFont(.title2)
                        .foregroundStyle(.secondary)
                }
                if attachment.isVideo {
                    Image(systemName: "play.circle.fill")
                        .scaledFont(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
            }
            .frame(height: 100)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .scaledFont(.title3)
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Remove \(attachment.filename)")
            }

            Text(attachment.filename)
                .scaledFont(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(attachment.detail)
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .task(id: attachment.id) { thumbnail = attachment.thumbnail }
    }
}
