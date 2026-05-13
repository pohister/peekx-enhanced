// PeekX - 预览加载与内容展示
// Copyright © 2025 ALTIC. All rights reserved.

import Cocoa
import Quartz
import UniformTypeIdentifiers
import QuickLook
import QuickLookThumbnailing
import ImageIO
import PDFKit
import AVKit
// MARK: - 预览加载入口

extension PreviewViewController {

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        DebugLogger.shared.log("preparePreviewOfFile started for \(url.path)")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey])
                // 顶层 Quick Look 请求按容器类型分流：文件夹和压缩包走左侧树，
                // 普通文件走单文件全窗口预览。
                if values.isDirectory == true {
                    self.prepareFolderPreview(at: url, completionHandler: handler)
                    return
                }

                if let provider = ArchiveProviderRegistry.shared.provider(for: url, contentType: values.contentType) {
                    self.prepareArchivePreview(at: url, provider: provider, resourceValues: values, completionHandler: handler)
                    return
                }

                self.prepareSingleFilePreview(at: url, completionHandler: handler)
            } catch {
                DebugLogger.shared.log("Failed to build preview for \(url.lastPathComponent): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    handler(error)
                }
            }
        }
    }

    // MARK: - 文件夹预览

    func prepareFolderPreview(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let requestID = UUID()
        DispatchQueue.main.async {
            self.contentLoadRequestID = requestID
            handler(nil)
            self.showFolderLoading(for: url)
        }

        do {
            // 文件夹枚举在后台完成，主线程只做一次批量 UI 更新，
            // 避免大目录或 iCloud 目录阻塞 Quick Look 面板。
            let start = CFAbsoluteTimeGetCurrent()
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            var rootItems: [FileItem] = []
            rootItems.reserveCapacity(contents.count)
            var totalSize: Int64 = 0
            var folderCount = 0
            var fileCount = 0

            for entry in contents {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey])
                let item = FileItem(url: entry, resourceValues: values)
                if item.isFolder {
                    folderCount += 1
                } else {
                    fileCount += 1
                    totalSize += item.size
                }
                rootItems.append(item)
            }
            sortFileItems(&rootItems)

            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let infoText = "\(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)) · \(folderCount) folders, \(fileCount) files"

            DispatchQueue.main.async {
                guard self.contentLoadRequestID == requestID else { return }
                DebugLogger.shared.log("Applying folder preview for \(url.lastPathComponent) with \(contents.count) entries in \(String(format: "%.1f", elapsed)) ms")
                self.previewSpinner.stopAnimation(nil)
                self.rootItems = rootItems
                self.previewRootURL = url
                self.iconImageView.image = self.headerIcon(for: url)
                self.titleLabel.stringValue = url.lastPathComponent
                self.infoLabel.stringValue = infoText
                self.outlineView.reloadData()
                self.updateOutlineScrollMetrics(resetPosition: true)
                self.syncPreviewWithSelection()
            }
        } catch {
            DebugLogger.shared.log("Failed to enumerate folder \(url.lastPathComponent): \(error.localizedDescription)")
            DispatchQueue.main.async {
                guard self.contentLoadRequestID == requestID else { return }
                self.showFolderError(for: url, error: error)
            }
        }
    }

    func showFolderLoading(for url: URL) {
        applySingleFileLayout(false)
        previewTimeoutWorkItem?.cancel()
        previewTimeoutWorkItem = nil
        contentLoadTimeoutWorkItem?.cancel()
        contentLoadTimeoutWorkItem = nil
        activeInlinePreviewRequestID = nil

        let icon = headerIcon(for: url)
        rootItems = []
        previewRootURL = url
        iconImageView.image = icon
        titleLabel.stringValue = url.lastPathComponent
        infoLabel.stringValue = "Reading folder contents..."
        outlineView.reloadData()
        updateOutlineScrollMetrics(resetPosition: false)

        previewTitleLabel.stringValue = "Loading folder contents"
        previewInfoLabel.stringValue = "Reading the folder directory..."
        previewMessageLabel.stringValue = ""
        previewMessageLabel.isHidden = true
        hidePreviewSurfaces()
        previewImageView.renderMode = .centeredIcon
        previewImageView.isHidden = false
        previewImageView.image = icon
        previewSpinner.startAnimation(nil)
    }

    func showFolderError(for url: URL, error: Error) {
        applySingleFileLayout(false)
        let icon = headerIcon(for: url)
        rootItems = []
        previewRootURL = url
        iconImageView.image = icon
        titleLabel.stringValue = url.lastPathComponent
        infoLabel.stringValue = "Folder preview failed"
        outlineView.reloadData()
        updateOutlineScrollMetrics(resetPosition: false)
        previewTitleLabel.stringValue = "Could not preview folder"
        previewInfoLabel.stringValue = error.localizedDescription
        previewMessageLabel.stringValue = ""
        previewMessageLabel.isHidden = true
        hidePreviewSurfaces()
        previewImageView.renderMode = .centeredIcon
        previewImageView.isHidden = false
        previewSpinner.stopAnimation(nil)
        previewImageView.image = icon
    }

    // MARK: - 压缩包预览

    func prepareArchivePreview(at url: URL, provider: ArchiveProvider, resourceValues: URLResourceValues, completionHandler handler: @escaping (Error?) -> Void) {
        let requestID = UUID()
        let fileSize = Int64(resourceValues.fileSize ?? 0)

        DispatchQueue.main.async {
            self.contentLoadRequestID = requestID
            DebugLogger.shared.log("Completing Quick Look request early for archive \(url.lastPathComponent)")
            // Quick Look 要求扩展尽快完成 setup；压缩包扫描可能较慢，
            // 因此先返回加载界面，再异步填充完整目录树。
            handler(nil)
            self.showArchiveLoading(for: url, fileSize: fileSize)
            self.scheduleContentLoadTimeout(
                requestID: requestID,
                message: "Archive listing is still running. The list will appear here if macOS finishes reading this archive."
            )

            DispatchQueue.global(qos: .userInitiated).async {
                self.loadArchiveContents(
                    at: url,
                    provider: provider,
                    fileSize: fileSize,
                    requestID: requestID
                )
            }
        }
    }

    func showArchiveLoading(for url: URL, fileSize: Int64) {
        applySingleFileLayout(false)
        previewTimeoutWorkItem?.cancel()
        previewTimeoutWorkItem = nil
        contentLoadTimeoutWorkItem?.cancel()
        contentLoadTimeoutWorkItem = nil
        activeInlinePreviewRequestID = nil

        let icon = headerIcon(for: url)
        rootItems = []
        previewRootURL = url
        iconImageView.image = icon
        titleLabel.stringValue = url.lastPathComponent
        infoLabel.stringValue = "\(byteFormatter.string(fromByteCount: fileSize)) · reading archive contents"
        outlineView.reloadData()
        updateOutlineScrollMetrics(resetPosition: false)

        previewTitleLabel.stringValue = "Loading archive contents"
        previewInfoLabel.stringValue = "Reading the archive directory..."
        previewMessageLabel.stringValue = ""
        previewMessageLabel.isHidden = true
        hidePreviewSurfaces()
        previewImageView.renderMode = .centeredIcon
        previewImageView.isHidden = false
        previewImageView.image = icon
        previewSpinner.startAnimation(nil)
    }

    func loadArchiveContents(at url: URL, provider: ArchiveProvider, fileSize: Int64, requestID: UUID) {
        do {
            let start = CFAbsoluteTimeGetCurrent()
            let listing = try provider.listContents(of: url)
            let rootItems = makeArchiveRootItems(from: listing)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let counts = countItems(in: rootItems)
            let totalSize = listing.entries.reduce(Int64(0)) { partial, entry in
                partial + (entry.isDirectory ? 0 : (entry.size ?? 0))
            }
            var infoSegments = [
                listing.formatDescription,
                "\(counts.folders) folders, \(counts.files) files",
                ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
            ]
            if listing.warning != nil {
                infoSegments.append("partial listing")
            }
            let infoText = infoSegments.joined(separator: " · ")

            DispatchQueue.main.async {
                guard self.contentLoadRequestID == requestID else { return }
                self.contentLoadTimeoutWorkItem?.cancel()
                self.contentLoadTimeoutWorkItem = nil
                self.previewSpinner.stopAnimation(nil)

                let icon = self.headerIcon(for: url)
                DebugLogger.shared.log("Applying archive preview for \(url.lastPathComponent) with \(listing.entries.count) entries in \(String(format: "%.1f", elapsed)) ms")
                self.rootItems = rootItems
                self.previewRootURL = url
                self.iconImageView.image = icon
                self.titleLabel.stringValue = url.lastPathComponent
                self.infoLabel.stringValue = infoText
                self.outlineView.reloadData()
                self.updateOutlineScrollMetrics(resetPosition: true)
                self.syncPreviewWithSelection()
                if let warning = listing.warning {
                    self.previewTitleLabel.stringValue = "Archive listing warning"
                    self.previewInfoLabel.stringValue = warning
                    self.previewMessageLabel.stringValue = "Some entries may not be shown."
                    self.previewMessageLabel.isHidden = false
                } else if self.rootItems.isEmpty {
                    self.previewTitleLabel.stringValue = "Archive is empty"
                    self.previewInfoLabel.stringValue = "No entries were found."
                    self.previewMessageLabel.stringValue = ""
                    self.previewMessageLabel.isHidden = true
                }
            }
        } catch {
            DebugLogger.shared.log("Failed to list archive \(url.lastPathComponent): \(error.localizedDescription)")
            DispatchQueue.main.async {
                guard self.contentLoadRequestID == requestID else { return }
                self.contentLoadTimeoutWorkItem?.cancel()
                self.contentLoadTimeoutWorkItem = nil
                self.showArchiveError(for: url, error: error, fileSize: fileSize)
            }
        }
    }

    func scheduleContentLoadTimeout(requestID: UUID, message: String) {
        contentLoadTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.contentLoadRequestID == requestID else { return }
            self.contentLoadTimeoutWorkItem = nil
            self.previewSpinner.stopAnimation(nil)
            self.previewTitleLabel.stringValue = "Archive listing is taking longer than expected"
            self.previewInfoLabel.stringValue = message
            self.previewMessageLabel.stringValue = "You can still keep the preview open; it will refresh if parsing completes."
            self.previewMessageLabel.isHidden = false
        }
        contentLoadTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
    }

    func showArchiveError(for url: URL, error: Error, fileSize: Int64) {
        applySingleFileLayout(false)
        let icon = headerIcon(for: url)
        rootItems = []
        previewRootURL = url
        iconImageView.image = icon
        titleLabel.stringValue = url.lastPathComponent
        infoLabel.stringValue = "\(byteFormatter.string(fromByteCount: fileSize)) · archive preview failed"
        outlineView.reloadData()
        updateOutlineScrollMetrics(resetPosition: false)
        previewTitleLabel.stringValue = "Could not preview archive"
        previewInfoLabel.stringValue = error.localizedDescription
        previewMessageLabel.stringValue = "The archive may be damaged, encrypted, or use an unsupported variant."
        previewMessageLabel.isHidden = false
        hidePreviewSurfaces()
        previewImageView.renderMode = .centeredIcon
        previewImageView.isHidden = false
        previewSpinner.stopAnimation(nil)
        previewImageView.image = icon
    }

    // MARK: - 压缩包树构建

    final class ArchiveTreeNode {
        let name: String
        let path: String
        var isDirectory: Bool
        var entry: ArchiveEntry?
        var children: [String: ArchiveTreeNode] = [:]

        init(name: String, path: String, isDirectory: Bool, entry: ArchiveEntry? = nil) {
            self.name = name
            self.path = path
            self.isDirectory = isDirectory
            self.entry = entry
        }
    }

    func makeArchiveRootItems(from listing: ArchiveListing) -> [FileItem] {
        let root = ArchiveTreeNode(name: "", path: "", isDirectory: true)
        for entry in listing.entries {
            let cleanPath = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = cleanPath.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            // 部分压缩格式不会显式记录目录项，这里根据路径补齐父目录节点。
            var node = root
            var pathComponents: [String] = []
            for (index, component) in components.enumerated() {
                pathComponents.append(component)
                let path = pathComponents.joined(separator: "/")
                let isLeaf = index == components.count - 1
                let shouldBeDirectory = !isLeaf || entry.isDirectory
                let child = node.children[component] ?? ArchiveTreeNode(name: component, path: path, isDirectory: shouldBeDirectory)
                child.isDirectory = child.isDirectory || shouldBeDirectory
                if isLeaf {
                    child.entry = entry
                }
                node.children[component] = child
                node = child
            }
        }

        var items = root.children.values.map { makeFileItem(from: $0, archiveURL: listing.archiveURL) }
        sortFileItems(&items)
        return items
    }

    func makeFileItem(from node: ArchiveTreeNode, archiveURL: URL) -> FileItem {
        let hasChildren = !node.children.isEmpty
        let isFolder = node.isDirectory || hasChildren
        let entry = node.entry
        let item = FileItem(
            archiveURL: archiveURL,
            entryPath: node.path,
            name: node.name,
            isFolder: isFolder,
            size: isFolder ? 0 : (entry?.size ?? 0),
            modificationDate: entry?.modificationDate,
            kindDescription: entry?.kindDescription ?? (isFolder ? "Folder" : "File"),
            isEncrypted: entry?.isEncrypted ?? false
        )

        if isFolder {
            var children = node.children.values.map { makeFileItem(from: $0, archiveURL: archiveURL) }
            sortFileItems(&children)
            item.setChildren(children)
        }

        return item
    }

    func countItems(in items: [FileItem]) -> (folders: Int, files: Int) {
        var folders = 0
        var files = 0
        for item in items {
            if item.isFolder {
                folders += 1
                let childCounts = countItems(in: item.children ?? [])
                folders += childCounts.folders
                files += childCounts.files
            } else {
                files += 1
            }
        }
        return (folders, files)
    }

    // MARK: - 单文件预览

    func prepareSingleFilePreview(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        DebugLogger.shared.log("Detected single file: \(url.lastPathComponent)")
        let isMarkdown = isMarkdownFile(url: url, contentType: UTType(filenameExtension: url.pathExtension))

        DispatchQueue.main.async {
            handler(nil)
            if isMarkdown {
                self.showSingleFileMarkdownPreview(url: url)
            } else {
                self.showSingleFileTextPreview(url: url)
            }
        }
    }

    // MARK: - 选中与预览同步

    func schedulePreviewWithCurrentSelection(after delay: TimeInterval) {
        let t0 = CFAbsoluteTimeGetCurrent()
        selectionPreviewWorkItem?.cancel()
        selectionPreviewWorkItem = nil
        previewUpdateWorkItem?.cancel()

        let item = selectedItems.last
        let selectedItemID = item.map(ObjectIdentifier.init)
        // 元信息立即更新；真正的解码、渲染和系统预览延迟执行，
        // 给 AppKit 一帧时间先画出选中高亮。
        beginPreviewSelection(for: item)
        let requestID = previewRequestID
        DebugLogger.shared.log(String(format: "[PERF] beginPreviewSelection immediate %.1fms for %@",
                                      (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                                      item?.name ?? "nil"))

        let workItem = DispatchWorkItem { [weak self, weak item] in
            guard let self else { return }
            let currentItemID = self.selectedItems.last.map(ObjectIdentifier.init)
            // 延迟期间如果用户又选了别的文件，旧任务必须退出，
            // 防止右侧显示已经过期的预览内容。
            guard currentItemID == selectedItemID,
                  self.previewRequestID == requestID,
                  self.previewedItem === item else {
                DebugLogger.shared.log(String(format: "[PERF] schedulePreview SKIP: item changed during %.1fms delay", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
                return
            }

            self.selectionPreviewWorkItem = nil
            let t1 = CFAbsoluteTimeGetCurrent()
            DebugLogger.shared.log(String(format: "[PERF] schedulePreview fired after %.1fms, starting preview content", (t1 - t0) * 1000))
            self.startPreviewContent(for: item, requestID: requestID)
            DebugLogger.shared.log(String(format: "[PERF] startPreviewContent done in %.1fms for %@", (CFAbsoluteTimeGetCurrent() - t1) * 1000, item?.name ?? "nil"))
        }
        selectionPreviewWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0), execute: workItem)
    }

    func syncPreviewWithSelection() {
        schedulePreviewWithCurrentSelection(after: 0)
    }

    func beginPreviewSelection(for item: FileItem?) {
        previewImageLoadTask?.cancel()
        previewImageLoadTask = nil
        archivePreviewLoadTask?.cancel()
        archivePreviewLoadTask = nil
        previewTimeoutWorkItem?.cancel()
        previewTimeoutWorkItem = nil
        activeInlinePreviewRequestID = nil
        previewRequestID = UUID()
        previewSpinner.stopAnimation(nil)

        previewedItem = item

        guard let item else {
            hidePreviewSurfaces()
            previewImageView.image = nil
            previewTitleLabel.stringValue = "No Selection"
            previewInfoLabel.stringValue = "Select a file or folder to preview."
            previewMessageLabel.stringValue = ""
            previewMessageLabel.isHidden = true
            return
        }

        previewTitleLabel.stringValue = item.name
        previewInfoLabel.stringValue = item.previewInfo(sizeFormatter: byteFormatter, dateFormatter: dateFormatter)
        previewMessageLabel.isHidden = true
    }

    func startPreviewContent(for item: FileItem?, requestID: UUID) {
        guard requestID == previewRequestID, let item, previewedItem === item else {
            let msg = "startPreviewContent SKIP: rID=\(requestID) prID=\(previewRequestID) item=\(item?.name ?? "nil")"
            DebugLogger.shared.log(msg)
            return
        }

        let msg = "startPreviewContent for \(item.name) isArchive=\(item.isArchiveEntry) isFolder=\(item.isFolder) ct=\(item.contentType?.identifier ?? "nil")"
        DebugLogger.shared.log(msg)

        if item.isArchiveEntry {
            loadArchiveEntryPreview(for: item, requestID: requestID)
            return
        }

        if item.isFolder {
            showFallbackIcon(for: item, message: "Folder contents are shown in the list.")
            return
        }

        // 在文件夹列表中选中压缩包时，只显示压缩包图标和元信息；
        // 只有直接 Quick Look 打开压缩包本身时，才展示压缩包内容树。
        if ArchiveProviderRegistry.shared.provider(for: item.url, contentType: item.contentType) != nil {
            DebugLogger.shared.log("startPreviewContent: showing archive icon only for nested archive \(item.name)")
            showFallbackIcon(for: item, message: "")
            return
        }

        DebugLogger.shared.log("startPreviewContent: showing native preview for \(item.name)")
        showNativePreview(url: item.url, title: item.name, contentType: item.contentType, requestID: requestID)
    }

    func loadNestedArchivePreview(provider: ArchiveProvider, from item: FileItem, requestID: UUID) {
        DebugLogger.shared.log("loadNestedArchivePreview for \(item.url.lastPathComponent)")
        activeInlinePreviewRequestID = requestID
        prepareLoadingPreview(for: item, message: "Reading archive contents...")
        schedulePreviewTimeout(
            for: item,
            requestID: requestID,
            seconds: 4,
            message: "Archive listing is taking longer than expected."
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                let listing = try provider.listContents(of: item.url)
                DebugLogger.shared.log("Nested archive listed: \(listing.formatDescription), \(listing.entries.count) entries")
                let archiveItems = self.makeArchiveRootItems(from: listing)
                let counts = self.countItems(in: archiveItems)
                let totalSize = listing.entries.reduce(Int64(0)) { $0 + ($1.isDirectory ? 0 : ($1.size ?? 0)) }
                let info = "\(listing.formatDescription) · \(counts.folders) folders, \(counts.files) files · \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))"
                let listingText = self.makeArchiveListingText(from: listing)

                DispatchQueue.main.async {
                    guard self.previewRequestID == requestID,
                          self.previewedItem === item,
                          self.activeInlinePreviewRequestID == requestID else { return }
                    self.previewTimeoutWorkItem?.cancel()
                    self.previewTimeoutWorkItem = nil
                    self.activeInlinePreviewRequestID = nil
                    self.previewSpinner.stopAnimation(nil)
                    self.previewTitleLabel.stringValue = item.name
                    self.previewInfoLabel.stringValue = info
                    self.hidePreviewSurfaces()
                    self.textScrollView.isHidden = false
                    MarkdownRenderer.setTextPreview(listingText, in: self.textView, markdown: false, fontSize: 12)
                    if let warning = listing.warning {
                        self.previewMessageLabel.stringValue = warning
                        self.previewMessageLabel.isHidden = false
                    } else {
                        self.previewMessageLabel.stringValue = "Archive contents are listed here; the folder list on the left is unchanged."
                        self.previewMessageLabel.isHidden = false
                    }
                }
            } catch {
                DebugLogger.shared.log("Nested archive FAILED for \(item.url.lastPathComponent): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    guard self.previewRequestID == requestID,
                          self.previewedItem === item,
                          self.activeInlinePreviewRequestID == requestID else { return }
                    self.previewTimeoutWorkItem?.cancel()
                    self.previewTimeoutWorkItem = nil
                    self.activeInlinePreviewRequestID = nil
                    self.previewSpinner.stopAnimation(nil)
                    self.showNativePreview(url: item.url, title: item.name,
                        contentType: item.contentType, requestID: requestID)
                }
            }
        }
        archivePreviewLoadTask = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    func makeArchiveListingText(from listing: ArchiveListing) -> String {
        guard !listing.entries.isEmpty else {
            return "No entries were found."
        }

        return listing.entries.map { entry in
            let displayPath = entry.isDirectory && !entry.path.hasSuffix("/")
                ? "\(entry.path)/"
                : entry.path
            let sizeText = entry.isDirectory
                ? ""
                : "  \(ByteCountFormatter.string(fromByteCount: entry.size ?? 0, countStyle: .file))"
            return "\(displayPath)\(sizeText)"
        }.joined(separator: "\n")
    }

    // MARK: - 原生预览路由

    func showNativePreview(url: URL, title: String, contentType: UTType? = nil, requestID: UUID) {
        guard requestID == previewRequestID else { return }
        let type = contentType ?? UTType(filenameExtension: url.pathExtension)

        // Markdown、DOCX、图片、PDF、音视频等格式有自定义路径；
        // 其他支持格式再交给嵌入式 QLPreviewView 或缩略图兜底。
        if isMarkdownFile(url: url, contentType: type), let item = previewedItem {
            showMarkdownPreview(url: url, item: item, requestID: requestID)
            return
        }

        if isDOCXFile(url: url, contentType: type) {
            showDOCXPreview(url: url, requestID: requestID)
            return
        }

        if type?.conforms(to: .image) == true {
            loadPreviewImage(at: url, item: previewedItem, requestID: requestID)
            return
        }

        if type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            showPDFPreview(url: url, requestID: requestID)
            return
        }

        if shouldUseMediaPlayerPreview(url: url, contentType: type) {
            showMediaPreview(url: url, title: title, requestID: requestID)
            return
        }

        if shouldRenderAsText(url: url, contentType: type) {
            showTextPreview(url: url, requestID: requestID)
            return
        }

        if shouldUseEmbeddedNativePreview(url: url, contentType: type) {
            showEmbeddedQuickLookPreview(url: url, title: title, requestID: requestID)
            return
        }

        showQuickLookThumbnailPreview(url: url, title: title, requestID: requestID)
    }

    // MARK: - PDF 预览

    func showPDFPreview(url: URL, requestID: UUID) {
        guard requestID == previewRequestID, let item = previewedItem else { return }

        activeInlinePreviewRequestID = requestID
        prepareLoadingPreview(for: item, message: "Loading preview...")
        schedulePreviewTimeout(
            for: item,
            requestID: requestID,
            seconds: 2.5,
            message: "PDF preview took too long; showing file information instead."
        )

        let workItem = DispatchWorkItem { [weak self] in
            let documentResult = Result<PDFDocument, Error> {
                let data = try Self.readCoordinatedData(from: url)
                guard let document = PDFDocument(data: data) else {
                    throw NSError(
                        domain: "PeekX",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "PDF document could not be opened."]
                    )
                }
                return document
            }

            DispatchQueue.main.async {
                guard let self,
                      self.previewRequestID == requestID,
                      self.previewedItem === item,
                      self.activeInlinePreviewRequestID == requestID else { return }

                self.enqueuePreviewSurfaceUpdate(label: "PDF", requestID: requestID, item: item) { controller in
                    guard controller.activeInlinePreviewRequestID == requestID else { return }
                    controller.previewTimeoutWorkItem?.cancel()
                    controller.previewTimeoutWorkItem = nil
                    controller.activeInlinePreviewRequestID = nil
                    controller.previewSpinner.stopAnimation(nil)
                    controller.previewImageLoadTask = nil

                    switch documentResult {
                    case .success(let document):
                        controller.hidePreviewSurfaces()
                        let pdfView = controller.ensurePDFView()
                        pdfView.document = document
                        pdfView.autoScales = true
                        pdfView.goToFirstPage(nil)
                        pdfView.isHidden = false
                        controller.previewMessageLabel.isHidden = true
                        DebugLogger.shared.log("PDF preview loaded for \(item.name)")
                    case .failure(let error):
                        DebugLogger.shared.log("PDF preview failed for \(item.name): \(error.localizedDescription)")
                        controller.showEmbeddedQuickLookPreview(url: url, title: item.name, requestID: requestID)
                    }
                }
            }
        }
        previewImageLoadTask = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    // MARK: - 音视频预览

    func showMediaPreview(url: URL, title: String, requestID: UUID) {
        guard requestID == previewRequestID, let item = previewedItem else { return }

        activeInlinePreviewRequestID = requestID
        prepareLoadingPreview(for: item, message: "Loading media preview...")
        schedulePreviewTimeout(
            for: item,
            requestID: requestID,
            seconds: 4,
            message: "Media preview is taking longer than expected."
        )

        enqueuePreviewSurfaceUpdate(label: "Media", requestID: requestID, item: item) { controller in
            guard controller.activeInlinePreviewRequestID == requestID else { return }

            controller.previewTimeoutWorkItem?.cancel()
            controller.previewTimeoutWorkItem = nil
            controller.activeInlinePreviewRequestID = nil
            controller.previewSpinner.stopAnimation(nil)
            controller.hidePreviewSurfaces()

            let didAccess = url.startAccessingSecurityScopedResource()
            if didAccess {
                controller.activeMediaSecurityScopedURL = url
            }

            let playerView = controller.ensureMediaPlayerView()
            let player = AVPlayer(url: url)
            controller.mediaPlayer = player
            playerView.player = player
            playerView.isHidden = false
            controller.previewMessageLabel.isHidden = true
            DebugLogger.shared.log("Media preview loaded directly for \(title)")
        }
    }

    // MARK: - 文本预览

    func showTextPreview(url: URL, requestID: UUID) {
        guard requestID == previewRequestID, let item = previewedItem else { return }

        activeInlinePreviewRequestID = requestID
        prepareLoadingPreview(for: item, message: "Loading preview...")
        schedulePreviewTimeout(
            for: item,
            requestID: requestID,
            seconds: 2,
            message: "Text preview is taking longer than expected."
        )

        let workItem = DispatchWorkItem { [weak self] in
            let maxPreviewBytes = 2 * 1024 * 1024

            do {
                let result = try Self.readTextPreview(from: url, maxBytes: maxPreviewBytes)

                DispatchQueue.main.async {
                    guard let self,
                          self.previewRequestID == requestID,
                          self.previewedItem === item,
                          self.activeInlinePreviewRequestID == requestID else { return }

                    guard let text = result.text else {
                        self.enqueuePreviewSurfaceUpdate(label: "Text thumbnail fallback", requestID: requestID, item: item) { controller in
                            guard controller.activeInlinePreviewRequestID == requestID else { return }
                            controller.previewTimeoutWorkItem?.cancel()
                            controller.previewTimeoutWorkItem = nil
                            controller.showQuickLookThumbnailPreview(url: url, title: url.lastPathComponent, requestID: requestID)
                        }
                        return
                    }

                    self.enqueuePreviewSurfaceUpdate(label: "Text", requestID: requestID, item: item) { controller in
                        guard controller.activeInlinePreviewRequestID == requestID else { return }
                        controller.previewTimeoutWorkItem?.cancel()
                        controller.previewTimeoutWorkItem = nil
                        controller.activeInlinePreviewRequestID = nil
                        controller.previewSpinner.stopAnimation(nil)
                        controller.hidePreviewSurfaces()
                        controller.textScrollView.isHidden = false
                        MarkdownRenderer.setTextPreview(text, in: controller.textView, markdown: false, fontSize: 12)
                        controller.previewMessageLabel.stringValue = result.isTruncated ? "Text preview truncated to keep switching responsive." : ""
                        controller.previewMessageLabel.isHidden = !result.isTruncated
                        controller.previewImageLoadTask = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self,
                          self.previewRequestID == requestID,
                          self.previewedItem === item,
                          self.activeInlinePreviewRequestID == requestID else { return }
                    self.enqueuePreviewSurfaceUpdate(label: "Text fallback", requestID: requestID, item: item) { controller in
                        guard controller.activeInlinePreviewRequestID == requestID else { return }
                        controller.previewTimeoutWorkItem?.cancel()
                        controller.previewTimeoutWorkItem = nil
                        controller.showQuickLookThumbnailPreview(url: url, title: url.lastPathComponent, requestID: requestID)
                    }
                }
            }
        }
        previewImageLoadTask = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    static func readTextPreview(from url: URL, maxBytes: Int) throws -> (text: String?, isTruncated: Bool) {
        let data = try coordinatedRead(from: url) { readableURL in
            let handle = try FileHandle(forReadingFrom: readableURL)
            defer { try? handle.close() }
            return try handle.read(upToCount: maxBytes + 1) ?? Data()
        }

        let isTruncated = data.count > maxBytes
        let previewData = data.prefix(maxBytes)
        let text = String(data: previewData, encoding: .utf8)
            ?? String(data: previewData, encoding: .utf16)
            ?? String(data: previewData, encoding: .utf16LittleEndian)
            ?? String(data: previewData, encoding: .utf16BigEndian)
            ?? String(data: previewData, encoding: .isoLatin1)
            ?? String(data: previewData, encoding: .ascii)

        return (text, isTruncated)
    }

    static func readCoordinatedData(from url: URL) throws -> Data {
        try coordinatedRead(from: url) { readableURL in
            try Data(contentsOf: readableURL, options: [.mappedIfSafe])
        }
    }

    static func coordinatedRead<T>(from url: URL, operation: @escaping (URL) throws -> T) throws -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // iCloud 文件可能只是占位符；读取前先请求系统开始下载。
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        var lastError: Error?
        for attempt in 0..<8 {
            var coordinatedError: NSError?
            var result: Result<T, Error>?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatedError) { readableURL in
                result = Result {
                    try operation(readableURL)
                }
            }

            if let result {
                do {
                    return try result.get()
                } catch {
                    lastError = error
                }
            } else if let coordinatedError {
                lastError = coordinatedError
            }

            if attempt < 7 {
                // 文件协调在 iCloud 下载或其他进程写入时可能短暂失败。
                // 这里运行在后台队列，重试不会卡住主线程。
                Thread.sleep(forTimeInterval: 0.35)
            }
        }

        throw lastError ?? NSError(
            domain: "PeekX",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not coordinate file reading."]
        )
    }

    func makeReadablePreviewCopy(of url: URL) throws -> URL {
        let ext = url.pathExtension
        let filename = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let destinationURL = extractedPreviewDirectory.appendingPathComponent(filename, isDirectory: false)
        try Self.coordinatedRead(from: url) { readableURL in
            try FileManager.default.copyItem(at: readableURL, to: destinationURL)
        }
        return destinationURL
    }

    // MARK: - DOCX 预览

    func showDOCXPreview(url: URL, requestID: UUID) {
        guard requestID == previewRequestID, let item = previewedItem else { return }

        activeInlinePreviewRequestID = requestID
        prepareLoadingPreview(for: item, message: "Loading DOCX preview...")
        schedulePreviewTimeout(
            for: item,
            requestID: requestID,
            seconds: 3,
            message: "DOCX preview is taking longer than expected."
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PeekXDocxPreviews", isDirectory: true)
            let documentXMLURL = tempDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("xml")

            do {
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: documentXMLURL) }

                // DOCX 本质是 ZIP 容器；这里只解出 word/document.xml 并提取文本。
                // 版式、图片和复杂对象交给系统预览兜底。
                let readableURL = try self.makeReadablePreviewCopy(of: url)
                try LibarchiveArchiveProvider().extractEntry("word/document.xml", from: readableURL, to: documentXMLURL)
                let data = try Data(contentsOf: documentXMLURL)
                let text = try DOCXTextExtractor().extractText(from: data)

                DispatchQueue.main.async {
                    guard self.previewRequestID == requestID,
                          self.previewedItem === item,
                          self.activeInlinePreviewRequestID == requestID else { return }

                    self.enqueuePreviewSurfaceUpdate(label: "DOCX", requestID: requestID, item: item) { controller in
                        guard controller.activeInlinePreviewRequestID == requestID else { return }
                        controller.previewTimeoutWorkItem?.cancel()
                        controller.previewTimeoutWorkItem = nil
                        controller.activeInlinePreviewRequestID = nil
                        controller.previewSpinner.stopAnimation(nil)
                        controller.hidePreviewSurfaces()
                        controller.textScrollView.isHidden = false
                        MarkdownRenderer.setTextPreview(text.isEmpty ? "No text content found in this document." : text, in: controller.textView, markdown: false, fontSize: 12)
                        controller.previewMessageLabel.isHidden = true
                        controller.previewImageLoadTask = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.previewRequestID == requestID,
                          self.previewedItem === item,
                          self.activeInlinePreviewRequestID == requestID else { return }

                    self.enqueuePreviewSurfaceUpdate(label: "DOCX fallback", requestID: requestID, item: item) { controller in
                        guard controller.activeInlinePreviewRequestID == requestID else { return }
                        controller.previewTimeoutWorkItem?.cancel()
                        controller.previewTimeoutWorkItem = nil
                        controller.activeInlinePreviewRequestID = nil
                        controller.previewSpinner.stopAnimation(nil)
                        DebugLogger.shared.log("DOCX preview failed for \(item.name): \(error.localizedDescription)")
                        controller.showEmbeddedQuickLookPreview(url: url, title: item.name, requestID: requestID)
                    }
                }
            }
        }
        previewImageLoadTask = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    // MARK: - 嵌入式系统预览与缩略图

    func showEmbeddedQuickLookPreview(url: URL, title: String, requestID: UUID) {
        guard requestID == previewRequestID, let item = previewedItem else { return }

        activeInlinePreviewRequestID = requestID
        prepareLoadingPreview(for: item, message: "Loading preview...")

        enqueuePreviewSurfaceUpdate(label: "Embedded Quick Look", requestID: requestID, item: item) { controller in
            guard controller.activeInlinePreviewRequestID == requestID else { return }
            let previewItem = URLPreviewItem(url: url, title: title)
            controller.activeNativePreviewItem = previewItem
            guard let previewView = controller.ensureNativePreviewView() else {
                controller.showQuickLookThumbnailPreview(url: url, title: title, requestID: requestID)
                return
            }
            DebugLogger.shared.log("Embedded native preview requested for \(title)")
            controller.hidePreviewSurfaces(clearNativePreview: false)
            previewView.previewItem = previewItem
            previewView.isHidden = false
            previewView.refreshPreviewItem()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak controller, weak item] in
                guard let controller,
                      let item,
                      controller.previewRequestID == requestID,
                      controller.previewedItem === item,
                      controller.activeInlinePreviewRequestID == requestID else { return }
                controller.previewSpinner.stopAnimation(nil)
                controller.previewMessageLabel.isHidden = true
            }
        }
    }

    func showQuickLookThumbnailPreview(url: URL, title: String, requestID: UUID) {
        guard requestID == previewRequestID, let item = previewedItem else { return }

        activeInlinePreviewRequestID = requestID
        prepareLoadingPreview(for: item, message: "Loading preview...")
        schedulePreviewTimeout(
            for: item,
            requestID: requestID,
            seconds: 2.5,
            message: "Preview generation took too long; showing file information instead."
        )

        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let boundsSize = previewImageScrollView.contentView.bounds.size
        let size = CGSize(
            width: max(boundsSize.width, 480),
            height: max(boundsSize.height, 340)
        )
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: [.lowQualityThumbnail, .thumbnail]
        )

        let start = CFAbsoluteTimeGetCurrent()
        QLThumbnailGenerator.shared.generateRepresentations(for: request) { [weak self] representation, representationType, error in
            DispatchQueue.main.async {
                guard let self,
                      self.previewRequestID == requestID,
                      self.previewedItem === item,
                      self.activeInlinePreviewRequestID == requestID else { return }

                guard let image = representation?.nsImage else {
                    if let error {
                        DebugLogger.shared.log("Quick Look thumbnail failed for \(title): \(error.localizedDescription)")
                    }
                    self.showFallbackIcon(for: item, message: error?.localizedDescription ?? "Preview is unavailable for this file.")
                    return
                }

                self.enqueuePreviewSurfaceUpdate(label: "Quick Look thumbnail", requestID: requestID, item: item) { controller in
                    guard controller.activeInlinePreviewRequestID == requestID else { return }
                    controller.previewTimeoutWorkItem?.cancel()
                    controller.previewTimeoutWorkItem = nil
                    controller.previewSpinner.stopAnimation(nil)
                    controller.textScrollView.isHidden = true
                    controller.hidePreviewSurfaces()
                    controller.previewImageView.renderMode = .fit
                    controller.previewImageView.image = image
                    controller.previewImageView.isHidden = false
                    if representationType == .thumbnail {
                        controller.activeInlinePreviewRequestID = nil
                        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                        DebugLogger.shared.log("Quick Look thumbnail for \(title) finished in \(String(format: "%.1f", elapsed)) ms")
                        controller.previewMessageLabel.isHidden = true
                    } else {
                        controller.previewMessageLabel.stringValue = "Generating full preview..."
                        controller.previewMessageLabel.isHidden = false
                    }
                }
            }
        }
    }

    // MARK: - 超时与兜底

    func schedulePreviewTimeout(for item: FileItem, requestID: UUID, seconds: TimeInterval, message: String) {
        previewTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak item] in
            guard let self,
                  let item,
                  self.previewRequestID == requestID,
                  self.previewedItem === item,
                  self.activeInlinePreviewRequestID == requestID else { return }

            self.previewTimeoutWorkItem = nil
            self.previewSpinner.stopAnimation(nil)
            self.showFallbackIcon(for: item, message: message, preservingActiveRequest: true)
        }
        previewTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    // MARK: - 文件类型判断

    func shouldRenderAsText(url: URL, contentType: UTType?) -> Bool {
        let ext = url.pathExtension.lowercased()
        if isMarkdownFile(url: url, contentType: contentType) {
            return false
        }
        let textExtensions: Set<String> = [
            "bash", "c", "cc", "cfg", "conf", "cpp", "cs", "css", "csv", "env", "go",
            "h", "hpp", "htm", "html", "ini", "java", "js", "json", "jsx", "kt", "log",
            "lua", "m", "mm", "php", "pl", "plist", "properties", "py", "rb", "rs",
            "rtf", "sh", "sql", "swift", "text", "toml", "ts", "tsx", "txt", "xml",
            "yaml", "yml", "zsh"
        ]
        if textExtensions.contains(ext) {
            return true
        }
        return contentType?.conforms(to: .text) == true
            || contentType?.conforms(to: .sourceCode) == true
            || contentType?.conforms(to: .json) == true
            || contentType?.conforms(to: .xml) == true
    }

    func isMarkdownFile(url: URL, contentType: UTType?) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md"
            || ext == "markdown"
            || contentType == UTType(filenameExtension: "md")
            || contentType?.identifier == "net.daringfireball.markdown"
    }

    func isDOCXFile(url: URL, contentType: UTType?) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "docx"
            || contentType?.identifier == "org.openxmlformats.wordprocessingml.document"
    }

    func shouldUseMediaPlayerPreview(url: URL, contentType: UTType?) -> Bool {
        let ext = url.pathExtension.lowercased()
        let mediaExtensions: Set<String> = [
            "aac", "aif", "aiff", "caf", "m4a", "m4v", "mov", "mp3", "mp4", "wav"
        ]
        if mediaExtensions.contains(ext) {
            return true
        }

        return contentType?.conforms(to: .audiovisualContent) == true
            || contentType?.conforms(to: .movie) == true
            || contentType?.conforms(to: .audio) == true
    }

    func shouldUseEmbeddedNativePreview(url: URL, contentType: UTType?) -> Bool {
        let ext = url.pathExtension.lowercased()
        let nativePreviewExtensions: Set<String> = [
            "doc", "key", "numbers", "pages", "ppt", "pptx", "xls", "xlsx"
        ]
        if nativePreviewExtensions.contains(ext) {
            return true
        }

        return contentType?.conforms(to: .presentation) == true
            || contentType?.conforms(to: .spreadsheet) == true
    }

    // MARK: - 压缩包成员预览

    func loadArchiveEntryPreview(for item: FileItem, requestID: UUID) {
        if item.isFolder {
            showFallbackIcon(for: item, message: "Archive folder contents are shown in the list.")
            return
        }

        guard shouldAttemptNativePreview(for: item) else {
            showFallbackIcon(for: item, message: "This archive entry is listed only; macOS does not provide a useful inline preview for this file type.")
            return
        }

        if let cachedURL = extractedPreviewCache[item.copyPath],
           FileManager.default.fileExists(atPath: cachedURL.path) {
            // 复用已解出的临时文件，避免重复读取同一个压缩包成员。
            showNativePreview(url: cachedURL, title: item.name, contentType: item.contentType, requestID: requestID)
            return
        }

        guard let archiveURL = item.archiveURL,
              let entryPath = item.archiveEntryPath,
              let provider = ArchiveProviderRegistry.shared.provider(for: archiveURL, contentType: nil) else {
            showFallbackIcon(for: item, message: "Archive entry contents could not be prepared for preview.")
            return
        }

        activeInlinePreviewRequestID = requestID
        prepareLoadingPreview(for: item, message: "Preparing preview...")
        schedulePreviewTimeout(
            for: item,
            requestID: requestID,
            seconds: 3,
            message: "Preparing this archive entry took too long; showing file information instead."
        )

        let destinationURL = makeExtractedPreviewURL(for: item)
        let cacheKey = item.copyPath
        let workItem = DispatchWorkItem { [weak self] in
            do {
                try provider.extractEntry(entryPath, from: archiveURL, to: destinationURL)
                DispatchQueue.main.async {
                    guard let self,
                          self.previewRequestID == requestID,
                          self.previewedItem === item,
                          self.activeInlinePreviewRequestID == requestID else { return }
                    self.extractedPreviewCache[cacheKey] = destinationURL
                    self.showNativePreview(url: destinationURL, title: item.name, contentType: item.contentType, requestID: requestID)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self,
                          self.previewRequestID == requestID,
                          self.previewedItem === item,
                          self.activeInlinePreviewRequestID == requestID else { return }
                    self.previewTimeoutWorkItem?.cancel()
                    self.previewTimeoutWorkItem = nil
                    self.activeInlinePreviewRequestID = nil
                    self.showFallbackIcon(for: item, message: error.localizedDescription)
                }
            }
        }
        archivePreviewLoadTask = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    func showFallbackIcon(for item: FileItem, message: String, preservingActiveRequest: Bool = false) {
        previewTimeoutWorkItem?.cancel()
        previewTimeoutWorkItem = nil
        if !preservingActiveRequest {
            activeInlinePreviewRequestID = nil
            activeNativePreviewItem = nil
            nativePreviewView?.previewItem = nil
        }
        previewSpinner.stopAnimation(nil)
        stopActiveMediaPreview()
        nativePreviewView?.isHidden = true
        pdfView?.document = nil
        pdfView?.isHidden = true
        mediaPlayerView?.isHidden = true
        textScrollView.isHidden = true
        previewImageView.renderMode = .centeredIcon
        previewImageView.isHidden = false
        previewMessageLabel.stringValue = message
        previewMessageLabel.isHidden = message.isEmpty
        loadLargeIcon(for: item) { [weak self] icon in
            guard let self, self.previewedItem === item else { return }
            self.previewImageView.renderMode = .centeredIcon
            self.previewImageView.image = icon
        }
    }

    func shouldAttemptNativePreview(for item: FileItem) -> Bool {
        guard !item.isEncryptedArchiveEntry else { return false }
        guard item.size <= 100 * 1024 * 1024 else { return false }

        let ext = (item.name as NSString).pathExtension.lowercased()
        let binaryLikeExtensions: Set<String> = [
            "a", "bin", "class", "com", "dll", "dylib", "exe", "lib", "o", "obj", "so"
        ]
        if binaryLikeExtensions.contains(ext) {
            return false
        }

        let commonPreviewExtensions: Set<String> = [
            "bmp", "c", "cpp", "css", "csv", "doc", "docx", "gif", "h", "heic", "heif",
            "htm", "html", "jpeg", "jpg", "js", "json", "key", "m", "md", "mov", "mp3",
            "mp4", "numbers", "pages", "pdf", "plist", "png", "ppt", "pptx", "py", "rtf",
            "swift", "text", "tif", "tiff", "txt", "wav", "webp", "xls", "xlsx", "xml"
        ]
        if commonPreviewExtensions.contains(ext) {
            return true
        }

        guard let type = item.contentType else { return false }
        let previewTypes: [UTType] = [
            .audiovisualContent,
            .compositeContent,
            .html,
            .image,
            .json,
            .pdf,
            .sourceCode,
            .text,
            .xml
        ]
        return previewTypes.contains { type.conforms(to: $0) }
    }

    func makeExtractedPreviewURL(for item: FileItem) -> URL {
        let ext = (item.name as NSString).pathExtension
        let filename = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        return extractedPreviewDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    // MARK: - 单文件全窗口预览

    func showSingleFileTextPreview(url: URL) {
        applySingleFileLayout(true)
        singleFileScrollView.isHidden = false
        singleFileTextView.string = ""

        DispatchQueue.global(qos: .userInitiated).async {
            let content = (try? Self.readTextPreview(from: url, maxBytes: 2 * 1024 * 1024))?.text ?? "Could not read file."
            DispatchQueue.main.async {
                self.applySingleFileLayout(true)
                self.singleFileScrollView.isHidden = false
                MarkdownRenderer.setTextPreview(content, in: self.singleFileTextView, markdown: false, fontSize: 14)
            }
        }
    }

    func showSingleFileMarkdownPreview(url: URL) {
        applySingleFileLayout(true)
        singleFileScrollView.isHidden = false
        singleFileTextView.string = ""
        MarkdownRenderer.setRenderedHTMLPreview(MarkdownRenderer.markdownLoadingHTML(), in: singleFileTextView)

        loadMarkdownHTML(from: url) { [weak self] result in
            guard let self else { return }
            self.applySingleFileLayout(true)
            self.singleFileScrollView.isHidden = false
            self.logMarkdownRenderResult(result, fileName: url.lastPathComponent)
            MarkdownRenderer.setRenderedHTMLPreview(result.html, in: self.singleFileTextView)
        }
    }

    // MARK: - Markdown 预览

    func showMarkdownPreview(url: URL, item: FileItem, requestID: UUID) {
        guard requestID == previewRequestID else { return }
        activeInlinePreviewRequestID = requestID
        prepareLoadingPreview(for: item, message: "Loading markdown preview...")

        loadMarkdownHTML(from: url) { [weak self] result in
            guard let self,
                  self.previewRequestID == requestID,
                  self.previewedItem === item,
                  self.activeInlinePreviewRequestID == requestID else { return }
            self.previewTimeoutWorkItem?.cancel()
            self.previewTimeoutWorkItem = nil
            self.logMarkdownRenderResult(result, fileName: item.name)

            // NSTextView 导入 HTML 可能占用主线程；短暂、可取消的延迟可以避免
            // 快速切换文件时被已经过期的 Markdown 渲染卡住。
            self.enqueuePreviewSurfaceUpdate(label: "Markdown HTML", requestID: requestID, item: item, delay: 0.08) { controller in
                guard controller.activeInlinePreviewRequestID == requestID else { return }
                controller.activeInlinePreviewRequestID = nil
                controller.previewSpinner.stopAnimation(nil)
                controller.hidePreviewSurfaces()
                controller.textScrollView.isHidden = false
                controller.previewMessageLabel.isHidden = true
                MarkdownRenderer.setRenderedHTMLPreview(result.html, in: controller.textView)
            }
        }
    }

    func loadMarkdownHTML(from url: URL, completion: @escaping (MarkdownRenderResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = (try? Self.readTextPreview(from: url, maxBytes: 2 * 1024 * 1024))?.text ?? ""
            let result = MarkdownRenderer.renderMarkdownDocument(text, sourceURL: url)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func logMarkdownRenderResult(_ result: MarkdownRenderResult, fileName: String) {
        if let reason = result.fallbackReason {
            DebugLogger.shared.log("Markdown renderer fallback for \(fileName): \(reason)")
        }
        DebugLogger.shared.log("Markdown rendered for \(fileName) using \(result.rendererName)")
    }

    // MARK: - 图片预览

    func loadPreviewImage(at url: URL, item: FileItem?, requestID: UUID) {
        guard let item else { return }
        activeInlinePreviewRequestID = requestID
        prepareLoadingPreview(for: item, message: "Loading image preview...")
        schedulePreviewTimeout(
            for: item,
            requestID: requestID,
            seconds: 3,
            message: "Image preview took too long; showing file information instead."
        )
        let previewBounds = previewContainerView.bounds.size
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let largestDisplayDimension = max(previewBounds.width, previewBounds.height, 800)
        // 按显示区域解码缩略图，不直接加载超大原图，减少切换图片时的延迟。
        let maxPixelSize = min(max(Int(largestDisplayDimension * scale * 1.5), 1200), 4096)
        let start = CFAbsoluteTimeGetCurrent()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let imageResult = Result {
                try Self.loadDecodedImage(from: url, maxPixelSize: maxPixelSize)
            }
            DispatchQueue.main.async {
                guard self.previewRequestID == requestID,
                      self.previewedItem === item,
                      self.activeInlinePreviewRequestID == requestID else { return }
                self.enqueuePreviewSurfaceUpdate(label: "Image", requestID: requestID, item: item) { controller in
                    guard controller.activeInlinePreviewRequestID == requestID else { return }
                    controller.previewTimeoutWorkItem?.cancel()
                    controller.previewTimeoutWorkItem = nil
                    controller.activeInlinePreviewRequestID = nil
                    controller.previewSpinner.stopAnimation(nil)
                    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    DebugLogger.shared.log("Preview image load for \(item.name) finished in \(String(format: "%.1f", elapsed)) ms")
                    switch imageResult {
                    case .success(let image):
                        controller.hidePreviewSurfaces()
                        controller.previewImageView.renderMode = .orientationFill
                        controller.previewImageView.image = image
                        controller.previewImageView.isHidden = false
                        controller.previewImageView.needsDisplay = true
                        controller.previewMessageLabel.isHidden = true
                    case .failure(let error):
                        DebugLogger.shared.log("Image decode failed for \(item.name): \(error.localizedDescription)")
                        controller.showEmbeddedQuickLookPreview(url: url, title: item.name, requestID: requestID)
                    }
                    controller.previewImageLoadTask = nil
                }
            }
        }
        previewImageLoadTask = task
        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }

    static func loadDecodedImage(from url: URL, maxPixelSize: Int) throws -> NSImage {
        try coordinatedRead(from: url) { readableURL in
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(readableURL as CFURL, sourceOptions) else {
                if let image = NSImage(contentsOf: readableURL) {
                    return image
                }
                throw NSError(
                    domain: "PeekX",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Image data could not be opened."]
                )
            }

            let imageOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, imageOptions) {
                let image = NSImage(cgImage: cgImage, size: .zero)
                image.size = NSSize(width: cgImage.width, height: cgImage.height)
                return image
            }

            if let image = NSImage(contentsOf: readableURL) {
                return image
            }

            throw NSError(
                domain: "PeekX",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Image data could not be decoded."]
            )
        }
    }

    // MARK: - 滚动尺寸

    func updateOutlineScrollMetrics(resetPosition: Bool = false) {
        let clipView = scrollView.contentView
        let rowExtent = outlineView.rowHeight + outlineView.intercellSpacing.height
        let headerHeight = outlineView.headerView?.frame.height ?? 0
        let contentHeight = max(CGFloat(max(outlineView.numberOfRows, 1)) * rowExtent + headerHeight, clipView.bounds.height + 1)
        let contentWidth = max(outlineView.tableColumns.reduce(CGFloat(0)) { $0 + $1.width }, clipView.bounds.width + 1)

        // NSOutlineView 放在普通 NSScrollView 里时不会总是自动扩展 document size；
        // 手动设置尺寸后，横向和纵向滚动条范围才准确。
        outlineView.setFrameSize(NSSize(width: contentWidth, height: contentHeight))
        if resetPosition {
            resetScrollViewToTopLeft(scrollView)
        } else {
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    func resetScrollViewToTopLeft(_ scrollView: NSScrollView) {
        scrollView.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        if scrollView.documentView?.isFlipped == true {
            clipView.scroll(to: NSPoint(x: 0, y: 0))
        } else {
            let docH = scrollView.documentView?.bounds.height ?? 0
            let clipH = clipView.bounds.height
            clipView.scroll(to: NSPoint(x: 0, y: max(docH - clipH, 0)))
        }
        scrollView.horizontalScroller?.floatValue = 0
        scrollView.verticalScroller?.floatValue = 0
        scrollView.reflectScrolledClipView(clipView)
    }
}
