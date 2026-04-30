// PeekX - File Item Model
// Copyright © 2025 ALTIC. All rights reserved.

import Cocoa
import Quartz
import UniformTypeIdentifiers

// MARK: - File Item Model

final class FileItem: NSObject, QLPreviewItem {
    let url: URL
    let name: String
    let isFolder: Bool
    let size: Int64
    let modificationDate: Date
    let hasModificationDate: Bool
    let contentType: UTType?
    let archiveURL: URL?
    let archiveEntryPath: String?
    let isEncryptedArchiveEntry: Bool
    let customKindDescription: String?
    weak var parent: FileItem?
    var icon: NSImage?
    var children: [FileItem]?
    var childrenLoaded = false

    private var _formattedSize: String?
    private var _formattedDate: String?
    private var _kindDescription: String?
    private var _previewInfo: String?

    init(url: URL, resourceValues: URLResourceValues, parent: FileItem? = nil) {
        self.url = url
        self.name = url.lastPathComponent
        self.isFolder = resourceValues.isDirectory ?? false
        self.size = Int64(resourceValues.fileSize ?? 0)
        self.modificationDate = resourceValues.contentModificationDate ?? Date.distantPast
        self.hasModificationDate = resourceValues.contentModificationDate != nil
        self.contentType = resourceValues.contentType
        self.archiveURL = nil
        self.archiveEntryPath = nil
        self.isEncryptedArchiveEntry = false
        self.customKindDescription = nil
        self.parent = parent
        super.init()
    }

    init(
        archiveURL: URL,
        entryPath: String,
        name: String,
        isFolder: Bool,
        size: Int64,
        modificationDate: Date?,
        kindDescription: String,
        isEncrypted: Bool = false,
        parent: FileItem? = nil
    ) {
        self.url = archiveURL
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modificationDate = modificationDate ?? Date.distantPast
        self.hasModificationDate = modificationDate != nil
        self.contentType = isFolder ? .folder : UTType(filenameExtension: (name as NSString).pathExtension)
        self.archiveURL = archiveURL
        self.archiveEntryPath = entryPath
        self.isEncryptedArchiveEntry = isEncrypted
        self.customKindDescription = kindDescription
        self.parent = parent
        super.init()
    }

    var isArchiveEntry: Bool {
        archiveEntryPath != nil
    }

    var copyPath: String {
        guard let archiveURL, let archiveEntryPath else {
            return url.path
        }
        return "\(archiveURL.path)!/\(archiveEntryPath)"
    }

    var kindDescription: String {
        if let cached = _kindDescription {
            return cached
        }
        let desc = customKindDescription ?? (isFolder ? "Folder" : (contentType?.localizedDescription ?? "File"))
        _kindDescription = desc
        return desc
    }

    func formattedSize(using formatter: ByteCountFormatter) -> String {
        if let cached = _formattedSize {
            return cached
        }
        let formatted = isFolder ? "—" : formatter.string(fromByteCount: size)
        _formattedSize = formatted
        return formatted
    }

    func formattedDate(using formatter: DateFormatter) -> String {
        if let cached = _formattedDate {
            return cached
        }
        let formatted = hasModificationDate ? formatter.string(from: modificationDate) : "Unknown date"
        _formattedDate = formatted
        return formatted
    }

    func previewInfo(sizeFormatter: ByteCountFormatter, dateFormatter: DateFormatter) -> String {
        if let cached = _previewInfo {
            return cached
        }
        var segments: [String] = []
        if !isFolder {
            segments.append(formattedSize(using: sizeFormatter))
        }
        segments.append(kindDescription)
        segments.append(formattedDate(using: dateFormatter))
        let info = segments.joined(separator: " · ")
        _previewInfo = info
        return info
    }

    func setChildren(_ children: [FileItem]) {
        self.children = children
        self.childrenLoaded = true
        for child in children {
            child.parent = self
        }
    }

    var previewItemURL: URL? { isArchiveEntry ? nil : url }
    var previewItemTitle: String { name }
}

// MARK: - URL Preview Item

final class URLPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
        super.init()
    }
}
