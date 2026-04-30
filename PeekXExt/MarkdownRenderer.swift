// PeekX - Markdown Rendering Engine
// Copyright © 2025 ALTIC. All rights reserved.

import Cocoa

// MARK: - Markdown Renderer

enum MarkdownRenderer {

    // MARK: - Public API

    static func makeHTML(fromMarkdown markdown: String) -> String {
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "<p>No content.</p>"
        }
        return renderMarkdownHTML(markdown)
    }

    static func makeOriginalMarkdownHTML(fromMarkdown markdown: String) -> String {
        let htmlBody = makeHTML(fromMarkdown: markdown)
        return originalMarkdownHTML(body: """
            <div id="content">\(htmlBody)</div>
        """)
    }

    static func originalMarkdownHTML(body htmlBody: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            :root { color-scheme: light; }
            html {
                margin: 0;
                min-height: 100%;
                background: #ffffff;
            }
            body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                margin: 0;
                min-height: 100%;
                padding: 18px 36px 40px 36px;
                font-size: 15px;
                line-height: 1.6;
                color: #1d1d1f;
                background: #ffffff;
            }
            #content { margin: 0; max-width: none; }
            body > :first-child,
            #content > :first-child { margin-top: 0; }
            h1, h2, h3, h4, h5, h6 {
                margin-top: 24px;
                margin-bottom: 16px;
                font-weight: 600;
                line-height: 1.25;
            }
            h1 { font-size: 2em; border-bottom: 1px solid #e1e4e8; padding-bottom: 8px; }
            h2 { font-size: 1.5em; border-bottom: 1px solid #e1e4e8; padding-bottom: 6px; }
            h3 { font-size: 1.25em; }
            p { margin: 0 0 16px 0; }
            a { color: #0969da; text-decoration: none; }
            a:hover { text-decoration: underline; }
            pre, code {
                font-family: "SF Mono", Menlo, Monaco, Consolas, monospace;
            }
            code {
                font-size: 13px;
                background: rgba(175,184,193,0.2);
                padding: 2px 6px;
                border-radius: 4px;
            }
            pre {
                background: #f6f8fa;
                padding: 16px;
                border-radius: 8px;
                overflow-x: auto;
                border: 1px solid #e1e4e8;
                margin: 16px 0;
                white-space: pre-wrap;
                word-break: break-word;
            }
            pre code { background: none; padding: 0; white-space: pre-wrap; word-break: break-word; }
            .md-list-item { margin: 4px 0; }
            .md-list-marker {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: 15px;
                font-weight: 400;
                font-style: normal;
                background: transparent;
            }
            blockquote {
                margin: 0 0 16px 0;
                padding: 0 16px;
                border-left: 4px solid #d0d7de;
                color: #57606a;
            }
            .details-summary {
                margin: 20px 0 12px 0;
                font-weight: 600;
                color: #1d1d1f;
            }
            table { border-collapse: collapse; width: 100%; margin: 16px 0; }
            th, td { border: 1px solid #d0d7de; padding: 8px 12px; text-align: left; }
            th { background: #f6f8fa; font-weight: 600; }
            img { max-width: 100%; height: auto; border-radius: 8px; margin: 16px 0; }
        </style>
        </head>
        <body>
        \(htmlBody)
        </body>
        </html>
        """
    }

    static func markdownLoadingHTML() -> String {
        originalMarkdownHTML(body: "<p>Loading...</p>")
    }

    // MARK: - Text Preview Setup

    static func setTextPreview(_ text: String, in textView: NSTextView, markdown: Bool, fontSize: CGFloat) {
        let foregroundColor: NSColor = markdown ? .black : .labelColor
        let backgroundColor: NSColor = markdown ? .white : .clear

        textView.font = markdown
            ? NSFont.systemFont(ofSize: fontSize)
            : NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = foregroundColor
        textView.drawsBackground = markdown
        textView.backgroundColor = backgroundColor
        textView.enclosingScrollView?.drawsBackground = markdown
        textView.enclosingScrollView?.backgroundColor = backgroundColor
        textView.enclosingScrollView?.contentView.drawsBackground = markdown
        textView.enclosingScrollView?.contentView.backgroundColor = backgroundColor

        if markdown,
           let attributed = try? AttributedString(markdown: text) {
            let rendered = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
            rendered.addAttribute(.foregroundColor, value: foregroundColor, range: NSRange(location: 0, length: rendered.length))
            textView.textStorage?.setAttributedString(rendered)
        } else {
            textView.string = text
        }
        textView.scrollToBeginningOfDocument(nil)
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                if let sv = textView.enclosingScrollView {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: sv.contentView.bounds.origin.y))
                }
            }
        }
    }

    static func setRenderedHTMLPreview(_ html: String, in textView: NSTextView) {
        let backgroundColor = NSColor.white
        textView.drawsBackground = true
        textView.backgroundColor = backgroundColor
        textView.textColor = .black
        textView.enclosingScrollView?.drawsBackground = true
        textView.enclosingScrollView?.backgroundColor = backgroundColor
        textView.enclosingScrollView?.contentView.drawsBackground = true
        textView.enclosingScrollView?.contentView.backgroundColor = backgroundColor

        let scrollView = textView.enclosingScrollView
        let viewportWidth = max(scrollView?.contentView.bounds.width ?? 640, 100)

        // Freeze container to viewport width before HTML import.
        // Otherwise the importer uses a default ~980 px paper width and lays
        // out glyphs too wide, pushing horizontal scroll off the left edge.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: viewportWidth, height: CGFloat.greatestFiniteMagnitude)

        if let data = html.data(using: .utf8),
           let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
           ) {
            let rendered = NSMutableAttributedString(attributedString: attributed)
            flattenImportedHTMLListMarkers(in: rendered)
            textView.textStorage?.setAttributedString(rendered)
        } else {
            textView.string = html
        }

        // setAttributedString triggers deferred layout. Double async waits
        // for two run-loop ticks so layout finishes before we reset scroll.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                textView.scrollToBeginningOfDocument(nil)
                if let sv = textView.enclosingScrollView {
                    sv.contentView.scroll(to: NSPoint(x: 0, y: sv.contentView.bounds.origin.y))
                }
                textView.textContainer?.widthTracksTextView = true
            }
        }
    }

    static func flattenImportedHTMLListMarkers(in attributed: NSMutableAttributedString) {
        let originalString = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: originalString.length)
        var paragraphRanges: [NSRange] = []

        originalString.enumerateSubstrings(in: fullRange, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosingRange, _ in
            paragraphRanges.append(enclosingRange)
        }

        for paragraphRange in paragraphRanges.reversed() {
            guard paragraphRange.location < attributed.length else { continue }
            guard let paragraphStyle = attributed.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle,
                  !paragraphStyle.textLists.isEmpty else { continue }

            let currentString = attributed.string as NSString
            let availableLength = min(paragraphRange.length, currentString.length - paragraphRange.location)
            guard availableLength >= 3 else { continue }

            let paragraphText = currentString.substring(with: NSRange(location: paragraphRange.location, length: availableLength)) as NSString
            guard paragraphText.character(at: 0) == 9 else { continue }

            var secondTabIndex: Int?
            for index in 1..<paragraphText.length {
                let character = paragraphText.character(at: index)
                if character == 9 {
                    secondTabIndex = index
                    break
                }
                if character == 10 || character == 13 {
                    break
                }
            }

            if let secondTabIndex {
                let marker = paragraphText.substring(with: NSRange(location: 1, length: secondTabIndex - 1))
                let replacement = marker == "•" ? "•  " : "\(marker).  "
                attributed.replaceCharacters(
                    in: NSRange(location: paragraphRange.location, length: secondTabIndex + 1),
                    with: replacement
                )

                let flattenedStyle = NSMutableParagraphStyle()
                flattenedStyle.setParagraphStyle(paragraphStyle)
                flattenedStyle.textLists = []
                flattenedStyle.firstLineHeadIndent = 0
                flattenedStyle.headIndent = 0
                flattenedStyle.tabStops = []
                let newLength = max(0, availableLength - (secondTabIndex + 1) + (replacement as NSString).length)
                let styleRange = NSRange(
                    location: paragraphRange.location,
                    length: min(newLength, attributed.length - paragraphRange.location)
                )
                attributed.addAttribute(.paragraphStyle, value: flattenedStyle, range: styleRange)
            }
        }
    }

    // MARK: - HTML Escaping

    static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Core Markdown to HTML

    static func renderMarkdownHTML(_ markdown: String) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var output: [String] = []
        var paragraph: [String] = []
        var inCodeBlock = false
        var codeLines: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            output.append("<p>\(renderMarkdownInline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }

        func closeList() {}

        func flushCodeBlock() {
            output.append("<pre><code>\(escapedHTML(codeLines.joined(separator: "\n")))</code></pre><br>")
            codeLines.removeAll()
        }

        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if isMarkdownFence(trimmed) {
                if inCodeBlock {
                    flushCodeBlock()
                    inCodeBlock = false
                } else {
                    flushParagraph()
                    closeList()
                    inCodeBlock = true
                }
                index += 1
                continue
            }

            if inCodeBlock {
                codeLines.append(rawLine)
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                closeList()
                index += 1
                continue
            }

            if index + 1 < lines.count,
               rawLine.contains("|"),
               isMarkdownTableSeparator(lines[index + 1]) {
                flushParagraph()
                closeList()
                let table = renderMarkdownTable(lines: lines, startIndex: index)
                output.append(table.html)
                index = table.nextIndex
                continue
            }

            if let level = markdownHeadingLevel(trimmed) {
                flushParagraph()
                closeList()
                let start = trimmed.index(trimmed.startIndex, offsetBy: level + 1)
                output.append("<h\(level)>\(renderMarkdownInline(String(trimmed[start...])))</h\(level)>")
                index += 1
                continue
            }

            if isMarkdownHorizontalRule(trimmed) {
                flushParagraph()
                closeList()
                output.append("<hr>")
                index += 1
                continue
            }

            if isMarkdownDetailsBoundary(trimmed) {
                flushParagraph()
                closeList()
                index += 1
                continue
            }

            if let summary = markdownSummaryContent(trimmed) {
                flushParagraph()
                closeList()
                output.append("<p class=\"details-summary\">&#9656; \(renderMarkdownInlineHTMLFragment(summary))</p>")
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                closeList()
                var quotedLines: [String] = []
                while index < lines.count {
                    let quotedLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quotedLine.hasPrefix(">") else { break }
                    quotedLines.append(markdownBlockquoteContent(quotedLine))
                    index += 1
                }
                output.append("<blockquote>\(renderMarkdownHTML(quotedLines.joined(separator: "\n")))</blockquote>")
                continue
            }

            if let content = unorderedMarkdownListItem(trimmed) {
                flushParagraph()
                closeList()
                output.append("<p class=\"md-list-item\"><span class=\"md-list-marker\">•</span> \(renderMarkdownInline(content))</p>")
                index += 1
                continue
            }

            if let item = orderedMarkdownListItem(trimmed) {
                flushParagraph()
                closeList()
                output.append("<p class=\"md-list-item\"><span class=\"md-list-marker\">\(escapedHTML(item.number)).</span> \(renderMarkdownInline(item.content))</p>")
                index += 1
                continue
            }

            closeList()
            paragraph.append(trimmed)
            index += 1
        }

        if inCodeBlock {
            flushCodeBlock()
        }
        flushParagraph()
        closeList()
        return output.joined(separator: "\n")
    }

    // MARK: - Block Element Parsers

    static func markdownHeadingLevel(_ line: String) -> Int? {
        var level = 0
        for character in line {
            if character == "#" {
                level += 1
            } else {
                break
            }
        }
        guard (1...6).contains(level) else { return nil }
        let markerEnd = line.index(line.startIndex, offsetBy: level)
        guard markerEnd < line.endIndex, line[markerEnd] == " " else { return nil }
        return level
    }

    static func isMarkdownFence(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    static func isMarkdownDetailsBoundary(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return matchesMarkdownPattern(#"(?i)^<details\b[^>]*>$"#, in: normalized)
            || matchesMarkdownPattern(#"(?i)^</details>$"#, in: normalized)
    }

    static func markdownSummaryContent(_ line: String) -> String? {
        let pattern = #"(?i)^<summary\b[^>]*>\s*(.*?)\s*</summary>$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges == 2 else { return nil }
        return nsLine.substring(with: match.range(at: 1))
    }

    static func matchesMarkdownPattern(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, range: range) != nil
    }

    static func markdownBlockquoteContent(_ line: String) -> String {
        guard line.hasPrefix(">") else { return line }
        let afterMarker = line.dropFirst()
        return String(afterMarker).trimmingCharacters(in: .whitespaces)
    }

    static func isMarkdownHorizontalRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3,
              let first = compact.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func unorderedMarkdownListItem(_ line: String) -> String? {
        guard line.count > 2,
              let first = line.first,
              first == "-" || first == "*" || first == "+" else { return nil }
        let second = line[line.index(after: line.startIndex)]
        guard second == " " else { return nil }
        return String(line.dropFirst(2))
    }

    static func orderedMarkdownListItem(_ line: String) -> (number: String, content: String)? {
        let characters = Array(line)
        var digitCount = 0
        while digitCount < characters.count, characters[digitCount].isNumber {
            digitCount += 1
        }
        guard digitCount > 0,
              digitCount + 1 < characters.count,
              characters[digitCount] == ".",
              characters[digitCount + 1] == " " else { return nil }
        return (
            number: String(characters.prefix(digitCount)),
            content: String(characters.dropFirst(digitCount + 2))
        )
    }

    // MARK: - Table Rendering

    static func isMarkdownTableSeparator(_ line: String) -> Bool {
        let compact = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "")
        guard compact.contains("|"), compact.contains("-") else { return false }
        return compact.allSatisfy { character in
            character == "|" || character == "-" || character == ":"
        }
    }

    static func renderMarkdownTable(lines: [String], startIndex: Int) -> (html: String, nextIndex: Int) {
        let headers = splitMarkdownTableRow(lines[startIndex])
        var html = "<table><thead><tr>"
        for header in headers {
            html += "<th>\(renderMarkdownInline(header))</th>"
        }
        html += "</tr></thead><tbody>"

        var index = startIndex + 2
        while index < lines.count {
            let line = lines[index]
            guard line.contains("|"),
                  !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            let cells = splitMarkdownTableRow(line)
            html += "<tr>"
            for cell in cells {
                html += "<td>\(renderMarkdownInline(cell))</td>"
            }
            html += "</tr>"
            index += 1
        }

        html += "</tbody></table>"
        return (html, index)
    }

    static func splitMarkdownTableRow(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.first == "|" {
            row.removeFirst()
        }
        if row.last == "|" {
            row.removeLast()
        }
        return row.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Inline Rendering

    static func renderMarkdownInline(_ text: String) -> String {
        var html = escapedHTML(text)
        var codePlaceholders: [String: String] = [:]
        html = replaceMarkdownPattern("!\\[([^\\]]*)\\]\\(([^\\)]+)\\)", in: html, with: "<img src=\"$2\" alt=\"$1\">")
        html = replaceMarkdownPattern("\\[([^\\]]+)\\]\\(([^\\)]+)\\)", in: html, with: "<a href=\"$2\">$1</a>")
        html = replaceInlineCodeSpans(in: html, placeholders: &codePlaceholders)
        html = replaceMarkdownPattern("\\*\\*([^*]+)\\*\\*", in: html, with: "<strong>$1</strong>")
        html = replaceMarkdownPattern("(?<![\\p{L}\\p{N}])__([^_\\n]+?)__(?![\\p{L}\\p{N}])", in: html, with: "<strong>$1</strong>")
        html = replaceMarkdownPattern("\\*([^*]+)\\*", in: html, with: "<em>$1</em>")
        html = replaceMarkdownPattern("(?<![\\p{L}\\p{N}])_([^_\\n]+?)_(?![\\p{L}\\p{N}])", in: html, with: "<em>$1</em>")
        for (placeholder, codeHTML) in codePlaceholders {
            html = html.replacingOccurrences(of: placeholder, with: codeHTML)
        }
        return html
    }

    static func replaceInlineCodeSpans(in text: String, placeholders: inout [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: "`([^`]+)`") else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result = text

        for (offset, match) in matches.reversed().enumerated() {
            let placeholder = "\u{E000}CODE\(offset)\u{E000}"
            let codeText = nsText.substring(with: match.range(at: 1))
            placeholders[placeholder] = "<code>\(codeText)</code>"
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: placeholder)
            }
        }

        return result
    }

    static func renderMarkdownInlineHTMLFragment(_ text: String) -> String {
        var html = renderMarkdownInline(text)
        html = replaceMarkdownPattern("&lt;b&gt;(.+?)&lt;/b&gt;", in: html, with: "<strong>$1</strong>")
        html = replaceMarkdownPattern("&lt;strong&gt;(.+?)&lt;/strong&gt;", in: html, with: "<strong>$1</strong>")
        html = replaceMarkdownPattern("&lt;i&gt;(.+?)&lt;/i&gt;", in: html, with: "<em>$1</em>")
        html = replaceMarkdownPattern("&lt;em&gt;(.+?)&lt;/em&gt;", in: html, with: "<em>$1</em>")
        return html
    }

    static func replaceMarkdownPattern(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
