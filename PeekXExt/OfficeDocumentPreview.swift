// PeekX - Office OOXML 原生图文预览支持
// Copyright © 2025 ALTIC. All rights reserved.

import Foundation
import UniformTypeIdentifiers

// MARK: - Office 预览类型

enum OfficeDocumentPreviewKind {
    case ppt
    case pptx
    case docx
    case xlsx

    init?(url: URL, contentType: UTType?) {
        let ext = url.pathExtension.lowercased()
        let identifier = contentType?.identifier
        if ext == "ppt" || identifier == "com.microsoft.powerpoint.ppt" {
            self = .ppt
            return
        }
        if ext == "pptx" || identifier == "org.openxmlformats.presentationml.presentation" {
            self = .pptx
            return
        }
        if ext == "docx" || identifier == "org.openxmlformats.wordprocessingml.document" {
            self = .docx
            return
        }
        if ext == "xlsx" || identifier == "org.openxmlformats.spreadsheetml.sheet" {
            self = .xlsx
            return
        }
        return nil
    }
}

enum OfficeDocumentPreviewError: LocalizedError {
    case missingReadableContent
    case quickLookExportFailed(String)
    case quickLookExportTimedOut
    case missingQuickLookHTML

    var errorDescription: String? {
        switch self {
        case .missingReadableContent:
            return "Could not find readable Office document content."
        case .quickLookExportFailed(let message):
            return "Could not export native Quick Look preview: \(message)"
        case .quickLookExportTimedOut:
            return "Native Quick Look preview export timed out."
        case .missingQuickLookHTML:
            return "Native Quick Look did not produce Preview.html."
        }
    }
}

// MARK: - 系统 Quick Look HTML 导出

struct OfficeQuickLookHTMLExporter {
    func exportPreviewHTML(for url: URL, kind: OfficeDocumentPreviewKind, workingDirectory: URL) throws -> URL {
        let htmlURL: URL
        do {
            htmlURL = try exportPreviewHTMLDirectly(for: url, workingDirectory: workingDirectory)
        } catch {
            DebugLogger.shared.log("Direct qlmanage export failed for \(url.lastPathComponent): \(error.localizedDescription); trying containing app helper")
            htmlURL = try exportPreviewHTMLThroughContainingApp(for: url, workingDirectory: workingDirectory)
        }
        return try makeWebKitCompatiblePreviewHTML(from: htmlURL, kind: kind)
    }

    private func exportPreviewHTMLDirectly(for url: URL, workingDirectory: URL) throws -> URL {
        let outputDirectory = workingDirectory
            .appendingPathComponent("OfficeQuickLookHTML", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", "-o", outputDirectory.path, url.path]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        try process.run()
        guard semaphore.wait(timeout: .now() + 12) == .success else {
            process.terminate()
            throw OfficeDocumentPreviewError.quickLookExportTimedOut
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw OfficeDocumentPreviewError.quickLookExportFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let htmlURL = findPreviewHTML(in: outputDirectory) else {
            throw OfficeDocumentPreviewError.missingQuickLookHTML
        }

        DebugLogger.shared.log("Office native Quick Look exported HTML for \(url.lastPathComponent): \(htmlURL.path)")
        return htmlURL
    }

    private func findPreviewHTML(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "Preview.html" {
                return url
            }
        }
        return nil
    }

    private func makeWebKitCompatiblePreviewHTML(from htmlURL: URL, kind: OfficeDocumentPreviewKind) throws -> URL {
        var html = try String(contentsOf: htmlURL, encoding: .utf8)
        let originalLength = html.count

        html = normalizeUnitlessCSSLengths(in: html)
        html = restoreOfficeLineHeightMultipliers(in: html)
        html = cleanDimensionAttributes(in: html)
        html = normalizeViewportMeta(in: html)
        try normalizeLinkedStylesheets(nextTo: htmlURL)

        let compatibilityCSS = compatibilityCSS(for: kind)
        if let headEnd = html.range(of: "</head>", options: [.caseInsensitive]) {
            html.insert(contentsOf: compatibilityCSS, at: headEnd.lowerBound)
        }

        let layoutScript = layoutScript(for: kind)
        if let bodyEnd = html.range(of: "</body>", options: [.caseInsensitive]) {
            html.insert(contentsOf: layoutScript, at: bodyEnd.lowerBound)
        }

        let outputURL = htmlURL
            .deletingLastPathComponent()
            .appendingPathComponent("Preview.peekx.html")
        try html.write(to: outputURL, atomically: true, encoding: .utf8)

        DebugLogger.shared.log(
            "Office Quick Look HTML prepared for WebKit: source=\(htmlURL.path) output=\(outputURL.path) originalChars=\(originalLength) finalChars=\(html.count)"
        )
        return outputURL
    }

    private func normalizeLinkedStylesheets(nextTo htmlURL: URL) throws {
        let directory = htmlURL.deletingLastPathComponent()
        let cssURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "css" }

        for cssURL in cssURLs {
            var css = try String(contentsOf: cssURL, encoding: .utf8)
            let originalLength = css.count
            css = normalizeUnitlessCSSLengths(in: css)
            css = restoreOfficeLineHeightMultipliers(in: css)
            if css.count != originalLength {
                try css.write(to: cssURL, atomically: true, encoding: .utf8)
                DebugLogger.shared.log("Office Quick Look stylesheet normalized for WebKit: path=\(cssURL.path) originalChars=\(originalLength) finalChars=\(css.count)")
            }
        }
    }

    private func normalizeViewportMeta(in html: String) -> String {
        let viewport = #"<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=4.0">"#
        let pattern = #"<meta\s+name=["']viewport["'][^>]*>"#
        if html.range(of: pattern, options: [.caseInsensitive, .regularExpression]) != nil {
            return html.replacingOccurrences(
                of: pattern,
                with: viewport,
                options: [.caseInsensitive, .regularExpression]
            )
        }

        var result = html
        if let headEnd = result.range(of: "</head>", options: [.caseInsensitive]) {
            result.insert(contentsOf: viewport, at: headEnd.lowerBound)
        }
        return result
    }

    private func normalizeUnitlessCSSLengths(in htmlOrCSS: String) -> String {
        htmlOrCSS.replacingOccurrences(
            of: #"(?i)(^|[;{"]\s*)(\b(?:width|height|top|left|right|bottom|font-size|text-indent|min-width|max-width|min-height|max-height|margin(?:-(?:top|right|bottom|left))?|padding(?:-(?:top|right|bottom|left))?|border(?:-(?:top|right|bottom|left))?-width)\s*:\s*)(-?\d+(?:\.\d+)?)(\s*(?=[;}"]))"#,
            with: "$1$2$3px$4",
            options: .regularExpression
        )
    }

    private func restoreOfficeLineHeightMultipliers(in htmlOrCSS: String) -> String {
        htmlOrCSS.replacingOccurrences(
            of: #"(?i)(\bline-height\s*:\s*)(-?\d+(?:\.\d+)?)px(\s*(?=[;}]))"#,
            with: "$1$2$3",
            options: .regularExpression
        )
    }

    private func cleanDimensionAttributes(in html: String) -> String {
        html.replacingOccurrences(
            of: #"(?i)(\b(?:width|height)=")(\d+(?:\.\d+)?);"#,
            with: "$1$2\"",
            options: .regularExpression
        )
    }

    private func compatibilityCSS(for kind: OfficeDocumentPreviewKind) -> String {
        switch kind {
        case .ppt, .pptx:
            return """
            <style id="peekx-office-compat">
            html, body { margin: 0; padding: 0; width: 100%; height: 100%; min-height: 100%; overflow: hidden; }
            body { -webkit-text-size-adjust: 100%; background: transparent !important; }
            #peekx-office-scroll-root { position: fixed; inset: 0; width: 100%; height: 100%; overflow: scroll; box-sizing: border-box; scrollbar-gutter: stable; }
            #peekx-office-content-root { display: inline-block; min-width: 100%; transform-origin: 0 0; }
            #peekx-office-scroll-root::-webkit-scrollbar { width: 14px; height: 14px; }
            #peekx-office-scroll-root::-webkit-scrollbar-track { background: rgba(128, 128, 128, 0.10); border-radius: 7px; }
            #peekx-office-scroll-root::-webkit-scrollbar-thumb { background: rgba(96, 96, 96, 0.56); border-radius: 7px; border: 3px solid rgba(255, 255, 255, 0.35); background-clip: padding-box; }
            #peekx-office-scroll-root::-webkit-scrollbar-corner { background: transparent; }
            img, table { max-width: none; }
            .peekx-pptx-page { width: 100%; position: relative; overflow: hidden; background: white; box-sizing: border-box; contain: layout paint; isolation: isolate; }
            .peekx-pptx-page + .peekx-pptx-page { margin-top: 12px; }
            </style>
            """
        case .docx:
            return """
            <style id="peekx-office-compat">
            html, body { margin: 0; padding: 0; width: 100%; height: 100%; min-height: 100%; overflow: hidden; }
            body { -webkit-text-size-adjust: 100%; background: transparent !important; }
            #peekx-office-scroll-root { position: fixed; inset: 0; width: 100%; height: 100%; overflow: scroll; box-sizing: border-box; scrollbar-gutter: stable; }
            #peekx-office-content-root { display: inline-block; min-width: 100%; transform-origin: 0 0; }
            #peekx-office-scroll-root::-webkit-scrollbar { width: 14px; height: 14px; }
            #peekx-office-scroll-root::-webkit-scrollbar-track { background: rgba(128, 128, 128, 0.10); border-radius: 7px; }
            #peekx-office-scroll-root::-webkit-scrollbar-thumb { background: rgba(96, 96, 96, 0.56); border-radius: 7px; border: 3px solid rgba(255, 255, 255, 0.35); background-clip: padding-box; }
            #peekx-office-scroll-root::-webkit-scrollbar-corner { background: transparent; }
            img, table { max-width: none; }
            .peekx-docx-page { background: white; box-sizing: content-box; transform-origin: 0 0; }
            </style>
            """
        case .xlsx:
            return """
            <style id="peekx-office-compat">
            html, body { margin: 0; padding: 0; width: 100%; height: 100%; min-width: 100%; min-height: 100%; overflow: hidden; }
            body { -webkit-text-size-adjust: 100%; background: white; box-sizing: border-box; }
            #peekx-office-scroll-root { position: fixed; inset: 0; width: 100%; height: 100%; overflow: scroll; box-sizing: border-box; padding-top: 12px; scrollbar-gutter: stable; }
            #peekx-office-content-root { display: inline-block; min-width: 100%; transform-origin: 0 0; }
            #peekx-office-scroll-root::-webkit-scrollbar { width: 14px; height: 14px; }
            #peekx-office-scroll-root::-webkit-scrollbar-track { background: rgba(128, 128, 128, 0.10); border-radius: 7px; }
            #peekx-office-scroll-root::-webkit-scrollbar-thumb { background: rgba(96, 96, 96, 0.56); border-radius: 7px; border: 3px solid rgba(255, 255, 255, 0.35); background-clip: padding-box; }
            #peekx-office-scroll-root::-webkit-scrollbar-corner { background: transparent; }
            table.worksheet { max-width: none; }
            </style>
            """
        }
    }

    private func layoutScript(for kind: OfficeDocumentPreviewKind) -> String {
        switch kind {
        case .ppt, .pptx:
            return """
            <script id="peekx-office-layout">
            (function() {
              function ensureOfficeScrollRoot() {
                var existingRoot = document.getElementById("peekx-office-scroll-root");
                var existingContent = document.getElementById("peekx-office-content-root");
                if (existingRoot && existingContent) {
                  return { root: existingRoot, content: existingContent };
                }

                var root = document.createElement("div");
                root.id = "peekx-office-scroll-root";
                var content = document.createElement("div");
                content.id = "peekx-office-content-root";
                var currentScript = document.currentScript;
                var nodes = Array.prototype.slice.call(document.body ? document.body.childNodes : []);
                for (var i = 0; i < nodes.length; i++) {
                  var node = nodes[i];
                  if (node === currentScript) { continue; }
                  if (node.nodeType === 1 && node.id === "peekx-office-scroll-root") { continue; }
                  content.appendChild(node);
                }
                root.appendChild(content);
                document.body.insertBefore(root, currentScript || null);
                return { root: root, content: content };
              }

              function numberFromStyle(value, fallback) {
                var parsed = parseFloat(value || "");
                return isFinite(parsed) && parsed > 0 ? parsed : fallback;
              }

              function ensurePages() {
                var slides = Array.prototype.slice.call(document.querySelectorAll("div.slide"));
                for (var i = 0; i < slides.length; i++) {
                  var slide = slides[i];
                  if (slide.parentElement && slide.parentElement.className === "peekx-pptx-page") {
                    continue;
                  }
                  var page = document.createElement("div");
                  page.className = "peekx-pptx-page";
                  slide.parentNode.insertBefore(page, slide);
                  page.appendChild(slide);
                }
              }

              function layout() {
                var wrapper = ensureOfficeScrollRoot();
                ensurePages();
                var viewportWidth = Math.max(1, wrapper.root.clientWidth || document.documentElement.clientWidth || window.innerWidth || 1);
                var pages = Array.prototype.slice.call(document.querySelectorAll(".peekx-pptx-page"));
                for (var i = 0; i < pages.length; i++) {
                  var page = pages[i];
                  var slide = page.querySelector("div.slide");
                  if (!slide) { continue; }

                  var baseWidth = numberFromStyle(slide.dataset.peekxBaseWidth, 0);
                  var baseHeight = numberFromStyle(slide.dataset.peekxBaseHeight, 0);
                  if (!baseWidth || !baseHeight) {
                    var style = window.getComputedStyle(slide);
                    baseWidth = numberFromStyle(style.width, slide.offsetWidth || 960);
                    baseHeight = numberFromStyle(style.height, slide.offsetHeight || 540);
                    slide.dataset.peekxBaseWidth = String(baseWidth);
                    slide.dataset.peekxBaseHeight = String(baseHeight);
                  }

                  var scale = viewportWidth / baseWidth;
                  page.style.width = "100%";
                  page.style.height = Math.ceil(baseHeight * scale) + "px";
                  slide.style.position = "relative";
                  slide.style.top = "0";
                  slide.style.left = "0";
                  slide.style.width = baseWidth + "px";
                  slide.style.height = baseHeight + "px";
                  slide.style.margin = "0";
                  slide.style.transform = "none";
                  slide.style.transformOrigin = "0 0";
                  slide.style.zoom = String(scale);
                  slide.style.webkitFontSmoothing = "antialiased";
                }
                wrapper.content.style.minWidth = viewportWidth + "px";
              }

              if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", layout);
              } else {
                layout();
              }
              window.addEventListener("load", layout);
              window.addEventListener("resize", layout);
            })();
            </script>
            """
        case .docx:
            return """
            <script id="peekx-office-layout">
            (function() {
              function ensureOfficeScrollRoot() {
                var existingRoot = document.getElementById("peekx-office-scroll-root");
                var existingContent = document.getElementById("peekx-office-content-root");
                if (existingRoot && existingContent) {
                  return { root: existingRoot, content: existingContent };
                }

                var root = document.createElement("div");
                root.id = "peekx-office-scroll-root";
                var content = document.createElement("div");
                content.id = "peekx-office-content-root";
                var currentScript = document.currentScript;
                var nodes = Array.prototype.slice.call(document.body ? document.body.childNodes : []);
                for (var i = 0; i < nodes.length; i++) {
                  var node = nodes[i];
                  if (node === currentScript) { continue; }
                  if (node.nodeType === 1 && node.id === "peekx-office-scroll-root") { continue; }
                  content.appendChild(node);
                }
                root.appendChild(content);
                document.body.insertBefore(root, currentScript || null);
                return { root: root, content: content };
              }

              function numberFromStyle(value, fallback) {
                var parsed = parseFloat(value || "");
                return isFinite(parsed) && parsed > 0 ? parsed : fallback;
              }

              function documentPage(contentRoot) {
                var children = Array.prototype.slice.call(contentRoot ? contentRoot.children : []);
                for (var i = 0; i < children.length; i++) {
                  var child = children[i];
                  var tag = (child.tagName || "").toUpperCase();
                  if (tag !== "STYLE" && tag !== "SCRIPT") {
                    return child;
                  }
                }
                return null;
              }

              function layout() {
                var wrapper = ensureOfficeScrollRoot();
                var page = documentPage(wrapper.content);
                if (!page) { return; }
                page.classList.add("peekx-docx-page");

                var viewportWidth = Math.max(1, wrapper.root.clientWidth || document.documentElement.clientWidth || window.innerWidth || 1);
                var baseWidth = numberFromStyle(page.dataset.peekxBaseWidth, 0);
                if (!baseWidth) {
                  var style = window.getComputedStyle(page);
                  var contentWidth = numberFromStyle(style.width, page.offsetWidth || page.scrollWidth || 595);
                  var paddingLeft = numberFromStyle(style.paddingLeft, 0);
                  var paddingRight = numberFromStyle(style.paddingRight, 0);
                  baseWidth = Math.max(1, page.scrollWidth || page.offsetWidth || contentWidth + paddingLeft + paddingRight);
                  page.dataset.peekxBaseWidth = String(baseWidth);
                }

                var scale = viewportWidth / baseWidth;
                page.style.margin = "0";
                page.style.zoom = String(scale);
                page.style.webkitFontSmoothing = "antialiased";
                wrapper.content.style.minWidth = viewportWidth + "px";
              }

              if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", layout);
              } else {
                layout();
              }
              window.addEventListener("load", layout);
              window.addEventListener("resize", layout);
            })();
            </script>
            """
        case .xlsx:
            return """
            <script id="peekx-office-layout">
            (function() {
              function ensureOfficeScrollRoot() {
                var existingRoot = document.getElementById("peekx-office-scroll-root");
                var existingContent = document.getElementById("peekx-office-content-root");
                if (existingRoot && existingContent) {
                  return { root: existingRoot, content: existingContent };
                }

                var root = document.createElement("div");
                root.id = "peekx-office-scroll-root";
                var content = document.createElement("div");
                content.id = "peekx-office-content-root";
                var currentScript = document.currentScript;
                var nodes = Array.prototype.slice.call(document.body ? document.body.childNodes : []);
                for (var i = 0; i < nodes.length; i++) {
                  var node = nodes[i];
                  if (node === currentScript) { continue; }
                  if (node.nodeType === 1 && node.id === "peekx-office-scroll-root") { continue; }
                  content.appendChild(node);
                }
                root.appendChild(content);
                document.body.insertBefore(root, currentScript || null);
                return { root: root, content: content };
              }

              function numberFromStyle(value, fallback) {
                var parsed = parseFloat(value || "");
                return isFinite(parsed) && parsed > 0 ? parsed : fallback;
              }

              function layout() {
                var wrapper = ensureOfficeScrollRoot();
                var viewportWidth = Math.max(1, wrapper.root.clientWidth || document.documentElement.clientWidth || window.innerWidth || 1);
                var maxWidth = viewportWidth;
                var tables = Array.prototype.slice.call(document.querySelectorAll("table.worksheet, table"));

                for (var i = 0; i < tables.length; i++) {
                  var table = tables[i];
                  var naturalWidth = numberFromStyle(table.dataset.peekxNaturalWidth, 0);
                  if (!naturalWidth) {
                    var inlineWidth = numberFromStyle(table.style.width, 0);
                    naturalWidth = inlineWidth || table.scrollWidth || table.offsetWidth || viewportWidth;
                    table.dataset.peekxNaturalWidth = String(naturalWidth);
                  }

                  if (naturalWidth < viewportWidth) {
                    table.style.width = "100%";
                    table.style.minWidth = naturalWidth + "px";
                    maxWidth = Math.max(maxWidth, viewportWidth);
                  } else {
                    table.style.width = naturalWidth + "px";
                    table.style.minWidth = naturalWidth + "px";
                    maxWidth = Math.max(maxWidth, naturalWidth);
                  }
                }

                wrapper.content.style.minWidth = Math.ceil(maxWidth) + "px";
              }

              if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", layout);
              } else {
                layout();
              }
              window.addEventListener("load", layout);
              window.addEventListener("resize", layout);
            })();
            </script>
            """
        }
    }

    private func exportPreviewHTMLThroughContainingApp(for url: URL, workingDirectory: URL) throws -> URL {
        let requestID = UUID().uuidString
        let requestDirectory = workingDirectory
            .appendingPathComponent("OfficeQuickLookRequests", isDirectory: true)
            .appendingPathComponent(requestID, isDirectory: true)
        let outputDirectory = requestDirectory.appendingPathComponent("Output", isDirectory: true)
        let requestURL = requestDirectory.appendingPathComponent("request.json")
        let responseURL = requestDirectory.appendingPathComponent("response.json")

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let request = OfficePreviewHelperRequest(
            requestID: requestID,
            inputPath: url.path,
            outputPath: outputDirectory.path,
            responsePath: responseURL.path
        )
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)

        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.pohister.PeekX.officePreviewRequest"),
            object: requestID,
            userInfo: ["requestPath": requestURL.path],
            deliverImmediately: true
        )

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: responseURL.path) {
                let responseData = try Data(contentsOf: responseURL)
                let response = try JSONDecoder().decode(OfficePreviewHelperResponse.self, from: responseData)
                if let htmlPath = response.htmlPath, response.status == "ok" {
                    let htmlURL = URL(fileURLWithPath: htmlPath)
                    DebugLogger.shared.log("Office containing app exported HTML for \(url.lastPathComponent): \(htmlURL.path)")
                    return htmlURL
                }
                throw OfficeDocumentPreviewError.quickLookExportFailed(response.error ?? "Unknown helper error.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        throw OfficeDocumentPreviewError.quickLookExportTimedOut
    }
}

struct OfficePreviewHelperRequest: Codable {
    let requestID: String
    let inputPath: String
    let outputPath: String
    let responsePath: String
}

struct OfficePreviewHelperResponse: Codable {
    let requestID: String
    let status: String
    let htmlPath: String?
    let error: String?
}

// MARK: - Office 文本提取器

final class OfficeDocumentTextExtractor {
    private let provider = LibarchiveArchiveProvider()

    func extractPreview(from url: URL, kind: OfficeDocumentPreviewKind) throws -> String {
        switch kind {
        case .ppt:
            throw OfficeDocumentPreviewError.missingReadableContent
        case .pptx:
            return try extractPresentationText(from: url)
        case .docx:
            return try extractWordText(from: url)
        case .xlsx:
            return try extractSpreadsheetText(from: url)
        }
    }

    private func extractWordText(from url: URL) throws -> String {
        let tempDirectory = makeTemporaryDirectory(named: "PeekXDOCXPreviews")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let documentXMLURL = tempDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("xml")
        try provider.extractEntry("word/document.xml", from: url, to: documentXMLURL)
        let data = try Data(contentsOf: documentXMLURL)
        return try DOCXTextExtractor().extractText(from: data)
    }

    private func extractPresentationText(from url: URL) throws -> String {
        let listing = try provider.listContainerContents(of: url)
        let slidePaths = listing.entries
            .map(\.path)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard !slidePaths.isEmpty else {
            throw OfficeDocumentPreviewError.missingReadableContent
        }

        let tempDirectory = makeTemporaryDirectory(named: "PeekXPPTXPreviews")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sections = try slidePaths.enumerated().compactMap { index, path -> String? in
            let xmlURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("xml")
            try provider.extractEntry(path, from: url, to: xmlURL)
            let data = try Data(contentsOf: xmlURL)
            let lines = try OOXMLTextNodeExtractor().extractTextLines(from: data)
            guard !lines.isEmpty else { return nil }
            return "Slide \(index + 1)\n" + lines.joined(separator: "\n")
        }

        guard !sections.isEmpty else {
            throw OfficeDocumentPreviewError.missingReadableContent
        }
        return sections.joined(separator: "\n\n")
    }

    private func extractSpreadsheetText(from url: URL) throws -> String {
        let listing = try provider.listContainerContents(of: url)
        let sheetPaths = listing.entries
            .map(\.path)
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard !sheetPaths.isEmpty else {
            throw OfficeDocumentPreviewError.missingReadableContent
        }

        let tempDirectory = makeTemporaryDirectory(named: "PeekXXLSXPreviews")
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sharedStrings = try extractSharedStrings(from: url, into: tempDirectory)
        let sheetNames = try extractSheetNames(from: url, into: tempDirectory)

        let sections = try sheetPaths.enumerated().compactMap { index, path -> String? in
            let xmlURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("xml")
            try provider.extractEntry(path, from: url, to: xmlURL)
            let data = try Data(contentsOf: xmlURL)
            let rows = try XLSXWorksheetTextExtractor(sharedStrings: sharedStrings).extractRows(from: data)
            guard !rows.isEmpty else { return nil }

            let name = index < sheetNames.count ? sheetNames[index] : "Sheet \(index + 1)"
            let body = rows
                .map { $0.joined(separator: "\t") }
                .joined(separator: "\n")
            return "\(name)\n\(body)"
        }

        guard !sections.isEmpty else {
            throw OfficeDocumentPreviewError.missingReadableContent
        }
        return sections.joined(separator: "\n\n")
    }

    private func extractSharedStrings(from url: URL, into tempDirectory: URL) throws -> [String] {
        let xmlURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("xml")
        do {
            try provider.extractEntry("xl/sharedStrings.xml", from: url, to: xmlURL)
        } catch ArchiveProviderError.entryNotFound {
            return []
        } catch {
            throw error
        }

        let data = try Data(contentsOf: xmlURL)
        return try XLSXSharedStringsExtractor().extractStrings(from: data)
    }

    private func extractSheetNames(from url: URL, into tempDirectory: URL) throws -> [String] {
        let xmlURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("xml")
        do {
            try provider.extractEntry("xl/workbook.xml", from: url, to: xmlURL)
        } catch ArchiveProviderError.entryNotFound {
            return []
        } catch {
            throw error
        }

        let data = try Data(contentsOf: xmlURL)
        return try XLSXWorkbookNameExtractor().extractSheetNames(from: data)
    }

    private func makeTemporaryDirectory(named name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

// MARK: - 通用 OOXML 文本节点解析

private final class OOXMLTextNodeExtractor: NSObject, XMLParserDelegate {
    private var isInTextNode = false
    private var currentText = ""
    private var lines: [String] = []

    func extractTextLines(from data: Data) throws -> [String] {
        isInTextNode = false
        currentText = ""
        lines = []

        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? OfficeDocumentPreviewError.missingReadableContent
        }
        flushCurrentText()
        return lines
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if localName(elementName, qName: qName) == "t" {
            isInTextNode = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInTextNode else { return }
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if localName(elementName, qName: qName) == "t" {
            isInTextNode = false
            flushCurrentText()
        }
    }

    private func flushCurrentText() {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            lines.append(text)
        }
        currentText = ""
    }
}

// MARK: - XLSX sharedStrings.xml

private final class XLSXSharedStringsExtractor: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var isInStringItem = false
    private var isInTextNode = false
    private var current = ""

    func extractStrings(from data: Data) throws -> [String] {
        strings = []
        isInStringItem = false
        isInTextNode = false
        current = ""

        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? OfficeDocumentPreviewError.missingReadableContent
        }
        return strings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName, qName: qName) {
        case "si":
            isInStringItem = true
            current = ""
        case "t":
            isInTextNode = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInStringItem, isInTextNode else { return }
        current += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName, qName: qName) {
        case "t":
            isInTextNode = false
        case "si":
            strings.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
            isInStringItem = false
        default:
            break
        }
    }
}

// MARK: - XLSX workbook.xml

private final class XLSXWorkbookNameExtractor: NSObject, XMLParserDelegate {
    private var names: [String] = []

    func extractSheetNames(from data: Data) throws -> [String] {
        names = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? OfficeDocumentPreviewError.missingReadableContent
        }
        return names
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard localName(elementName, qName: qName) == "sheet" else { return }
        if let name = attributeDict["name"], !name.isEmpty {
            names.append(name)
        }
    }
}

// MARK: - XLSX worksheet XML

private final class XLSXWorksheetTextExtractor: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var rows: [[String]] = []
    private var currentCells: [(column: Int, value: String)] = []
    private var currentColumn = 0
    private var currentCellType: String?
    private var currentValue = ""
    private var currentInlineText = ""
    private var isInCell = false
    private var isReadingValue = false
    private var isReadingInlineText = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func extractRows(from data: Data) throws -> [[String]] {
        rows = []
        currentCells = []
        currentColumn = 0
        currentCellType = nil
        currentValue = ""
        currentInlineText = ""
        isInCell = false
        isReadingValue = false
        isReadingInlineText = false

        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? OfficeDocumentPreviewError.missingReadableContent
        }
        return rows
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName, qName: qName) {
        case "row":
            currentCells = []
        case "c":
            isInCell = true
            currentCellType = attributeDict["t"]
            currentColumn = columnIndex(from: attributeDict["r"]) ?? currentCells.count
            currentValue = ""
            currentInlineText = ""
        case "v":
            if isInCell {
                isReadingValue = true
            }
        case "t":
            if isInCell {
                isReadingInlineText = true
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReadingValue {
            currentValue += string
        } else if isReadingInlineText {
            currentInlineText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName, qName: qName) {
        case "v":
            isReadingValue = false
        case "t":
            isReadingInlineText = false
        case "c":
            let value = resolvedCellValue().trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                currentCells.append((column: currentColumn, value: value))
            }
            isInCell = false
        case "row":
            let row = normalizedRow(from: currentCells)
            if row.contains(where: { !$0.isEmpty }) {
                rows.append(row)
            }
            currentCells = []
        default:
            break
        }
    }

    private func resolvedCellValue() -> String {
        switch currentCellType {
        case "s":
            guard let index = Int(currentValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  sharedStrings.indices.contains(index) else {
                return currentValue
            }
            return sharedStrings[index]
        case "inlineStr":
            return currentInlineText
        case "b":
            return currentValue.trimmingCharacters(in: .whitespacesAndNewlines) == "1" ? "TRUE" : "FALSE"
        default:
            return currentInlineText.isEmpty ? currentValue : currentInlineText
        }
    }

    private func normalizedRow(from cells: [(column: Int, value: String)]) -> [String] {
        let sortedCells = cells.sorted { $0.column < $1.column }
        guard let maxColumn = sortedCells.map(\.column).max(), maxColumn < 80 else {
            return sortedCells.map(\.value)
        }

        var row = Array(repeating: "", count: maxColumn + 1)
        for cell in sortedCells where row.indices.contains(cell.column) {
            row[cell.column] = cell.value
        }
        while row.last?.isEmpty == true {
            row.removeLast()
        }
        return row
    }

    private func columnIndex(from cellReference: String?) -> Int? {
        guard let cellReference else { return nil }
        let letters = cellReference.prefix { $0.isLetter }
        guard !letters.isEmpty else { return nil }

        var index = 0
        for scalar in letters.uppercased().unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            index = index * 26 + Int(scalar.value - 64)
        }
        return max(0, index - 1)
    }
}

private func localName(_ elementName: String, qName: String?) -> String {
    let name = (qName?.isEmpty == false ? qName : elementName) ?? elementName
    return name.split(separator: ":").last.map(String.init) ?? name
}
