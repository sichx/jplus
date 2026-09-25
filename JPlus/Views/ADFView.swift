import SwiftUI

/// Renders an Atlassian Document Format tree with native SwiftUI views.
/// Covers the node types that show up in ordinary issue descriptions and
/// comments; anything unknown falls back to rendering its children.
struct ADFView: View {
    let node: ADFNode

    var body: some View {
        ADFBlocks(nodes: node.type == "doc" ? node.children : [node])
    }
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

    var body: some View {
        switch node.type {
        case "paragraph":
            if node.children.isEmpty {
                Color.clear.frame(height: 4)
            } else {
                Text(ADFInline.attributedString(node.children))
                    .textSelection(.enabled)
            }

        case "heading":
            Text(ADFInline.attributedString(node.children))
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

        case "mediaSingle", "mediaGroup", "mediaInline", "media":
            Label(node.attr("alt") ?? "Attachment", systemImage: "paperclip")
                .foregroundStyle(.secondary)
                .font(.callout)

        case "taskList":
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.attr("state") == "DONE" ? "checkmark.square.fill" : "square")
                            .foregroundStyle(item.attr("state") == "DONE" ? Color.accentColor : .secondary)
                        Text(ADFInline.attributedString(item.children)).textSelection(.enabled)
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
                Text(ADFInline.attributedString(node.children)).textSelection(.enabled)
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

/// Inline (text-level) ADF → AttributedString.
enum ADFInline {
    static let inlineTypes: Set<String> = ["text", "hardBreak", "mention", "emoji", "inlineCard", "status", "date"]

    static func isInline(_ node: ADFNode) -> Bool { inlineTypes.contains(node.type) }

    static func attributedString(_ nodes: [ADFNode]) -> AttributedString {
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
            default:
                result += attributedString(node.children)
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
