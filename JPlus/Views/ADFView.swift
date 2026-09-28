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

extension EnvironmentValues {
    @Entry var adfMedia: ADFMediaContext? = nil
}

private struct ADFBlocks: View {
    let nodes: [ADFNode]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                ADFBlock(node: node)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ADFBlock: View {
    let node: ADFNode

    @Environment(\.adfMedia) private var media

    var body: some View {
        switch node.type {
        case "paragraph":
            if node.children.isEmpty {
                Color.clear.frame(height: 4)
            } else {
                Text(ADFInline.attributedString(node.children, media: media))
                    .textSelection(.enabled)
            }

        case "heading":
            Text(ADFInline.attributedString(node.children, media: media))
                .font(headingFont(level: node.intAttr("level") ?? 3))
                .padding(.top, 4)
                .textSelection(.enabled)

        case "bulletList":
            listView(items: node.children) { _ in Text("•") }

        case "orderedList":
            let start = node.intAttr("order") ?? 1
            listView(items: node.children) { index in Text("\(start + index).") }

        case "codeBlock":
            ScrollView(.horizontal) {
                Text(node.children.map(\.plainText).joined())
                    .font(.body.monospaced())
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
                        Text(ADFInline.attributedString(item.children, media: media)).textSelection(.enabled)
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
                Text(ADFInline.attributedString(node.children, media: media)).textSelection(.enabled)
            } else {
                ADFBlocks(nodes: node.children)
            }
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title.weight(.bold)
        case 2: return .title2.weight(.semibold)
        case 3: return .title3.weight(.semibold)
        default: return .headline
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
                                .font(cell.type == "tableHeader" ? .body.weight(.semibold) : .body)
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

    var body: some View {
        VStack(alignment: alignment.horizontal, spacing: 4) {
            if let item = node.children.first(where: { $0.type == "media" }) {
                ADFMediaView(media: item, maxWidth: width(of: item))
            }
            if let caption = node.children.first(where: { $0.type == "caption" }), !caption.children.isEmpty {
                Text(ADFInline.attributedString(caption.children, media: media))
                    .font(.caption)
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

    /// The width chosen in Jira's editor: pixels, or in older content a
    /// percentage of the 760 pt text column. Wide layouts use the image's own width.
    private func width(of item: ADFNode) -> CGFloat? {
        let natural = item.intAttr("width").map(CGFloat.init)
        if ["wide", "full-width"].contains(node.attr("layout")) { return natural }
        guard let width = node.intAttr("width").map(CGFloat.init) else { return natural }
        return node.attr("widthType") == "pixel" ? width : 760 * width / 100
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

    var body: some View {
        if let context, let attachment = context.attachment(for: media) {
            if attachment.isImage {
                AttachmentImage(attachment: attachment, context: context, aspectRatio: aspectRatio,
                                maxWidth: maxWidth, isThumbnail: isThumbnail)
            } else {
                AttachmentChip(attachment: attachment, context: context)
            }
        } else {
            Label(media.attr("alt") ?? "Attachment", systemImage: "paperclip")
                .foregroundStyle(.secondary)
                .font(.callout)
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

    @State private var image: NSImage?
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
                .pointerStyle(.link)
                .help("\(attachment.filename) — click to preview")
                .accessibilityLabel(attachment.filename)
                .contextMenu {
                    Button("Quick Look") { Task { await context.preview(attachment) } }
                    Button("Copy Image") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
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
    private func picture(_ image: NSImage) -> some View {
        if isThumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 160, height: 120)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.quaternary))
        } else {
            Image(nsImage: image)
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
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
                Text(attachment.filename).lineLimit(1)
                if let size = attachment.size {
                    Text(Int64(size), format: .byteCount(style: .file))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(isOpening)
        .help("Preview \(attachment.filename)")
    }

    private var symbol: String {
        let type = attachment.mimeType ?? ""
        let name = attachment.filename.lowercased()
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.contains("spreadsheet") || type == "text/csv" || name.hasSuffix(".csv") { return "tablecells" }
        if type.contains("zip") { return "doc.zipper" }
        return "doc"
    }
}

/// Inline (text-level) ADF → AttributedString.
enum ADFInline {
    static let inlineTypes: Set<String> = ["text", "hardBreak", "mention", "emoji", "inlineCard", "status", "date", "mediaInline"]

    static func isInline(_ node: ADFNode) -> Bool { inlineTypes.contains(node.type) }

    /// `media` resolves attached files named in the text; without it they're plain text.
    static func attributedString(_ nodes: [ADFNode], media: ADFMediaContext? = nil) -> AttributedString {
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
                let urlString = node.attr("url") ?? ""
                var card = AttributedString(urlString)
                card.link = URL(string: urlString)
                result += card
            case "status":
                var status = AttributedString(" \(node.attr("text")?.uppercased() ?? "STATUS") ")
                status.backgroundColor = .secondary.opacity(0.2)
                status.font = .caption.weight(.semibold)
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
                result += attributedString(node.children, media: media)
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
