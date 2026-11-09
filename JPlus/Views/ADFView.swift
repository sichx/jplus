import SwiftUI

/// Renders an Atlassian Document Format tree with native SwiftUI views.
/// Covers the node types that show up in ordinary issue descriptions and
/// comments; anything unknown falls back to rendering its children.
struct ADFView: View {
    let node: ADFNode

    @Environment(\.adfMedia) private var media
    @Environment(\.openURL) private var openURL

    var body: some View {
        ADFBlocks(nodes: node.type == "doc" ? node.children : [node])
            .environment(\.openURL, media == nil ? openURL : OpenURLAction { url in
                // Links to this issue's attachments preview in the app; every other link goes on as before.
                if let media, let attachment = media.attachment(linkedBy: url) {
                    Task { await media.preview(attachment) }
                } else {
                    openURL(url)
                }
                return .handled
            })
    }
}

/// What ADF media nodes need to show an issue's attachments. The issue
/// detail provides it; without it, media nodes render as plain labels.
struct ADFMediaContext {
    let client: JiraClient
    let attachments: [JiraIssue.Attachment]
    /// Media file id → attachment id, from the GraphQL gateway.
    let attachmentIDsByMediaID: [String: String]
    /// Opens an attachment in Quick Look.
    let preview: @MainActor (JiraIssue.Attachment) async -> Void

    /// Matches on media id when the gateway supplied the mapping, otherwise
    /// on file name, which Jira's editor uses as an image's alt text.
    func attachment(for media: ADFNode) -> JiraIssue.Attachment? {
        if let mediaID = media.attr("id"), let attachmentID = attachmentIDsByMediaID[mediaID],
           let attachment = attachments.first(where: { $0.id == attachmentID }) {
            return attachment
        }
        guard let alt = media.attr("alt") else { return nil }
        return attachments.first { $0.filename == alt }
    }

    /// The attachment a `…/secure/attachment/<id>/…` link on this site points to.
    func attachment(linkedBy url: URL) -> JiraIssue.Attachment? {
        let parts = url.pathComponents
        guard url.host() == client.credentials.siteURL.host(), parts.count >= 4,
              parts[1] == "secure", parts[2] == "attachment" else { return nil }
        return attachments.first { $0.id == parts[3] }
    }
}

/// What ADF media nodes need to show files attached in Confluence: the
/// images in a priority's comments, which are drawn small, side by side,
/// and open full size in Quick Look.
struct ADFConfluenceFiles: Equatable {
    /// Tells one set of files from another, as closures can't be compared:
    /// the site and the content they're attached to.
    let id: String
    let client: JiraClient
    /// The attachment a `media` node shows.
    let attachment: @MainActor (ADFNode) async throws -> ConfluenceAttachment
    /// Opens a downloaded file in Quick Look.
    let preview: @MainActor (URL) -> Void

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

extension EnvironmentValues {
    @Entry var adfMedia: ADFMediaContext? = nil
    @Entry var adfConfluenceFiles: ADFConfluenceFiles? = nil
}

private struct ADFBlocks: View {
    let nodes: [ADFNode]

    @Environment(\.adfConfluenceFiles) private var confluenceFiles

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.runs(of: nodes, groupingImages: confluenceFiles != nil).enumerated()), id: \.offset) { _, run in
                switch run {
                case .text(let nodes): ADFTextRun(nodes: nodes)
                case .block(let node): ADFBlock(node: node)
                case .images(let media):
                    FlowLayout(spacing: 8) {
                        ForEach(Array(media.enumerated()), id: \.offset) { _, image in
                            ADFMediaView(media: image.media, maxWidth: image.width)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Run {
        case text([ADFNode])
        case block(ADFNode)
        /// Images on lines of their own, one after another, by their `media`
        /// nodes, each with the width its block gives it.
        case images([(media: ADFNode, width: CGFloat?)])
    }

    /// Consecutive paragraphs, headings and lists go together, so they
    /// render as one Text. With `groupingImages`, consecutive uncaptioned
    /// images go together too, to sit side by side as they're drawn small.
    private static func runs(of nodes: [ADFNode], groupingImages: Bool) -> [Run] {
        var runs: [Run] = []
        for node in nodes {
            if groupingImages, let media = ADFMediaSingle.uncaptionedFile(in: node) {
                let image = (media: media, width: ADFMediaSingle.width(of: media, in: node))
                if case .images(let previous) = runs.last {
                    runs[runs.count - 1] = .images(previous + [image])
                } else {
                    runs.append(.images([image]))
                }
                continue
            }
            guard ADFTextRun.canInclude(node) else {
                runs.append(.block(node))
                continue
            }
            if case .text(let previous) = runs.last {
                runs[runs.count - 1] = .text(previous + [node])
            } else {
                runs.append(.text([node]))
            }
        }
        return runs
    }
}

/// Paragraphs, headings and lists in a row, drawn as a single Text: SwiftUI
/// can't extend a selection from one Text into the next, so this lets a drag
/// select across them. Text can't hang-indent, so a wrapped list item
/// continues at the margin.
private struct ADFTextRun: View {
    private static let listTypes: Set<String> = ["bulletList", "orderedList", "taskList"]

    /// Whether `node` can be drawn as text: lists qualify unless an item holds
    /// a code block, table, image or the like.
    static func canInclude(_ node: ADFNode) -> Bool {
        switch node.type {
        case "paragraph", "heading":
            return true
        case _ where listTypes.contains(node.type):
            return node.children.allSatisfy { item in
                if listTypes.contains(item.type) { return canInclude(item) }
                if item.type == "taskItem" { return item.children.allSatisfy(ADFInline.isInline) }
                return item.children.allSatisfy(canInclude)
            }
        default:
            return false
        }
    }

    let nodes: [ADFNode]

    @Environment(\.adfMedia) private var media
    @Environment(\.textSizeScale) private var textScale
    @Environment(\.appFont) private var appFont

    var body: some View {
        Text(attributedString).textSelection(.enabled)
    }

    /// One paragraph of the text: indented `level` steps, after a marker if
    /// it starts a list item, and `gap` points below the line before it.
    private struct Line {
        var text: AttributedString
        var level = 0
        var marker: AttributedString?
        var gap: CGFloat = 5
    }

    private var attributedString: AttributedString {
        var result = AttributedString()
        let lines = nodes.flatMap { node in
            var lines = self.lines(of: node, level: 0)
            // A list's first item sits a block's distance from what's above it.
            if !lines.isEmpty { lines[0].gap = max(lines[0].gap, 5) }
            return lines
        }
        for (index, line) in lines.enumerated() {
            if index > 0 {
                // A short blank line stands in for the spacing between views.
                result += AttributedString("\n")
                var gap = AttributedString("\n")
                gap.font = .system(size: line.gap * textScale)
                result += gap
            }
            result += AttributedString(String(repeating: "    ", count: line.level))
            if let marker = line.marker { result += marker + AttributedString("  ") }
            result += line.text
        }
        return result
    }

    private func lines(of node: ADFNode, level: Int) -> [Line] {
        switch node.type {
        case "heading":
            var text = inline(node.children)
            let font = headingFont(level: node.intAttr("level") ?? 3).font(scale: textScale, family: appFont)
            // Status lozenges keep their own font.
            for range in text.runs.filter({ $0.font == nil }).map(\.range) {
                text[range].font = font
            }
            return [Line(text: text, level: level, gap: 9)]

        case _ where Self.listTypes.contains(node.type):
            let start = node.intAttr("order") ?? 1
            return node.children.enumerated().flatMap { index, item -> [Line] in
                // A task list nests by holding another task list among its items.
                if Self.listTypes.contains(item.type) {
                    return lines(of: item, level: level + 1).map { line in
                        var line = line
                        line.gap = 2
                        return line
                    }
                }
                var content = item.type == "taskItem"
                    ? [Line(text: inline(item.children), level: level + 1)]
                    : item.children.flatMap { lines(of: $0, level: level + 1) }
                if content.isEmpty { content = [Line(text: AttributedString(), level: level + 1)] }
                for i in content.indices { content[i].gap = 2 }
                content[0].level = level
                content[0].marker = marker(for: node, item: item, number: start + index)
                return content
            }

        default:
            return [Line(text: inline(node.children), level: level)]
        }
    }

    private func marker(for list: ADFNode, item: ADFNode, number: Int) -> AttributedString {
        switch list.type {
        case "orderedList":
            var marker = AttributedString("\(number).")
            marker.foregroundColor = .secondary
            return marker
        case "taskList":
            let isDone = item.attr("state") == "DONE"
            var marker = AttributedString(isDone ? "☑" : "☐")
            marker.foregroundColor = isDone ? .accentColor : .secondary
            return marker
        default:
            var marker = AttributedString("•")
            marker.foregroundColor = .secondary
            return marker
        }
    }

    private func inline(_ nodes: [ADFNode]) -> AttributedString {
        ADFInline.attributedString(nodes, media: media, textScale: textScale, font: appFont)
    }
}

private func headingFont(level: Int) -> ScaledFont {
    switch level {
    case 1: return .title.weight(.bold)
    case 2: return .title2.weight(.semibold)
    case 3: return .title3.weight(.semibold)
    default: return .headline
    }
}

private struct ADFBlock: View {
    let node: ADFNode

    @Environment(\.adfMedia) private var media
    @Environment(\.textSizeScale) private var textScale
    @Environment(\.appFont) private var appFont

    var body: some View {
        // Paragraphs and headings are drawn by ADFTextRun.
        switch node.type {
        case "bulletList":
            listView(items: node.children) { _ in Text("•") }

        case "orderedList":
            let start = node.intAttr("order") ?? 1
            listView(items: node.children) { index in Text("\(start + index).") }

        case "codeBlock":
            ScrollView(.horizontal) {
                Text(node.children.map(\.plainText).joined())
                    .scaledFont(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

        case "blockquote":
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(width: 3)
                ADFBlocks(nodes: node.children)
            }
            .fixedSize(horizontal: false, vertical: true)

        case "rule":
            Divider()

        case "panel":
            let style = PanelStyle(type: node.attr("panelType"))
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.symbol).foregroundStyle(style.color)
                ADFBlocks(nodes: node.children)
            }
            .padding(10)
            .background(style.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

        case "table":
            tableView(rows: node.children)

        case "mediaSingle":
            ADFMediaSingle(node: node)

        case "mediaGroup":
            FlowLayout(spacing: 8) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, media in
                    ADFMediaView(media: media, isThumbnail: true)
                }
            }

        case "media", "mediaInline":
            ADFMediaView(media: node)

        case "taskList":
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.attr("state") == "DONE" ? "checkmark.square.fill" : "square")
                            .foregroundStyle(item.attr("state") == "DONE" ? Color.accentColor : .secondary)
                        Text(ADFInline.attributedString(item.children, media: media, textScale: textScale, font: appFont)).textSelection(.enabled)
                    }
                }
            }

        case "expand", "nestedExpand":
            DisclosureGroup(node.attr("title") ?? "Details") {
                ADFBlocks(nodes: node.children).padding(.top, 4)
            }

        default:
            if node.children.isEmpty {
                if let text = node.text, !text.isEmpty {
                    Text(text)
                }
            } else if node.children.allSatisfy(ADFInline.isInline) {
                Text(ADFInline.attributedString(node.children, media: media, textScale: textScale, font: appFont)).textSelection(.enabled)
            } else {
                ADFBlocks(nodes: node.children)
            }
        }
    }

    private func listView<Marker: View>(items: [ADFNode], @ViewBuilder marker: @escaping (Int) -> Marker) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(index)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                    ADFBlocks(nodes: item.children)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func tableView(rows: [ADFNode]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.children.enumerated()), id: \.offset) { _, cell in
                            ADFBlocks(nodes: cell.children)
                                .scaledFont(cell.type == "tableHeader" ? .body.weight(.semibold) : .body)
                                .padding(8)
                                .frame(minWidth: 80, alignment: .topLeading)
                                .background(cell.type == "tableHeader" ? Color.secondary.opacity(0.1) : .clear)
                                .border(Color.secondary.opacity(0.25), width: 0.5)
                        }
                    }
                }
            }
        }
    }

    private struct PanelStyle {
        let symbol: String
        let color: Color

        init(type: String?) {
            switch type {
            case "warning": (symbol, color) = ("exclamationmark.triangle.fill", .orange)
            case "error":   (symbol, color) = ("xmark.octagon.fill", .red)
            case "success": (symbol, color) = ("checkmark.circle.fill", .green)
            case "note":    (symbol, color) = ("note.text", .purple)
            default:        (symbol, color) = ("info.circle.fill", .blue)
            }
        }
    }
}

// MARK: - Media

/// An image or file on its own line, sized and aligned as in Jira.
private struct ADFMediaSingle: View {
    let node: ADFNode

    @Environment(\.adfMedia) private var media
    @Environment(\.textSizeScale) private var textScale
    @Environment(\.appFont) private var appFont

    var body: some View {
        VStack(alignment: alignment.horizontal, spacing: 4) {
            if let item = node.children.first(where: { $0.type == "media" }) {
                ADFMediaView(media: item, maxWidth: Self.width(of: item, in: node))
            }
            if let caption = node.children.first(where: { $0.type == "caption" }), !caption.children.isEmpty {
                Text(ADFInline.attributedString(caption.children, media: media, textScale: textScale, font: appFont))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var alignment: Alignment {
        switch node.attr("layout") {
        case "align-start", "wrap-left": return .leading
        case "align-end", "wrap-right": return .trailing
        default: return .center
        }
    }

    /// The width chosen in Jira's editor for `item` in its block `node`:
    /// pixels, or in older content a percentage of the 760 pt text column.
    /// Wide layouts use the image's own width.
    static func width(of item: ADFNode, in node: ADFNode) -> CGFloat? {
        let natural = item.intAttr("width").map(CGFloat.init)
        if ["wide", "full-width"].contains(node.attr("layout")) { return natural }
        guard let width = node.intAttr("width").map(CGFloat.init) else { return natural }
        return node.attr("widthType") == "pixel" ? width : 760 * width / 100
    }

    /// The attached file a block shows on its own line, when it has no
    /// caption: its `media` node.
    static func uncaptionedFile(in node: ADFNode) -> ADFNode? {
        guard node.type == "mediaSingle",
              !node.children.contains(where: { $0.type == "caption" && !$0.children.isEmpty }),
              let media = node.children.first(where: { $0.type == "media" }),
              media.attr("type") == "file"
        else { return nil }
        return media
    }
}

/// One `media` node: an attachment image, or a chip for any other file.
/// Both open in Quick Look. Without a media context it's a plain label.
private struct ADFMediaView: View {
    let media: ADFNode
    var maxWidth: CGFloat?
    /// Fixed-size tile, for files shown side by side.
    var isThumbnail = false

    @Environment(\.adfMedia) private var context
    @Environment(\.adfConfluenceFiles) private var confluenceFiles

    var body: some View {
        if let context, let attachment = context.attachment(for: media) {
            if attachment.isImage {
                AttachmentImage(attachment: attachment, context: context, aspectRatio: aspectRatio,
                                maxWidth: maxWidth, isThumbnail: isThumbnail)
            } else {
                AttachmentChip(attachment: attachment, context: context)
            }
        } else if let confluenceFiles, media.attr("type") == "file" {
            ConfluenceFileView(media: media, files: confluenceFiles, aspectRatio: aspectRatio, maxWidth: maxWidth)
        } else {
            Label(media.attr("alt") ?? "Attachment", systemImage: "paperclip")
                .foregroundStyle(.secondary)
                .scaledFont(.callout)
        }
    }

    /// Width ÷ height from the node, so space is reserved before the image arrives.
    private var aspectRatio: CGFloat? {
        guard let width = media.intAttr("width"), let height = media.intAttr("height"),
              width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }
}

/// An image attachment, downloaded with the account's credentials.
private struct AttachmentImage: View {
    let attachment: JiraIssue.Attachment
    let context: ADFMediaContext
    let aspectRatio: CGFloat?
    let maxWidth: CGFloat?
    let isThumbnail: Bool

    @State private var image: PlatformImage?
    @State private var failed = false

    private let shape = RoundedRectangle(cornerRadius: 6)

    var body: some View {
        Group {
            if let image {
                Button {
                    Task { await context.preview(attachment) }
                } label: {
                    picture(image)
                }
                .buttonStyle(.plain)
                .linkPointer()
                .help("\(attachment.filename) — click to preview")
                .accessibilityLabel(attachment.filename)
                .contextMenu {
                    Button("Quick Look") { Task { await context.preview(attachment) } }
                    Button("Copy Image") {
                        Clipboard.copy(image)
                    }
                }
            } else if failed {
                AttachmentChip(attachment: attachment, context: context)
            } else {
                placeholder
            }
        }
        .task(id: attachment.id) {
            do {
                image = try await AttachmentStore.shared.image(for: attachment, using: context.client)
            } catch {
                failed = true
            }
        }
    }

    @ViewBuilder
    private func picture(_ image: PlatformImage) -> some View {
        if isThumbnail {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 160, height: 120)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.quaternary))
        } else {
            Image(platformImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.quaternary))
                .frame(maxWidth: maxWidth ?? image.size.width)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        let tile = shape.fill(.quaternary.opacity(0.5)).overlay { ProgressView().controlSize(.small) }
        if isThumbnail {
            tile.frame(width: 160, height: 120)
        } else {
            tile.aspectRatio(aspectRatio ?? 4 / 3, contentMode: .fit)
                .frame(maxWidth: maxWidth ?? 320)
        }
    }
}

/// Any other attachment: icon, file name and size.
private struct AttachmentChip: View {
    let attachment: JiraIssue.Attachment
    let context: ADFMediaContext

    @State private var isOpening = false

    var body: some View {
        Button {
            Task {
                isOpening = true
                await context.preview(attachment)
                isOpening = false
            }
        } label: {
            HStack(spacing: 6) {
                if isOpening {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: attachment.symbolName).foregroundStyle(.secondary)
                }
                Text(attachment.filename).lineLimit(1)
                if let size = attachment.size {
                    Text(Int64(size), format: .byteCount(style: .file))
                        .foregroundStyle(.secondary)
                }
            }
            .scaledFont(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(isOpening)
        .help("Preview \(attachment.filename)")
    }
}

/// A file attached in Confluence, such as an image in a priority's comment:
/// a small copy of an image, or a chip for any other file, downloaded with
/// the account's credentials. Either opens full size in Quick Look.
private struct ConfluenceFileView: View {
    let media: ADFNode
    let files: ADFConfluenceFiles
    /// Width ÷ height from the node, so space is reserved before the image arrives.
    let aspectRatio: CGFloat?
    /// The width the image is given where it's shown, which it's never drawn wider than.
    let maxWidth: CGFloat?

    @State private var attachment: ConfluenceAttachment?
    @State private var image: PlatformImage?
    @State private var failure: String?
    @State private var isOpening = false

    /// The box an image fits in: a glance, not the column's whole width,
    /// so a few phone screenshots sit side by side.
    #if os(iOS)
    private static let tallest: CGFloat = 140
    private static let widest: CGFloat = 240
    #else
    private static let tallest: CGFloat = 180
    private static let widest: CGFloat = 360
    #endif
    /// Pixels on the long side of the copy decoded for one: enough for a
    /// Retina screen at the largest it shows.
    private static let previewPixels = 720

    private let shape = RoundedRectangle(cornerRadius: 6)

    private var name: String {
        attachment?.title ?? media.attr("alt") ?? media.attr("__fileName") ?? "Attachment"
    }

    /// Whether it's drawn as an image: anything but a file known not to be one.
    private var isImage: Bool {
        guard let type = attachment?.mediaType ?? media.attr("__fileMimeType") else { return true }
        return type.hasPrefix("image/")
    }

    var body: some View {
        Group {
            if let image {
                picture(image)
            } else if isImage && failure == nil {
                placeholder
            } else {
                chip
            }
        }
        .task(id: "\(files.id)/\(media.attr("id") ?? "")") { await load() }
    }

    private func picture(_ image: PlatformImage) -> some View {
        let size = size(for: image.size.height > 0 ? image.size.width / image.size.height : aspectRatio ?? 4 / 3)
        return Button(action: open) {
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipShape(shape)
                .overlay {
                    if isOpening {
                        shape.fill(.black.opacity(0.25))
                        ProgressView().controlSize(.small)
                    }
                }
                .overlay(shape.strokeBorder(.quaternary))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .linkPointer()
        .help(failure ?? "\(name) — click to open")
        .accessibilityLabel(name)
        .contextMenu {
            Button("Open", systemImage: "eye", action: open)
            Button("Copy Image", systemImage: "doc.on.doc", action: copy)
        }
    }

    private var placeholder: some View {
        let size = size(for: aspectRatio ?? 4 / 3)
        return shape.fill(.quaternary.opacity(0.5))
            .overlay { ProgressView().controlSize(.small) }
            .frame(width: size.width, height: size.height)
            .help(name)
    }

    /// A file that isn't an image, or one that couldn't be shown.
    private var chip: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                if isOpening {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbolName).foregroundStyle(.secondary)
                }
                Text(name).lineLimit(1)
                if let size = attachment?.fileSize {
                    Text(Int64(size), format: .byteCount(style: .file))
                        .foregroundStyle(.secondary)
                }
            }
            .scaledFont(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: shape)
        }
        .buttonStyle(.plain)
        .disabled(isOpening || attachment == nil)
        .help(failure ?? "Open \(name)")
    }

    private var symbolName: String {
        if attachment == nil { return "exclamationmark.triangle" }
        let type = attachment?.mediaType ?? ""
        if failure != nil, type.hasPrefix("image/") { return "photo.badge.exclamationmark" }
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type == "application/pdf" { return "doc.richtext" }
        return "doc"
    }

    /// Its size for width ÷ height `ratio`: within the box, and no wider
    /// than it's given.
    private func size(for ratio: CGFloat) -> CGSize {
        let widest = min(Self.widest, maxWidth ?? .infinity)
        let height = min(Self.tallest, widest / max(ratio, 0.01))
        return CGSize(width: (height * ratio).rounded(), height: height.rounded())
    }

    private func load() async {
        do {
            let found = try await files.attachment(media)
            attachment = found
            if found.mediaType?.hasPrefix("image/") ?? true {
                image = try await PriorityPhotoStore.shared.preview(for: found, using: files.client, maxPixels: Self.previewPixels)
            }
            failure = nil
        } catch where error.isCancellation {
            return
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Downloads it full size, if it isn't already, and opens it in Quick Look.
    private func open() {
        guard let attachment, !isOpening else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            do {
                files.preview(try await PriorityPhotoStore.shared.file(for: attachment, using: files.client))
            } catch where error.isCancellation {
                return
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    /// Copies the full-size image.
    private func copy() {
        guard let attachment else { return }
        Task {
            guard let file = try? await PriorityPhotoStore.shared.file(for: attachment, using: files.client),
                  let full = PlatformImage.decoded(contentsOf: file) else { return }
            Clipboard.copy(full)
        }
    }
}

extension JiraIssue.Attachment {
    /// SF Symbol for the kind of file.
    var symbolName: String {
        let type = mimeType ?? ""
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.contains("spreadsheet") || type == "text/csv" || filename.lowercased().hasSuffix(".csv") { return "tablecells" }
        if type.contains("zip") { return "doc.zipper" }
        return "doc"
    }
}

/// Inline (text-level) ADF → AttributedString.
enum ADFInline {
    static let inlineTypes: Set<String> = ["text", "hardBreak", "mention", "emoji", "inlineCard", "status", "date", "mediaInline"]

    static func isInline(_ node: ADFNode) -> Bool { inlineTypes.contains(node.type) }

    /// `media` resolves attached files named in the text; without it they're plain text.
    /// `textScale` and `font` size status lozenges, which carry their own font.
    static func attributedString(_ nodes: [ADFNode], media: ADFMediaContext? = nil, textScale: CGFloat = 1, font: AppFont = .system) -> AttributedString {
        var result = AttributedString()
        for node in nodes {
            switch node.type {
            case "text":
                result += styled(node.text ?? "", marks: node.marks ?? [])
            case "hardBreak":
                result += AttributedString("\n")
            case "mention":
                var mention = AttributedString(node.attr("text") ?? "@unknown")
                mention.foregroundColor = .accentColor
                mention.inlinePresentationIntent = .stronglyEmphasized
                result += mention
            case "emoji":
                result += AttributedString(node.attr("text") ?? node.attr("shortName") ?? "")
            case "inlineCard":
                // Issue cards read as their key, the way Jira draws them; other cards show their address.
                let urlString = node.attr("url") ?? ""
                var card = AttributedString(node.plainText.isEmpty ? urlString : node.plainText)
                card.link = URL(string: urlString)
                result += card
            case "status":
                var status = AttributedString(" \(node.attr("text")?.uppercased() ?? "STATUS") ")
                status.backgroundColor = .secondary.opacity(0.2)
                status.font = ScaledFont.caption.weight(.semibold).font(scale: textScale, family: font)
                result += status
            case "date":
                if let millis = node.attr("timestamp").flatMap(Double.init) {
                    let date = Date(timeIntervalSince1970: millis / 1000)
                    result += AttributedString(date.formatted(date: .abbreviated, time: .omitted))
                }
            case "mediaInline":
                // Jira draws these as chips with their own margin; keep them off the preceding word.
                if let last = result.characters.last, !last.isWhitespace {
                    result += AttributedString(" ")
                }
                if let media, let attachment = media.attachment(for: node) {
                    var name = AttributedString(attachment.filename)
                    name.link = media.client.browseURL(for: attachment)
                    result += name
                } else {
                    result += AttributedString(node.attr("alt") ?? "Attachment")
                }
            default:
                result += attributedString(node.children, media: media, textScale: textScale, font: font)
            }
        }
        return result
    }

    private static func styled(_ text: String, marks: [ADFMark]) -> AttributedString {
        var string = AttributedString(text)
        var intent: InlinePresentationIntent = []
        for mark in marks {
            switch mark.type {
            case "strong": intent.insert(.stronglyEmphasized)
            case "em": intent.insert(.emphasized)
            case "code":
                intent.insert(.code)
                string.backgroundColor = .secondary.opacity(0.15)
            case "strike": intent.insert(.strikethrough)
            case "underline": string.underlineStyle = .single
            case "link":
                if let href = mark.attr("href"), let url = URL(string: href) {
                    string.link = url
                }
            case "textColor":
                if let color = Color(hex: mark.attr("color")) { string.foregroundColor = color }
            default: break
            }
        }
        if !intent.isEmpty { string.inlinePresentationIntent = intent }
        return string
    }
}

private extension Color {
    init?(hex: String?) {
        guard var hex else { return nil }
        hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
