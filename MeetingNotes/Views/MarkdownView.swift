import SwiftUI

/// Minimal Markdown renderer for the summary and action items (headings, bullets, to-dos, bold).
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    private enum Block {
        case heading(Int, String)
        case bullet(Int, String)
        case todo(Bool, String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        markdown.components(separatedBy: .newlines).compactMap { raw in
            let indent = raw.prefix { $0 == " " }.count / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("### ") { return .heading(3, String(line.dropFirst(4))) }
            if line.hasPrefix("## ") { return .heading(2, String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return .heading(1, String(line.dropFirst(2))) }
            if line.hasPrefix("- [ ] ") { return .todo(false, String(line.dropFirst(6))) }
            if line.lowercased().hasPrefix("- [x] ") { return .todo(true, String(line.dropFirst(6))) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return .bullet(indent, String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level == 1 ? 0 : 8)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(text))
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .todo(let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square" : "square").foregroundStyle(.secondary)
                Text(inline(text))
            }
        case .paragraph(let text):
            Text(inline(text))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        // Model output is untrusted: keep link text but make it not clickable.
        for run in result.runs where run.link != nil {
            result[run.range].link = nil
        }
        return result
    }
}
