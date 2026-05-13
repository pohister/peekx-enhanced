// PeekX - DOCX 预览支持
// Copyright © 2025 ALTIC. All rights reserved.

import Foundation

// MARK: - DOCX 预览错误

enum DOCXPreviewError: LocalizedError {
    case missingDocumentXML
    case invalidDocumentXML

    var errorDescription: String? {
        switch self {
        case .missingDocumentXML:
            return "Could not find the DOCX document body."
        case .invalidDocumentXML:
            return "Could not parse the DOCX document body."
        }
    }
}

// MARK: - DOCX 文本提取器

final class DOCXTextExtractor: NSObject, XMLParserDelegate {
    private var text = ""
    private var isInTextNode = false

    func extractText(from data: Data) throws -> String {
        text = ""
        isInTextNode = false

        let parser = XMLParser(data: data)
        parser.delegate = self

        guard parser.parse() else {
            throw parser.parserError ?? DOCXPreviewError.invalidDocumentXML
        }

        return normalize(text)
    }

    // Word XML 使用命名空间标签；解析时只关心本地名称即可。
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName, qName: qName) {
        case "t":
            isInTextNode = true
        case "tab":
            text += "\t"
        case "br", "cr":
            text += "\n"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInTextNode else { return }
        text += string
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
        case "p":
            text += "\n"
        default:
            break
        }
    }

    private func localName(_ elementName: String, qName: String?) -> String {
        let name = (qName?.isEmpty == false ? qName : elementName) ?? elementName
        return name.split(separator: ":").last.map(String.init) ?? name
    }

    private func normalize(_ rawText: String) -> String {
        var normalized = rawText
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while normalized.contains("\n\n\n") {
            normalized = normalized.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return normalized
    }
}
