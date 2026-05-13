// PeekX - 文件项模型
// Copyright © 2025 ALTIC. All rights reserved.

import Cocoa
import Quartz
import UniformTypeIdentifiers

// MARK: - 文件项模型

/// 大纲列表中的一行。
///
/// `FileItem` 同时表示真实文件系统条目和压缩包内的虚拟条目。
/// 统一模型可以让大纲列表、复制路径、排序和元信息显示共用同一套逻辑。
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

    /// 为压缩包内条目创建虚拟行。这里的 `url` 仍指向压缩包本身，
    /// 因为成员文件只有在需要预览时才会被临时解出。
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
        // 使用常见的压缩包路径写法，避免复制出来的路径和真实路径混淆。
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
        // 父节点弱引用只用于树结构和界面状态，不参与所有权管理。
        for child in children {
            child.parent = self
        }
    }

    // QLPreviewItem 只能预览真实文件，不能直接预览压缩包内的虚拟条目。
    var previewItemURL: URL? { isArchiveEntry ? nil : url }
    var previewItemTitle: String { name }
}

// MARK: - URL 预览项

final class URLPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
        super.init()
    }
}
