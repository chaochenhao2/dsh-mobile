import SwiftUI
import UIKit

/// One block of parsed Markdown.
///
/// The transcript is rendered block by block rather than through one
/// `AttributedString`, because a coding agent's answer is mostly fenced code,
/// lists, and headings — block-level layout is what makes those readable on a
/// phone. `id` is assigned at parse time so `ForEach` stays stable.
struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(indent: Int, text: String)
        case numbered(indent: Int, marker: String, text: String)
        case code(language: String, code: String)
        case quote(text: String)
        case rule
    }

    let id: Int
    let kind: Kind
}

/// A single-pass Markdown reader for the subset a model answer actually uses.
///
/// Supported: ATX headings, paragraphs, fenced code (``` and ~~~), bullets,
/// ordered lists, block quotes, and horizontal rules. Tables, footnotes, and
/// reference links are intentionally left as plain text — rendering them badly
/// is worse than showing the source.
enum MarkdownParser {
    /// Parse one Markdown document into renderable blocks.
    /// @param source - the raw message text.
    /// @returns blocks in document order; never empty for non-empty input.
    static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(MarkdownBlock(id: blocks.count, kind: .paragraph(paragraph.joined(separator: "\n"))))
            paragraph.removeAll()
        }

        func append(_ kind: MarkdownBlock.Kind) {
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind))
        }

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code: everything up to the closing fence is verbatim.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) { break }
                    body.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                append(.code(language: language, code: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = headingLevel(trimmed) {
                flushParagraph()
                append(.heading(level: heading, text: String(trimmed.dropFirst(heading)).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoted.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                append(.quote(text: quoted.joined(separator: "\n")))
                continue
            }

            if let item = bullet(raw) {
                flushParagraph()
                append(item)
                index += 1
                continue
            }

            if let item = numbered(raw) {
                flushParagraph()
                append(item)
                index += 1
                continue
            }

            paragraph.append(raw)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    /// Count the leading `#` run of an ATX heading.
    /// @param line - a whitespace-trimmed line.
    /// @returns the level 1...6, or nil when the line is not a heading.
    private static func headingLevel(_ line: String) -> Int? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes <= 6, line.count > hashes else { return nil }
        let separatorIndex = line.index(line.startIndex, offsetBy: hashes)
        guard line[separatorIndex] == " " else { return nil }
        return hashes
    }

    /// Read one bullet item, including its indentation depth.
    /// @param raw - the original line, before trimming.
    /// @returns the block kind, or nil when the line is not a bullet.
    private static func bullet(_ raw: String) -> MarkdownBlock.Kind? {
        let indent = indentation(raw)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let text = String(trimmed.dropFirst(marker.count))
            guard !text.isEmpty else { return nil }
            return .bullet(indent: indent, text: text)
        }
        return nil
    }

    /// Read one ordered-list item, including its indentation depth.
    /// @param raw - the original line, before trimming.
    /// @returns the block kind, or nil when the line is not a list item.
    private static func numbered(_ raw: String) -> MarkdownBlock.Kind? {
        let indent = indentation(raw)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let dot = trimmed.firstIndex(of: ".") else { return nil }
        let marker = String(trimmed[trimmed.startIndex..<dot])
        guard !marker.isEmpty, marker.count <= 4, marker.allSatisfy({ $0.isNumber }) else { return nil }
        let rest = trimmed[trimmed.index(after: dot)...]
        guard rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return .numbered(indent: indent, marker: marker, text: text)
    }

    /// Convert leading whitespace into a bounded nesting depth.
    /// @param raw - the original line.
    /// @returns 0...3, rounded down from two spaces per level.
    private static func indentation(_ raw: String) -> Int {
        let spaces = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
        return min(spaces / 2, 3)
    }
}

/// Renders parsed Markdown blocks with the app's typography.
struct MarkdownView: View {
    private let blocks: [MarkdownBlock]

    init(text: String) {
        blocks = MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                view(for: block.kind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for kind: MarkdownBlock.Kind) -> some View {
        switch kind {
        case let .heading(level, text):
            Text(inline(text, size: headingSize(level), weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, level <= 2 ? 4 : 2)
        case let .paragraph(text):
            Text(inline(text, size: 15))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .bullet(indent, text):
            listRow(marker: "•", indent: indent, text: text)
        case let .numbered(indent, marker, text):
            listRow(marker: "\(marker).", indent: indent, text: text)
        case let .code(language, code):
            codeBlock(language: language, code: code)
        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Theme.accent.opacity(0.6))
                    .frame(width: 3)
                Text(inline(text, size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .rule:
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func listRow(marker: String, indent: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accentAlt)
                .frame(minWidth: 16, alignment: .trailing)
            Text(inline(text, size: 15))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    private func codeBlock(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 21
        case 2: return 18
        case 3: return 16.5
        default: return 15.5
        }
    }

    /// Parse inline Markdown into a styled string.
    ///
    /// The whole run gets the base font first, then inline-code runs override
    /// it, so a code span keeps its monospace face. Colors are left unset so the
    /// surrounding `Text` style applies, which keeps links tinted by the app.
    /// @param source - one line or block of inline Markdown.
    /// @param size - base point size.
    /// @param weight - base weight.
    /// @returns the attributed string, falling back to plain text.
    private func inline(_ source: String, size: CGFloat, weight: Font.Weight = .regular) -> AttributedString {
        var attributed: AttributedString
        if let parsed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            attributed = parsed
        } else {
            attributed = AttributedString(source)
        }
        attributed.font = .system(size: size, weight: weight)
        let codeRanges = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            attributed[range].font = .system(size: max(11, size - 1.5), design: .monospaced)
            attributed[range].backgroundColor = Theme.inlineCode
        }
        return attributed
    }
}