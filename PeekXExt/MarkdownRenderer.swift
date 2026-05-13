// PeekX - Markdown 渲染引擎
// Copyright © 2025 ALTIC. All rights reserved.

import Cocoa
import JavaScriptCore

struct MarkdownRenderResult {
    let html: String
    let plainText: String
    let rendererName: String
    let fallbackReason: String?
}

private protocol MarkdownHTMLRendering {
    var name: String { get }
    func render(markdown: String, sourceURL: URL) throws -> String
}

private enum MarkdownRenderFailure: LocalizedError {
    case vsCodeNotInstalled
    case vsCodeRendererMissing(URL)
    case vsCodeJavaScriptFailed(String)
    case vsCodeEmptyOutput

    var errorDescription: String? {
        switch self {
        case .vsCodeNotInstalled:
            return "Visual Studio Code.app was not found in /Applications or ~/Applications."
        case .vsCodeRendererMissing(let appURL):
            return "VS Code markdown-it renderer was not found inside \(appURL.path)."
        case .vsCodeJavaScriptFailed(let message):
            return "VS Code markdown-it renderer failed: \(message)"
        case .vsCodeEmptyOutput:
            return "VS Code markdown-it renderer produced empty HTML."
        }
    }
}

private struct VSCodeMarkdownRenderer: MarkdownHTMLRendering {
    let name = "VS Code MarkdownIt"

    private static let rendererRelativePath = "Contents/Resources/app/extensions/markdown-language-features/notebook-out/index.js"

    func render(markdown: String, sourceURL _: URL) throws -> String {
        guard let appURL = Self.applicationURL() else {
            throw MarkdownRenderFailure.vsCodeNotInstalled
        }
        let rendererURL = appURL.appendingPathComponent(Self.rendererRelativePath)
        guard FileManager.default.fileExists(atPath: rendererURL.path) else {
            throw MarkdownRenderFailure.vsCodeRendererMissing(appURL)
        }

        let htmlFragment = try Self.renderHTMLFragment(markdown, rendererURL: rendererURL)
        guard !htmlFragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MarkdownRenderFailure.vsCodeEmptyOutput
        }
        return MarkdownRenderer.originalMarkdownHTML(body: """
            <div id="content">\(htmlFragment)</div>
        """)
    }

    private static func applicationURL() -> URL? {
        let homeApplicationsURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
        let candidates = [
            URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Visual Studio Code - Insiders.app", isDirectory: true),
            homeApplicationsURL.appendingPathComponent("Visual Studio Code.app", isDirectory: true),
            homeApplicationsURL.appendingPathComponent("Visual Studio Code - Insiders.app", isDirectory: true)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func renderHTMLFragment(_ markdown: String, rendererURL: URL) throws -> String {
        guard let context = JSContext() else {
            throw MarkdownRenderFailure.vsCodeJavaScriptFailed("Could not create JavaScriptCore context.")
        }

        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString()
        }

        context.evaluateScript(javaScriptDOMStub)
        try throwIfNeeded(exceptionMessage)

        // 直接复用 VS Code 自带的 markdown-it 打包文件，尽量获得和 VS Code
        // 一致的 Markdown 语法表现。
        let rendererSource = try String(contentsOf: rendererURL, encoding: .utf8)
        guard rendererSource.contains("export{lu as activate};") else {
            throw MarkdownRenderFailure.vsCodeJavaScriptFailed("Unsupported VS Code renderer bundle format.")
        }
        context.evaluateScript(rendererSource.replacingOccurrences(
            of: "export{lu as activate};",
            with: "globalThis.__activate = lu;"
        ))
        try throwIfNeeded(exceptionMessage)

        context.evaluateScript("globalThis.__renderer = globalThis.__activate({ workspace: { isTrusted: true } });")
        try throwIfNeeded(exceptionMessage)

        let markdownData = try JSONSerialization.data(withJSONObject: [markdown])
        guard let markdownJSON = String(data: markdownData, encoding: .utf8) else {
            throw MarkdownRenderFailure.vsCodeJavaScriptFailed("Could not serialize Markdown input.")
        }

        // VS Code 的渲染器面向浏览器环境，这里用 JavaScriptCore 和最小 DOM stub
        // 只捕获它写入的 HTML 字符串。
        context.evaluateScript("""
            globalThis.__capturedHTML = "";
            globalThis.__markdownInput = \(markdownJSON)[0];
            globalThis.__renderer.renderOutputItem(
                {
                    mime: "text/markdown",
                    text: function() { return globalThis.__markdownInput; }
                },
                {
                    attachShadow: function() {
                        return {
                            appendChild: function() {},
                            getElementById: function() { return null; }
                        };
                    }
                }
            );
        """)
        try throwIfNeeded(exceptionMessage)

        return context.objectForKeyedSubscript("__capturedHTML")?.toString() ?? ""
    }

    private static func throwIfNeeded(_ message: String?) throws {
        if let message, !message.isEmpty {
            throw MarkdownRenderFailure.vsCodeJavaScriptFailed(message)
        }
    }

    // 供 VS Code 渲染器运行的最小 DOM 环境；没有真实页面，只记录 innerHTML。
    private static let javaScriptDOMStub = """
        globalThis.__capturedHTML = "";
        var window = globalThis;
        var document = {
            documentElement: {
                style: {
                    getPropertyValue: function() { return ""; }
                }
            },
            head: {
                appendChild: function() {}
            },
            createElement: function(tag) {
                var element = {
                    tagName: tag,
                    id: "",
                    classList: {
                        add: function() {},
                        remove: function() {}
                    },
                    content: {
                        appendChild: function() {},
                        cloneNode: function() { return {}; }
                    },
                    appendChild: function() {},
                    cloneNode: function() { return this; },
                    attachShadow: function() {
                        return {
                            appendChild: function() {},
                            getElementById: function() { return null; }
                        };
                    }
                };
                Object.defineProperty(element, "innerHTML", {
                    get: function() { return globalThis.__capturedHTML; },
                    set: function(value) { globalThis.__capturedHTML = value; }
                });
                Object.defineProperty(element, "innerText", {
                    get: function() { return globalThis.__capturedHTML; },
                    set: function(value) { globalThis.__capturedHTML = value; }
                });
                return element;
            },
            getElementById: function() {
                return {
                    cloneNode: function() { return {}; }
                };
            },
            getElementsByClassName: function() {
                return [];
            }
        };
    """
}

// MARK: - Markdown 渲染器

enum MarkdownRenderer {

    // MARK: - 对外接口

    static func renderMarkdownDocument(_ markdown: String, sourceURL: URL) -> MarkdownRenderResult {
        let vsCodeRenderer = VSCodeMarkdownRenderer()
        do {
            let html = try vsCodeRenderer.render(markdown: markdown, sourceURL: sourceURL)
            return MarkdownRenderResult(
                html: html,
                plainText: markdown,
                rendererName: vsCodeRenderer.name,
                fallbackReason: nil
            )
        } catch {
            // VS Code 未安装或其内部打包格式变化时，回退到内置轻量解析器。
            return MarkdownRenderResult(
                html: makeOriginalMarkdownHTML(fromMarkdown: markdown),
                plainText: markdown,
                rendererName: "Built-in",
                fallbackReason: renderFailureDescription(error)
            )
        }
    }

    private static func renderFailureDescription(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

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
            strong { font-weight: 600; }
            em { font-style: italic; }
            ul, ol {
                margin: 0 0 16px 24px;
                padding-left: 20px;
            }
            li { margin: 4px 0; }
            li p { margin: 0 0 8px 0; }
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
                white-space: pre;
                background: #f6f8fa;
                padding: 16px;
                border-radius: 8px;
                overflow-x: auto;
                border: 1px solid #e1e4e8;
                margin: 16px 0;
            }
            pre code { white-space: pre; background: none; padding: 0; }
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
            details { margin: 16px 0; }
            summary { font-weight: 600; }
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

    // MARK: - 文本预览设置

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

        resetPreviewScrollPosition(in: textView)
    }

    static func setRenderedHTMLPreview(_ html: String, in textView: NSTextView) {
        let t0 = CFAbsoluteTimeGetCurrent()
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .black
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.enclosingScrollView?.drawsBackground = true
        textView.enclosingScrollView?.backgroundColor = .white
        textView.enclosingScrollView?.contentView.drawsBackground = true
        textView.enclosingScrollView?.contentView.backgroundColor = .white
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.widthTracksTextView = true

        let t1 = CFAbsoluteTimeGetCurrent()
        // NSTextView 只能显示 NSAttributedString，因此 HTML 最终仍需要导入成富文本。
        // 这里记录耗时，便于排查 Markdown 预览导致的主线程卡顿。
        if let data = html.data(using: .utf8),
           let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
           ) {
            let t2 = CFAbsoluteTimeGetCurrent()
            textView.textStorage?.setAttributedString(removingImportedTextLists(from: attributed))
            let t3 = CFAbsoluteTimeGetCurrent()
            resetPreviewScrollPosition(in: textView)
            let t4 = CFAbsoluteTimeGetCurrent()
            DebugLogger.shared.log(String(format: "[PERF] HTML render: setup=%.1fms import=%.1fms setAttr=%.1fms scroll=%.1fms total=%.1fms",
                                          (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000, (t4 - t3) * 1000, (t4 - t0) * 1000))
        } else {
            textView.string = html
            resetPreviewScrollPosition(in: textView)
            DebugLogger.shared.log(String(format: "[PERF] HTML render fallback: total=%.1fms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        }
    }

    private static func removingImportedTextLists(from attributed: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        // AppKit 导入 HTML 列表时会再叠加一套 NSTextList 标记，
        // 对已经包含项目符号的 HTML 会造成“双点”显示，因此移除它。
        mutable.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            guard
                let paragraphStyle = value as? NSParagraphStyle,
                paragraphStyle.textLists.isEmpty == false,
                let mutableStyle = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle
            else { return }

            mutableStyle.textLists = []
            mutable.addAttribute(.paragraphStyle, value: mutableStyle, range: range)
        }
        return mutable
    }

    private static func resetPreviewScrollPosition(in textView: NSTextView) {
        func applyReset() {
            guard let scrollView = textView.enclosingScrollView else { return }
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.origin.y))
            scrollView.horizontalScroller?.floatValue = 0
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // NSTextView 在设置富文本后会异步重算布局；多次轻量重置可以稳定保证
        // Markdown 初始横向滚动条位于最左侧。
        applyReset()
        DispatchQueue.main.async {
            applyReset()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                applyReset()
            }
        }
    }

    static func markdownLoadingHTML() -> String {
        originalMarkdownHTML(body: "<p>Loading...</p>")
    }

    // MARK: - HTML 转义

    static func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - 内置 Markdown 到 HTML

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
            // 代码块后追加空行，避免下一段文本紧贴代码块边框。
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

    // MARK: - 块级元素解析

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

    // MARK: - 表格渲染

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

    // MARK: - 行内元素渲染

    static func renderMarkdownInline(_ text: String) -> String {
        var html = escapedHTML(text)
        var codePlaceholders: [String: String] = [:]
        html = replaceMarkdownPattern("!\\[([^\\]]*)\\]\\(([^\\)]+)\\)", in: html, with: "<img src=\"$2\" alt=\"$1\">")
        html = replaceMarkdownPattern("\\[([^\\]]+)\\]\\(([^\\)]+)\\)", in: html, with: "<a href=\"$2\">$1</a>")
        // 行内代码先用占位符保护，避免其中的星号、下划线被强调规则误处理。
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
