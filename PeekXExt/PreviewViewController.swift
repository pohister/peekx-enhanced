// PeekX - Folder Preview Extension for macOS
// Copyright © 2025 ALTIC. All rights reserved.

import Cocoa
import Quartz
import UniformTypeIdentifiers
import QuickLook
import QuickLookThumbnailing
import ImageIO
import PDFKit
import AVKit
import QuartzCore

// MARK: - Debug Logger
final class DebugLogger {
    static let shared = DebugLogger()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.peekx.logger", qos: .utility)
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let maxSize: UInt64 = 256 * 1024 // 256 KB

    private init() {
        let sandboxTempLog = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PeekXExt.log")
        fileURL = sandboxTempLog
    }

    func log(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)\n"
        queue.async {
            if let data = entry.data(using: .utf8) {
                self.append(data)
            }
            NSLog("%@", message)
        }
    }

    func locationDescription() -> String { fileURL.path }

    private func append(_ data: Data) {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) == false {
                try data.write(to: fileURL, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            }
            pruneIfNeeded(fileURL)
        } catch {
            NSLog("PeekX logger error for %@: %@", fileURL.path, error.localizedDescription)
        }
    }

    private func pruneIfNeeded(_ fileURL: URL) {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? UInt64,
            size > maxSize
        else { return }

        if let data = try? Data(contentsOf: fileURL) {
            let trimmed = data.suffix(Int(maxSize / 2))
            try? trimmed.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Custom Outline View

/// Protocol for handling keyboard events in the outline view
protocol FinderOutlineViewKeyboardDelegate: AnyObject {
    func outlineView(_ outlineView: FinderOutlineView, handle event: NSEvent) -> Bool
}

/// Custom outline view that intercepts keyboard events for QuickLook-specific shortcuts
final class FinderOutlineView: NSOutlineView {
    weak var keyboardDelegate: FinderOutlineViewKeyboardDelegate?

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 {
            let shouldExtend = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: shouldExtend)
            window?.makeFirstResponder(self)
            needsDisplay = true
            if frameOfOutlineCell(atRow: row).contains(point) {
                super.mouseDown(with: event)
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = enclosingScrollView as? FinderScrollView,
           FinderScrollView.scrollHorizontallyIfNeeded(scrollView, with: event) {
            return
        }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyboardDelegate?.outlineView(self, handle: event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

final class FinderScroller: NSScroller {
    weak var ownerScrollView: NSScrollView?

    override func scrollWheel(with event: NSEvent) {
        guard bounds.width >= bounds.height,
              let ownerScrollView,
              FinderScrollView.scrollHorizontally(ownerScrollView, with: event) else {
            super.scrollWheel(with: event)
            return
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // alphaValue on the scroller view handles transparency;
        // just delegate to the system drawing.
        super.draw(dirtyRect)
    }
}

class FinderScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if Self.scrollHorizontallyIfNeeded(self, with: event) {
            return
        }

        super.scrollWheel(with: event)
    }

    func installTranslucentScrollers() {
        // Only adjust alpha — do NOT replace the scroller instances.
        // Replacing them discards NSScrollView's internal frame / layout
        // configuration and breaks hit-testing for horizontal-scroll redirection.
        verticalScroller?.alphaValue = 0.58
        horizontalScroller?.alphaValue = 0.58
    }

    static func scrollHorizontallyIfNeeded(_ scrollView: NSScrollView, with event: NSEvent) -> Bool {
        let point = scrollView.convert(event.locationInWindow, from: nil)
        // Hit test: accept the scroller's own frame, or any point in the
        // bottom 28 pt of the scroll view's content area (covers legacy
        // scroller track plus a generous margin for overlay-trackpad gaps).
        let isOverHorizontalScroller = scrollView.horizontalScroller?.frame.contains(point) == true
        let inBottomBand = point.y >= 0 && point.y <= scrollView.contentView.frame.minY + 28
        guard isOverHorizontalScroller || inBottomBand else {
            return false
        }

        return scrollHorizontally(scrollView, with: event)
    }

    static func scrollHorizontally(_ scrollView: NSScrollView, with event: NSEvent) -> Bool {
        let verticalDelta = event.scrollingDeltaY
        guard abs(verticalDelta) > abs(event.scrollingDeltaX) else {
            return false
        }

        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let current = scrollView.contentView.bounds.origin
        let maxX = max((scrollView.documentView?.bounds.width ?? 0) - scrollView.contentView.bounds.width, 0)
        guard maxX > 0 else { return false }
        let nextX = min(max(current.x - verticalDelta * multiplier, 0), maxX)
        scrollView.contentView.scroll(to: NSPoint(x: nextX, y: current.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
    }
}

final class ImagePreviewView: NSImageView {
    enum RenderMode {
        case centeredIcon
        case fit
        case orientationFill
    }

    var renderMode: RenderMode = .orientationFill {
        didSet { updateLayout(resetScroll: true) }
    }

    private var drawRect: NSRect = .zero

    override var image: NSImage? {
        didSet { updateLayout(resetScroll: true) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateLayout(resetScroll: false)
    }

    func updateLayout(resetScroll: Bool) {
        guard let scrollView = enclosingScrollView else {
            needsDisplay = true
            return
        }

        let viewportSize = scrollView.contentView.bounds.size
        guard let image, image.size.width > 0, image.size.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            drawRect = .zero
            setFrameSize(viewportSize)
            needsDisplay = true
            return
        }

        let imageSize = image.size
        let scale: CGFloat
        switch renderMode {
        case .centeredIcon:
            scale = min(1, min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height))
        case .fit:
            scale = min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
        case .orientationFill:
            scale = imageSize.height > imageSize.width
                ? viewportSize.height / imageSize.height
                : viewportSize.width / imageSize.width
        }

        let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let documentSize = NSSize(width: max(drawSize.width, viewportSize.width), height: max(drawSize.height, viewportSize.height))
        let previousCenter = NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)

        if frame.size != documentSize {
            setFrameSize(documentSize)
        }
        drawRect = NSRect(
            x: max((documentSize.width - drawSize.width) / 2, 0),
            y: max((documentSize.height - drawSize.height) / 2, 0),
            width: drawSize.width,
            height: drawSize.height
        )

        let nextOrigin: NSPoint
        if resetScroll {
            nextOrigin = NSPoint(
                x: max((documentSize.width - viewportSize.width) / 2, 0),
                y: max((documentSize.height - viewportSize.height) / 2, 0)
            )
        } else {
            nextOrigin = NSPoint(
                x: min(max(previousCenter.x - viewportSize.width / 2, 0), max(documentSize.width - viewportSize.width, 0)),
                y: min(max(previousCenter.y - viewportSize.height / 2, 0), max(documentSize.height - viewportSize.height, 0))
            )
        }
        scrollView.contentView.scroll(to: nextOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else {
            super.draw(dirtyRect)
            return
        }

        NSColor.clear.setFill()
        dirtyRect.fill()

        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, !drawRect.isEmpty else { return }
        image.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: imageSize),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

final class ImagePreviewScrollView: FinderScrollView {
    let imageView = ImagePreviewView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = false
        scrollerStyle = .legacy
        installTranslucentScrollers()
        borderType = .noBorder
        drawsBackground = false
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .allowed
        documentView = imageView
    }

    override func layout() {
        super.layout()
        imageView.updateLayout(resetScroll: false)
    }
}

private enum PreviewMetrics {
    static let cornerRadius: CGFloat = 12
    static let dividerContentGap: CGFloat = 28
}

// MARK: - File Item Model

/// Represents a file or folder in the preview hierarchy
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

    // Cached formatted strings to avoid repeated formatting
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

    // Lazy formatted size - computed once and cached
    func formattedSize(using formatter: ByteCountFormatter) -> String {
        if let cached = _formattedSize {
            return cached
        }
        let formatted = isFolder ? "—" : formatter.string(fromByteCount: size)
        _formattedSize = formatted
        return formatted
    }

    // Lazy formatted date - computed once and cached
    func formattedDate(using formatter: DateFormatter) -> String {
        if let cached = _formattedDate {
            return cached
        }
        let formatted = hasModificationDate ? formatter.string(from: modificationDate) : "Unknown date"
        _formattedDate = formatted
        return formatted
    }

    // Pre-build complete preview info string
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

private final class URLPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
        super.init()
    }
}

private enum DOCXPreviewError: LocalizedError {
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

private final class DOCXTextExtractor: NSObject, XMLParserDelegate {
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

// MARK: - Preview View Controller

/// Main view controller for the QuickLook folder preview extension
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController, NSSplitViewDelegate {

    // MARK: - UI Components

    private var mainStack: NSStackView!
    private var scrollView: FinderScrollView!
    private var splitView: NSSplitView!
    private var outlineView: FinderOutlineView!
    private var headerView: NSView!
    private var iconImageView: NSImageView!
    private var titleLabel: NSTextField!
    private var infoLabel: NSTextField!
    private var previewPane: NSView!
    private var previewContainerView: NSView!
    private var previewImageScrollView: ImagePreviewScrollView!
    private var previewImageView: ImagePreviewView!
    private var nativePreviewView: QLPreviewView?
    private var pdfView: PDFView?
    private var mediaPlayerView: AVPlayerView?
    private var mediaPlayer: AVPlayer?
    private var activeMediaSecurityScopedURL: URL?
    private var textScrollView: NSScrollView!
    private var textView: NSTextView!
    private var singleFileScrollView: NSScrollView!
    private var singleFileTextView: NSTextView!
    private var previewSpinner: NSProgressIndicator!
    private var previewTitleLabel: NSTextField!
    private var previewInfoLabel: NSTextField!
    private var previewMessageLabel: NSTextField!

    // MARK: - Performance Caches

    private let iconCache = NSCache<NSString, NSImage>()
    // MARK: - Data State

    private var rootItems: [FileItem] = []
    private var currentSortDescriptor: NSSortDescriptor? = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
    private var previewedItem: FileItem?
    private var previewImageLoadTask: DispatchWorkItem?
    private var archivePreviewLoadTask: DispatchWorkItem?
    private var previewTimeoutWorkItem: DispatchWorkItem?
    private var contentLoadTimeoutWorkItem: DispatchWorkItem?
    private var activeInlinePreviewRequestID: UUID?
    private var previewRequestID = UUID()
    private var contentLoadRequestID = UUID()
    private var previewRootURL: URL?
    private var quickLookItems: [FileItem] = []
    private var activeNativePreviewItem: QLPreviewItem?
    private var suppressOutlineSelectionSync = false
    private var didSetInitialSplitPosition = false
    private var previewUpdateWorkItem: DispatchWorkItem?
    private var scrollWheelMonitor: Any?
    private var extractedPreviewCache: [String: URL] = [:]
    private var extractedPreviewDirectoryURL: URL?
    private lazy var extractedPreviewDirectory: URL = {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PeekXArchivePreviews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        extractedPreviewDirectoryURL = directory
        return directory
    }()

    // MARK: - Formatters

    private lazy var byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    deinit {
        previewUpdateWorkItem?.cancel()
        previewImageLoadTask?.cancel()
        archivePreviewLoadTask?.cancel()
        previewTimeoutWorkItem?.cancel()
        contentLoadTimeoutWorkItem?.cancel()
        stopActiveMediaPreview()
        if let extractedPreviewDirectoryURL {
            try? FileManager.default.removeItem(at: extractedPreviewDirectoryURL)
        }
        if let scrollWheelMonitor {
            NSEvent.removeMonitor(scrollWheelMonitor)
        }
    }

    // MARK: - View Lifecycle

    override func loadView() {
        DebugLogger.shared.log("loadView started. Diagnostics log: \(DebugLogger.shared.locationDescription())")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        container.translatesAutoresizingMaskIntoConstraints = false

        // Main content split. The left side owns the folder header; the right preview can start at the top.
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        self.mainStack = stack

        headerView = createHeaderView()
        DebugLogger.shared.log("loadView created header")

        scrollView = FinderScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.installTranslucentScrollers()
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor

        outlineView = FinderOutlineView()
        outlineView.translatesAutoresizingMaskIntoConstraints = true
        outlineView.autoresizingMask = [.width]
        outlineView.delegate = self
        outlineView.dataSource = self
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.headerView = NSTableHeaderView()
        outlineView.focusRingType = .none
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowSizeStyle = .default
        outlineView.allowsColumnReordering = false
        outlineView.allowsColumnResizing = true
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        outlineView.keyboardDelegate = self
        outlineView.menu = contextMenu
        outlineView.menu?.delegate = self

        scrollView.documentView = outlineView
        DebugLogger.shared.log("loadView created outline")

        let leftPane = NSView()
        leftPane.translatesAutoresizingMaskIntoConstraints = false

        let outlineContainer = NSView()
        outlineContainer.translatesAutoresizingMaskIntoConstraints = false
        applySystemPreviewCornerStyle(to: outlineContainer, backgroundColor: .windowBackgroundColor)
        outlineContainer.addSubview(scrollView)

        leftPane.addSubview(headerView)
        leftPane.addSubview(outlineContainer)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: -PreviewMetrics.dividerContentGap),
            headerView.topAnchor.constraint(equalTo: leftPane.topAnchor),

            outlineContainer.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            outlineContainer.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor, constant: -PreviewMetrics.dividerContentGap),
            outlineContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 10),
            outlineContainer.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: outlineContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: outlineContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: outlineContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: outlineContainer.bottomAnchor)
        ])

        splitView = NSSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(leftPane)
        previewPane = createPreviewPane()
        DebugLogger.shared.log("loadView created preview pane")
        splitView.addArrangedSubview(previewPane)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        splitView.arrangedSubviews[0].widthAnchor.constraint(greaterThanOrEqualToConstant: 280 + PreviewMetrics.dividerContentGap).isActive = true
        splitView.arrangedSubviews[1].widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true

        mainStack.addArrangedSubview(splitView)

        container.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),

            splitView.widthAnchor.constraint(equalTo: mainStack.widthAnchor)
        ])

        // Content priorities to ensure SplitView fills space
        headerView.setContentHuggingPriority(.required, for: .vertical)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        splitView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let singleFilePreview = createTextPreviewScrollView()
        singleFileScrollView = singleFilePreview.scrollView
        singleFileTextView = singleFilePreview.textView
        applySystemPreviewCornerStyle(to: singleFileScrollView, backgroundColor: .white)
        singleFileScrollView.isHidden = true
        container.addSubview(singleFileScrollView)
        DebugLogger.shared.log("loadView created single file text view")

        NSLayoutConstraint.activate([
            singleFileScrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            singleFileScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            singleFileScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            singleFileScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])

        createColumns()
        syncPreviewWithSelection()
        self.view = container
        DebugLogger.shared.log("loadView completed")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installScrollWheelMonitorIfNeeded()
        outlineView.window?.makeFirstResponder(outlineView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didSetInitialSplitPosition {
            didSetInitialSplitPosition = true
            setDefaultSplitPosition()
        }
        updateOutlineScrollMetrics()
    }

    private func installScrollWheelMonitorIfNeeded() {
        guard scrollWheelMonitor == nil else { return }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  let target = self.horizontalScrollViewUnderMouse(in: self.view, event: event)
            else {
                return event
            }
            return FinderScrollView.scrollHorizontallyIfNeeded(target, with: event) ? nil : event
        }
    }

    private func horizontalScrollViewUnderMouse(in root: NSView, event: NSEvent) -> NSScrollView? {
        func find(in view: NSView) -> NSScrollView? {
            for subview in view.subviews.reversed() {
                if let found = find(in: subview) {
                    return found
                }
            }

            guard let scrollView = view as? NSScrollView,
                  !scrollView.isHiddenOrHasHiddenAncestor,
                  scrollView.hasHorizontalScroller,
                  scrollView.horizontalScroller != nil
            else { return nil }

            let point = scrollView.convert(event.locationInWindow, from: nil)
            let inScroller = scrollView.horizontalScroller?.frame.contains(point) == true
            let inBottomBand = point.y >= -2 && point.y <= scrollView.contentView.frame.minY + 28
            return (inScroller || inBottomBand) ? scrollView : nil
        }

        return find(in: root)
    }

    private func applySystemPreviewCornerStyle(to view: NSView, backgroundColor: NSColor? = nil) {
        view.wantsLayer = true
        if let backgroundColor {
            view.layer?.backgroundColor = backgroundColor.cgColor
        }
        view.layer?.cornerRadius = PreviewMetrics.cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }

    // MARK: - UI Builders
    private func createHeaderView() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        iconImageView = NSImageView()
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyDown

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        infoLabel = NSTextField(labelWithString: "")
        infoLabel.font = NSFont.systemFont(ofSize: 13)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(iconImageView)
        view.addSubview(titleLabel)
        view.addSubview(infoLabel)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            iconImageView.topAnchor.constraint(equalTo: view.topAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 48),
            iconImageView.heightAnchor.constraint(equalToConstant: 48),

            titleLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            infoLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            infoLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            infoLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            infoLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4)
        ])

        return view
    }
    private func setDefaultSplitPosition() {
        view.layoutSubtreeIfNeeded()
        let totalWidth = splitView.bounds.width
        guard totalWidth > 0 else { return }
        let previewMin: CGFloat = 360
        let outlineMin: CGFloat = 320 + PreviewMetrics.dividerContentGap
        let desiredLeft = max(outlineMin, min(totalWidth - previewMin, totalWidth * 0.4 + PreviewMetrics.dividerContentGap))
        splitView.setPosition(desiredLeft, ofDividerAt: 0)
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Left pane must remain at least wide enough for the outline columns.
        let leftMin: CGFloat = 280 + PreviewMetrics.dividerContentGap
        return leftMin
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // Right pane must keep at least one-third of the total split width.
        let totalWidth = splitView.bounds.width
        let rightMin = totalWidth / 3
        return totalWidth - rightMin - splitView.dividerThickness
    }

    private func createColumns() {
        outlineView.tableColumns.forEach { outlineView.removeTableColumn($0) }

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.minWidth = 250
        nameColumn.width = 380
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn

        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = "Date Modified"
        dateColumn.minWidth = 160
        dateColumn.width = 200
        dateColumn.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: false)
        outlineView.addTableColumn(dateColumn)

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.minWidth = 80
        sizeColumn.width = 120
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: false)
        outlineView.addTableColumn(sizeColumn)

        let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kindColumn.title = "Kind"
        kindColumn.minWidth = 140
        kindColumn.width = 180
        kindColumn.sortDescriptorPrototype = NSSortDescriptor(key: "kind", ascending: true)
        outlineView.addTableColumn(kindColumn)
    }

    private func createTextPreviewScrollView() -> (scrollView: NSScrollView, textView: NSTextView) {
        let scrollView = FinderScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.installTranslucentScrollers()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        applySystemPreviewCornerStyle(to: scrollView)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        textView.translatesAutoresizingMaskIntoConstraints = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor

        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private func createPreviewPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading

        let imageContainer = NSView()
        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        applySystemPreviewCornerStyle(to: imageContainer, backgroundColor: .windowBackgroundColor)
        previewContainerView = imageContainer

        previewImageScrollView = ImagePreviewScrollView()
        previewImageView = previewImageScrollView.imageView

        let textPreview = createTextPreviewScrollView()
        textScrollView = textPreview.scrollView
        textView = textPreview.textView
        textScrollView.isHidden = true

        previewSpinner = NSProgressIndicator()
        previewSpinner.translatesAutoresizingMaskIntoConstraints = false
        previewSpinner.style = .spinning
        previewSpinner.controlSize = .large
        previewSpinner.isDisplayedWhenStopped = false

        imageContainer.addSubview(previewImageScrollView)
        imageContainer.addSubview(textScrollView)
        imageContainer.addSubview(previewSpinner)

        NSLayoutConstraint.activate([
            previewImageScrollView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            previewImageScrollView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            previewImageScrollView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            previewImageScrollView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),

            textScrollView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            textScrollView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            textScrollView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            textScrollView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),

            previewSpinner.centerXAnchor.constraint(equalTo: imageContainer.centerXAnchor),
            previewSpinner.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor)
        ])

        previewTitleLabel = NSTextField(labelWithString: "No Selection")
        previewTitleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        previewTitleLabel.lineBreakMode = .byTruncatingTail
        previewTitleLabel.alignment = .center

        previewInfoLabel = NSTextField(labelWithString: "Select a file to preview.")
        previewInfoLabel.font = NSFont.systemFont(ofSize: 12)
        previewInfoLabel.textColor = .secondaryLabelColor
        previewInfoLabel.lineBreakMode = .byWordWrapping
        previewInfoLabel.alignment = .center

        previewMessageLabel = NSTextField(labelWithString: "")
        previewMessageLabel.font = NSFont.systemFont(ofSize: 12)
        previewMessageLabel.textColor = .tertiaryLabelColor
        previewMessageLabel.lineBreakMode = .byWordWrapping
        previewMessageLabel.alignment = .center
        previewMessageLabel.isHidden = true

        stack.addArrangedSubview(imageContainer)
        stack.addArrangedSubview(previewTitleLabel)
        stack.addArrangedSubview(previewInfoLabel)
        stack.addArrangedSubview(previewMessageLabel)
        stack.setCustomSpacing(4, after: previewTitleLabel)
        imageContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        pane.addSubview(stack)

        let preferredPreviewHeight = imageContainer.heightAnchor.constraint(equalTo: pane.heightAnchor, multiplier: 0.72)
        preferredPreviewHeight.priority = .defaultHigh
        let minimumPreviewHeight = imageContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 500)
        minimumPreviewHeight.priority = .defaultLow

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: PreviewMetrics.dividerContentGap),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor, constant: -16),
            preferredPreviewHeight,
            minimumPreviewHeight,

            previewTitleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewInfoLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewMessageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return pane
    }

    private func constrainPreviewSurface(_ surface: NSView) {
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: previewContainerView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: previewContainerView.trailingAnchor),
            surface.topAnchor.constraint(equalTo: previewContainerView.topAnchor),
            surface.bottomAnchor.constraint(equalTo: previewContainerView.bottomAnchor)
        ])
    }

    private func ensureNativePreviewView() -> QLPreviewView? {
        if let nativePreviewView {
            return nativePreviewView
        }

        guard let nativePreviewView = QLPreviewView(frame: .zero, style: .normal) else {
            return nil
        }
        nativePreviewView.translatesAutoresizingMaskIntoConstraints = false
        nativePreviewView.isHidden = true
        previewContainerView.addSubview(nativePreviewView, positioned: .below, relativeTo: previewSpinner)
        constrainPreviewSurface(nativePreviewView)
        self.nativePreviewView = nativePreviewView
        return nativePreviewView
    }

    private func ensurePDFView() -> PDFView {
        if let pdfView {
            return pdfView
        }

        let pdfView = PDFView(frame: .zero)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.isHidden = true
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .white
        previewContainerView.addSubview(pdfView, positioned: .below, relativeTo: previewSpinner)
        constrainPreviewSurface(pdfView)
        self.pdfView = pdfView
        return pdfView
    }

    private func ensureMediaPlayerView() -> AVPlayerView {
        if let mediaPlayerView {
            return mediaPlayerView
        }

        let mediaPlayerView = AVPlayerView(frame: .zero)
        mediaPlayerView.translatesAutoresizingMaskIntoConstraints = false
        mediaPlayerView.isHidden = true
        mediaPlayerView.controlsStyle = .inline
        mediaPlayerView.videoGravity = .resizeAspect
        applySystemPreviewCornerStyle(to: mediaPlayerView, backgroundColor: .black)
        previewContainerView.addSubview(mediaPlayerView, positioned: .below, relativeTo: previewSpinner)
        constrainPreviewSurface(mediaPlayerView)
        self.mediaPlayerView = mediaPlayerView
        return mediaPlayerView
    }

    private func hidePreviewSurfaces(clearNativePreview: Bool = true) {
        if clearNativePreview {
            activeNativePreviewItem = nil
            nativePreviewView?.previewItem = nil
        }
        stopActiveMediaPreview()
        nativePreviewView?.isHidden = true
        pdfView?.document = nil
        pdfView?.isHidden = true
        mediaPlayerView?.isHidden = true
        textScrollView.isHidden = true
        previewImageView.isHidden = true
        previewImageView.image = nil
    }

    private func showPreviewPlaceholderIcon(for item: FileItem) {
        previewImageView.renderMode = .centeredIcon
        previewImageView.isHidden = false
        if let existingImage = previewImageView.image, existingImage.size.width > 0 {
            return
        }
        loadLargeIcon(for: item) { [weak self, weak item] icon in
            guard let self,
                  let item,
                  self.previewedItem === item,
                  self.previewImageView.isHidden == false else { return }
            self.previewImageView.renderMode = .centeredIcon
            self.previewImageView.image = icon
        }
    }

    private func prepareLoadingPreview(for item: FileItem, message: String) {
        if !hasVisiblePreviewSurface {
            showPreviewPlaceholderIcon(for: item)
        }
        previewMessageLabel.stringValue = message
        previewMessageLabel.isHidden = false
        previewSpinner.startAnimation(nil)
    }

    private var hasVisiblePreviewSurface: Bool {
        if previewImageView.isHidden == false, previewImageView.image != nil { return true }
        if textScrollView.isHidden == false { return true }
        if nativePreviewView?.isHidden == false { return true }
        if pdfView?.isHidden == false { return true }
        if mediaPlayerView?.isHidden == false { return true }
        return false
    }

    private func stopActiveMediaPreview() {
        mediaPlayer?.pause()
        mediaPlayerView?.player = nil
        mediaPlayer = nil
        if let activeMediaSecurityScopedURL {
            activeMediaSecurityScopedURL.stopAccessingSecurityScopedResource()
            self.activeMediaSecurityScopedURL = nil
        }
    }

    // MARK: - Preview Loading
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        DebugLogger.shared.log("preparePreviewOfFile started for \(url.path)")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey])
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

    // MARK: - Helpers
    private func prepareFolderPreview(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let requestID = UUID()
        DispatchQueue.main.async {
            self.contentLoadRequestID = requestID
            handler(nil)
            self.showFolderLoading(for: url)
        }

        do {
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
                self.updateOutlineScrollMetrics()
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

    private func showFolderLoading(for url: URL) {
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
        updateOutlineScrollMetrics()

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

    private func showFolderError(for url: URL, error: Error) {
        applySingleFileLayout(false)
        let icon = headerIcon(for: url)
        rootItems = []
        previewRootURL = url
        iconImageView.image = icon
        titleLabel.stringValue = url.lastPathComponent
        infoLabel.stringValue = "Folder preview failed"
        outlineView.reloadData()
        updateOutlineScrollMetrics()
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

    private func headerIcon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 48, height: 48)
        return icon
    }

    private func prepareArchivePreview(at url: URL, provider: ArchiveProvider, resourceValues: URLResourceValues, completionHandler handler: @escaping (Error?) -> Void) {
        let requestID = UUID()
        let fileSize = Int64(resourceValues.fileSize ?? 0)

        DispatchQueue.main.async {
            self.contentLoadRequestID = requestID
            DebugLogger.shared.log("Completing Quick Look request early for archive \(url.lastPathComponent)")
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

    private func prepareSingleFilePreview(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
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

    private func showArchiveLoading(for url: URL, fileSize: Int64) {
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
        updateOutlineScrollMetrics()

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

    private func loadArchiveContents(at url: URL, provider: ArchiveProvider, fileSize: Int64, requestID: UUID) {
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
                self.updateOutlineScrollMetrics()
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

    private func scheduleContentLoadTimeout(requestID: UUID, message: String) {
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

    private func showArchiveError(for url: URL, error: Error, fileSize: Int64) {
        applySingleFileLayout(false)
        let icon = headerIcon(for: url)
        rootItems = []
        previewRootURL = url
        iconImageView.image = icon
        titleLabel.stringValue = url.lastPathComponent
        infoLabel.stringValue = "\(byteFormatter.string(fromByteCount: fileSize)) · archive preview failed"
        outlineView.reloadData()
        updateOutlineScrollMetrics()
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

    private final class ArchiveTreeNode {
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

    private func makeArchiveRootItems(from listing: ArchiveListing) -> [FileItem] {
        let root = ArchiveTreeNode(name: "", path: "", isDirectory: true)
        for entry in listing.entries {
            let cleanPath = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let components = cleanPath.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

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

    private func makeFileItem(from node: ArchiveTreeNode, archiveURL: URL) -> FileItem {
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

    private func countItems(in items: [FileItem]) -> (folders: Int, files: Int) {
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

    private func sortFileItems(_ items: inout [FileItem]) {
        guard !items.isEmpty else { return }
        let comparator = makeItemComparator()
        items.sort(by: comparator)
    }

    private func makeItemComparator() -> (FileItem, FileItem) -> Bool {
        if let descriptor = currentSortDescriptor {
            return { lhs, rhs in
                self.compareFileItems(lhs, rhs, with: descriptor)
            }
        }
        return { lhs, rhs in
            self.defaultItemComparator(lhs, rhs)
        }
    }

    private func compareFileItems(_ lhs: FileItem, _ rhs: FileItem, with descriptor: NSSortDescriptor) -> Bool {
        let ascending = descriptor.ascending
        switch descriptor.key ?? "name" {
        case "date":
            if lhs.modificationDate == rhs.modificationDate {
                return defaultItemComparator(lhs, rhs)
            }
            return ascending ? lhs.modificationDate < rhs.modificationDate : lhs.modificationDate > rhs.modificationDate
        case "size":
            if lhs.size == rhs.size {
                return defaultItemComparator(lhs, rhs)
            }
            return ascending ? lhs.size < rhs.size : lhs.size > rhs.size
        case "kind":
            if lhs.kindDescription == rhs.kindDescription {
                return defaultItemComparator(lhs, rhs)
            }
            return ascending ? lhs.kindDescription < rhs.kindDescription : lhs.kindDescription > rhs.kindDescription
        case "name":
            fallthrough
        default:
            if lhs.name == rhs.name {
                return defaultItemComparator(lhs, rhs)
            }
            if ascending {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            } else {
                return rhs.name.localizedStandardCompare(lhs.name) == .orderedAscending
            }
        }
    }

    private func defaultItemComparator(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        if lhs.isFolder != rhs.isFolder {
            return lhs.isFolder && !rhs.isFolder
        }
        return lhs.name.localizedStandardCompare(rhs.name) != .orderedDescending
    }

    private func resortDescendants(from items: [FileItem]) {
        guard !items.isEmpty else { return }
        let comparator = makeItemComparator()
        resortDescendants(items, comparator: comparator)
    }

    private func resortDescendants(_ items: [FileItem], comparator: @escaping (FileItem, FileItem) -> Bool) {
        for item in items {
            if var children = item.children {
                children.sort(by: comparator)
                item.children = children
                resortDescendants(children, comparator: comparator)
            }
        }
    }

    private func children(of item: FileItem?) -> [FileItem] {
        if let item {
            return item.children ?? []
        }
        return rootItems
    }

    private func syncPreviewWithSelection() {
        previewUpdateWorkItem?.cancel()
        let item = selectedItems.last
        beginPreviewSelection(for: item)

        let requestID = previewRequestID
        let workItem = DispatchWorkItem { [weak self, weak item] in
            guard let self else { return }
            self.startPreviewContent(for: item, requestID: requestID)
        }
        previewUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: workItem)
    }

    private func beginPreviewSelection(for item: FileItem?) {
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

    private func startPreviewContent(for item: FileItem?, requestID: UUID) {
        guard requestID == previewRequestID, let item, previewedItem === item else { return }

        if item.isArchiveEntry {
            loadArchiveEntryPreview(for: item, requestID: requestID)
            return
        }

        if item.isFolder {
            showFallbackIcon(for: item, message: "Folder contents are shown in the list.")
            return
        }

        showNativePreview(url: item.url, title: item.name, contentType: item.contentType, requestID: requestID)
    }

    private func showNativePreview(url: URL, title: String, contentType: UTType? = nil, requestID: UUID) {
        guard requestID == previewRequestID else { return }
        let type = contentType ?? UTType(filenameExtension: url.pathExtension)

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

    private func showPDFPreview(url: URL, requestID: UUID) {
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

                self.previewTimeoutWorkItem?.cancel()
                self.previewTimeoutWorkItem = nil
                self.activeInlinePreviewRequestID = nil
                self.previewSpinner.stopAnimation(nil)
                self.previewImageLoadTask = nil

                switch documentResult {
                case .success(let document):
                    self.hidePreviewSurfaces()
                    let pdfView = self.ensurePDFView()
                    pdfView.document = document
                    pdfView.autoScales = true
                    pdfView.goToFirstPage(nil)
                    pdfView.isHidden = false
                    self.previewMessageLabel.isHidden = true
                    DebugLogger.shared.log("PDF preview loaded for \(item.name)")
                case .failure(let error):
                    DebugLogger.shared.log("PDF preview failed for \(item.name): \(error.localizedDescription)")
                    self.showEmbeddedQuickLookPreview(url: url, title: item.name, requestID: requestID)
                }
            }
        }
        previewImageLoadTask = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    private func showMediaPreview(url: URL, title: String, requestID: UUID) {
        guard requestID == previewRequestID, let item = previewedItem else { return }

        activeInlinePreviewRequestID = requestID
        prepareLoadingPreview(for: item, message: "Loading media preview...")
        schedulePreviewTimeout(
            for: item,
            requestID: requestID,
            seconds: 4,
            message: "Media preview is taking longer than expected."
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let mediaResult = Result { try self.makeReadablePreviewCopy(of: url) }

            DispatchQueue.main.async {
                guard self.previewRequestID == requestID,
                      self.previewedItem === item,
                      self.activeInlinePreviewRequestID == requestID else { return }

                self.previewTimeoutWorkItem?.cancel()
                self.previewTimeoutWorkItem = nil
                self.activeInlinePreviewRequestID = nil
                self.previewSpinner.stopAnimation(nil)
                self.previewImageLoadTask = nil

                switch mediaResult {
                case .success(let playableURL):
                    self.hidePreviewSurfaces()
                    let playerView = self.ensureMediaPlayerView()
                    let player = AVPlayer(url: playableURL)
                    self.mediaPlayer = player
                    playerView.player = player
                    playerView.isHidden = false
                    self.previewMessageLabel.isHidden = true
                    DebugLogger.shared.log("Media preview loaded for \(title)")
                case .failure(let error):
                    DebugLogger.shared.log("Media preview failed for \(title): \(error.localizedDescription)")
                    self.showQuickLookThumbnailPreview(url: url, title: title, requestID: requestID)
                }
            }
        }
        previewImageLoadTask = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    private func showTextPreview(url: URL, requestID: UUID) {
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
                        self.previewTimeoutWorkItem?.cancel()
                        self.previewTimeoutWorkItem = nil
                        self.showQuickLookThumbnailPreview(url: url, title: url.lastPathComponent, requestID: requestID)
                        return
                    }

                    self.previewTimeoutWorkItem?.cancel()
                    self.previewTimeoutWorkItem = nil
                    self.activeInlinePreviewRequestID = nil
                    self.previewSpinner.stopAnimation(nil)
                    self.hidePreviewSurfaces()
                    self.textScrollView.isHidden = false
                    self.setTextPreview(text, in: self.textView, markdown: false, fontSize: 12)
                    self.previewMessageLabel.stringValue = result.isTruncated ? "Text preview truncated to keep switching responsive." : ""
                    self.previewMessageLabel.isHidden = !result.isTruncated
                    self.previewImageLoadTask = nil
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self,
                          self.previewRequestID == requestID,
                          self.previewedItem === item,
                          self.activeInlinePreviewRequestID == requestID else { return }
                    self.previewTimeoutWorkItem?.cancel()
                    self.previewTimeoutWorkItem = nil
                    self.showQuickLookThumbnailPreview(url: url, title: url.lastPathComponent, requestID: requestID)
                }
            }
        }
        previewImageLoadTask = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    private static func readTextPreview(from url: URL, maxBytes: Int) throws -> (text: String?, isTruncated: Bool) {
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

    private static func readCoordinatedData(from url: URL) throws -> Data {
        try coordinatedRead(from: url) { readableURL in
            try Data(contentsOf: readableURL, options: [.mappedIfSafe])
        }
    }

    private static func coordinatedRead<T>(from url: URL, operation: @escaping (URL) throws -> T) throws -> T {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

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
                Thread.sleep(forTimeInterval: 0.35)
            }
        }

        throw lastError ?? NSError(
            domain: "PeekX",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not coordinate file reading."]
        )
    }

    private func makeReadablePreviewCopy(of url: URL) throws -> URL {
        let ext = url.pathExtension
        let filename = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let destinationURL = extractedPreviewDirectory.appendingPathComponent(filename, isDirectory: false)
        try Self.coordinatedRead(from: url) { readableURL in
            try FileManager.default.copyItem(at: readableURL, to: destinationURL)
        }
        return destinationURL
    }

    private func showDOCXPreview(url: URL, requestID: UUID) {
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

                let readableURL = try self.makeReadablePreviewCopy(of: url)
                try LibarchiveArchiveProvider().extractEntry("word/document.xml", from: readableURL, to: documentXMLURL)
                let data = try Data(contentsOf: documentXMLURL)
                let text = try DOCXTextExtractor().extractText(from: data)

                DispatchQueue.main.async {
                    guard self.previewRequestID == requestID,
                          self.previewedItem === item,
                          self.activeInlinePreviewRequestID == requestID else { return }

                    self.previewTimeoutWorkItem?.cancel()
                    self.previewTimeoutWorkItem = nil
                    self.activeInlinePreviewRequestID = nil
                    self.previewSpinner.stopAnimation(nil)
                    self.hidePreviewSurfaces()
                    self.textScrollView.isHidden = false
                    self.setTextPreview(text.isEmpty ? "No text content found in this document." : text, in: self.textView, markdown: false, fontSize: 12)
                    self.previewMessageLabel.isHidden = true
                    self.previewImageLoadTask = nil
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.previewRequestID == requestID,
                          self.previewedItem === item,
                          self.activeInlinePreviewRequestID == requestID else { return }

                    self.previewTimeoutWorkItem?.cancel()
                    self.previewTimeoutWorkItem = nil
                    self.activeInlinePreviewRequestID = nil
                    self.previewSpinner.stopAnimation(nil)
                    DebugLogger.shared.log("DOCX preview failed for \(item.name): \(error.localizedDescription)")
                    self.showEmbeddedQuickLookPreview(url: url, title: item.name, requestID: requestID)
                }
            }
        }
        previewImageLoadTask = workItem
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    private func showEmbeddedQuickLookPreview(url: URL, title: String, requestID: UUID) {
        guard requestID == previewRequestID, let item = previewedItem else { return }

        activeInlinePreviewRequestID = requestID
        prepareLoadingPreview(for: item, message: "Loading preview...")

        let previewItem = URLPreviewItem(url: url, title: title)
        activeNativePreviewItem = previewItem
        guard let previewView = ensureNativePreviewView() else {
            showQuickLookThumbnailPreview(url: url, title: title, requestID: requestID)
            return
        }
        DebugLogger.shared.log("Embedded native preview requested for \(title)")
        hidePreviewSurfaces(clearNativePreview: false)
        previewView.previewItem = previewItem
        previewView.isHidden = false
        previewView.refreshPreviewItem()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak item] in
            guard let self,
                  let item,
                  self.previewRequestID == requestID,
                  self.previewedItem === item,
                  self.activeInlinePreviewRequestID == requestID else { return }
            self.previewSpinner.stopAnimation(nil)
            self.previewMessageLabel.isHidden = true
        }
    }

    private func showQuickLookThumbnailPreview(url: URL, title: String, requestID: UUID) {
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

                self.previewTimeoutWorkItem?.cancel()
                self.previewTimeoutWorkItem = nil
                self.previewSpinner.stopAnimation(nil)
                self.textScrollView.isHidden = true
                self.hidePreviewSurfaces()
                self.previewImageView.renderMode = .fit
                self.previewImageView.image = image
                self.previewImageView.isHidden = false
                if representationType == .thumbnail {
                    self.activeInlinePreviewRequestID = nil
                    let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    DebugLogger.shared.log("Quick Look thumbnail for \(title) finished in \(String(format: "%.1f", elapsed)) ms")
                    self.previewMessageLabel.isHidden = true
                } else {
                    self.previewMessageLabel.stringValue = "Generating full preview..."
                    self.previewMessageLabel.isHidden = false
                }
            }
        }
    }

    private func updateOutlineScrollMetrics() {
        let clipView = scrollView.contentView
        let rowExtent = outlineView.rowHeight + outlineView.intercellSpacing.height
        let headerHeight = outlineView.headerView?.frame.height ?? 0
        let contentHeight = max(CGFloat(max(outlineView.numberOfRows, 1)) * rowExtent + headerHeight, clipView.bounds.height + 1)
        let contentWidth = max(outlineView.tableColumns.reduce(CGFloat(0)) { $0 + $1.width }, clipView.bounds.width + 1)

        outlineView.setFrameSize(NSSize(width: contentWidth, height: contentHeight))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.installTranslucentScrollers()
        scrollView.reflectScrolledClipView(clipView)
    }

    private func schedulePreviewTimeout(for item: FileItem, requestID: UUID, seconds: TimeInterval, message: String) {
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

    private func shouldRenderAsText(url: URL, contentType: UTType?) -> Bool {
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

    private func isMarkdownFile(url: URL, contentType: UTType?) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md"
            || ext == "markdown"
            || contentType == UTType(filenameExtension: "md")
            || contentType?.identifier == "net.daringfireball.markdown"
    }

    private func isDOCXFile(url: URL, contentType: UTType?) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "docx"
            || contentType?.identifier == "org.openxmlformats.wordprocessingml.document"
    }

    private func shouldUseMediaPlayerPreview(url: URL, contentType: UTType?) -> Bool {
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

    private func shouldUseEmbeddedNativePreview(url: URL, contentType: UTType?) -> Bool {
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

    private func escapedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func loadArchiveEntryPreview(for item: FileItem, requestID: UUID) {
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

    private func showFallbackIcon(for item: FileItem, message: String, preservingActiveRequest: Bool = false) {
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
        previewMessageLabel.isHidden = false
        loadLargeIcon(for: item) { [weak self] icon in
            guard let self, self.previewedItem === item else { return }
            self.previewImageView.renderMode = .centeredIcon
            self.previewImageView.image = icon
        }
    }

    private func shouldAttemptNativePreview(for item: FileItem) -> Bool {
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

    private func makeExtractedPreviewURL(for item: FileItem) -> URL {
        let ext = (item.name as NSString).pathExtension
        let filename = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        return extractedPreviewDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    private func setTextPreview(_ text: String, in textView: NSTextView, markdown: Bool, fontSize: CGFloat) {
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
    }

    private func setRenderedHTMLPreview(_ html: String, in textView: NSTextView) {
        let backgroundColor = NSColor.white
        textView.drawsBackground = true
        textView.backgroundColor = backgroundColor
        textView.textColor = .black
        textView.enclosingScrollView?.drawsBackground = true
        textView.enclosingScrollView?.backgroundColor = backgroundColor
        textView.enclosingScrollView?.contentView.drawsBackground = true
        textView.enclosingScrollView?.contentView.backgroundColor = backgroundColor

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
        textView.scrollToBeginningOfDocument(nil)
    }

    private func flattenImportedHTMLListMarkers(in attributed: NSMutableAttributedString) {
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

    private func applySingleFileLayout(_ enabled: Bool) {
        mainStack.isHidden = enabled
        singleFileScrollView.isHidden = !enabled
    }

    private func showSingleFileTextPreview(url: URL) {
        applySingleFileLayout(true)
        singleFileTextView.string = ""

        DispatchQueue.global(qos: .userInitiated).async {
            let content = (try? Self.readTextPreview(from: url, maxBytes: 2 * 1024 * 1024))?.text ?? "Could not read file."
            DispatchQueue.main.async {
                self.applySingleFileLayout(true)
                self.setTextPreview(content, in: self.singleFileTextView, markdown: false, fontSize: 14)
            }
        }
    }

    private func showSingleFileMarkdownPreview(url: URL) {
        applySingleFileLayout(true)
        singleFileTextView.string = ""
        setRenderedHTMLPreview(markdownLoadingHTML(), in: singleFileTextView)
        loadMarkdownHTML(from: url) { [weak self] html, _ in
            guard let self else { return }
            self.applySingleFileLayout(true)
            self.setRenderedHTMLPreview(html, in: self.singleFileTextView)
            DebugLogger.shared.log("Markdown rendered for \(url.lastPathComponent)")
        }
    }

    private func showMarkdownPreview(url: URL, item: FileItem, requestID: UUID) {
        guard requestID == previewRequestID else { return }
        activeInlinePreviewRequestID = requestID
        prepareLoadingPreview(for: item, message: "Loading markdown preview...")

        loadMarkdownHTML(from: url) { [weak self] html, _ in
            guard let self,
                  self.previewRequestID == requestID,
                  self.previewedItem === item,
                  self.activeInlinePreviewRequestID == requestID else { return }
            self.previewTimeoutWorkItem?.cancel()
            self.previewTimeoutWorkItem = nil
            self.activeInlinePreviewRequestID = nil
            self.previewSpinner.stopAnimation(nil)
            self.hidePreviewSurfaces()
            self.textScrollView.isHidden = false
            self.setRenderedHTMLPreview(html, in: self.textView)
            self.previewMessageLabel.isHidden = true
            DebugLogger.shared.log("Markdown rendered for \(item.name)")
        }
    }

    private func loadMarkdownHTML(from url: URL, completion: @escaping (String, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = (try? Self.readTextPreview(from: url, maxBytes: 2 * 1024 * 1024))?.text ?? ""
            let html = self.makeOriginalMarkdownHTML(fromMarkdown: text)
            DispatchQueue.main.async {
                completion(html, text)
            }
        }
    }

    private func markdownLoadingHTML() -> String {
        originalMarkdownHTML(body: "<p>Loading...</p>")
    }

    private func makeOriginalMarkdownHTML(fromMarkdown markdown: String) -> String {
        let htmlBody = makeHTML(fromMarkdown: markdown)

        return originalMarkdownHTML(
            body: """
                <div id="content">\(htmlBody)</div>
            """
        )
    }

    private func originalMarkdownHTML(body htmlBody: String) -> String {
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
            }
            pre code { background: none; padding: 0; }
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

    private func makeHTML(fromMarkdown markdown: String) -> String {
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "<p>No content.</p>"
        }
        return renderMarkdownHTML(markdown)
    }

    private func renderMarkdownHTML(_ markdown: String) -> String {
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

        func closeList() {
            // Lists are rendered as plain paragraphs to avoid AppKit's HTML importer
            // synthesizing heavyweight NSTextList markers.
        }

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

    private func markdownHeadingLevel(_ line: String) -> Int? {
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

    private func isMarkdownFence(_ line: String) -> Bool {
        line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    private func isMarkdownDetailsBoundary(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return matchesMarkdownPattern(#"(?i)^<details\b[^>]*>$"#, in: normalized)
            || matchesMarkdownPattern(#"(?i)^</details>$"#, in: normalized)
    }

    private func markdownSummaryContent(_ line: String) -> String? {
        let pattern = #"(?i)^<summary\b[^>]*>\s*(.*?)\s*</summary>$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges == 2 else { return nil }
        return nsLine.substring(with: match.range(at: 1))
    }

    private func matchesMarkdownPattern(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private func markdownBlockquoteContent(_ line: String) -> String {
        guard line.hasPrefix(">") else { return line }
        let afterMarker = line.dropFirst()
        return String(afterMarker).trimmingCharacters(in: .whitespaces)
    }

    private func isMarkdownHorizontalRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3,
              let first = compact.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private func unorderedMarkdownListItem(_ line: String) -> String? {
        guard line.count > 2,
              let first = line.first,
              first == "-" || first == "*" || first == "+" else { return nil }
        let second = line[line.index(after: line.startIndex)]
        guard second == " " else { return nil }
        return String(line.dropFirst(2))
    }

    private func orderedMarkdownListItem(_ line: String) -> (number: String, content: String)? {
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

    private func isMarkdownTableSeparator(_ line: String) -> Bool {
        let compact = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "")
        guard compact.contains("|"), compact.contains("-") else { return false }
        return compact.allSatisfy { character in
            character == "|" || character == "-" || character == ":"
        }
    }

    private func renderMarkdownTable(lines: [String], startIndex: Int) -> (html: String, nextIndex: Int) {
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

    private func splitMarkdownTableRow(_ line: String) -> [String] {
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

    private func renderMarkdownInline(_ text: String) -> String {
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

    private func replaceInlineCodeSpans(in text: String, placeholders: inout [String: String]) -> String {
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

    private func renderMarkdownInlineHTMLFragment(_ text: String) -> String {
        var html = renderMarkdownInline(text)
        html = replaceMarkdownPattern("&lt;b&gt;(.+?)&lt;/b&gt;", in: html, with: "<strong>$1</strong>")
        html = replaceMarkdownPattern("&lt;strong&gt;(.+?)&lt;/strong&gt;", in: html, with: "<strong>$1</strong>")
        html = replaceMarkdownPattern("&lt;i&gt;(.+?)&lt;/i&gt;", in: html, with: "<em>$1</em>")
        html = replaceMarkdownPattern("&lt;em&gt;(.+?)&lt;/em&gt;", in: html, with: "<em>$1</em>")
        return html
    }

    private func replaceMarkdownPattern(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private func loadPreviewImage(at url: URL, item: FileItem?, requestID: UUID) {
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
                self.previewTimeoutWorkItem?.cancel()
                self.previewTimeoutWorkItem = nil
                self.activeInlinePreviewRequestID = nil
                self.previewSpinner.stopAnimation(nil)
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                DebugLogger.shared.log("Preview image load for \(item.name) finished in \(String(format: "%.1f", elapsed)) ms")
                switch imageResult {
                case .success(let image):
                    self.hidePreviewSurfaces()
                    self.previewImageView.renderMode = .orientationFill
                    self.previewImageView.image = image
                    self.previewImageView.isHidden = false
                    self.previewImageView.needsDisplay = true
                    self.previewMessageLabel.isHidden = true
                case .failure(let error):
                    DebugLogger.shared.log("Image decode failed for \(item.name): \(error.localizedDescription)")
                    self.showEmbeddedQuickLookPreview(url: url, title: item.name, requestID: requestID)
                }
                self.previewImageLoadTask = nil
            }
        }
        previewImageLoadTask = task
        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }

    private static func loadDecodedImage(from url: URL, maxPixelSize: Int) throws -> NSImage {
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

    private var selectedItems: [FileItem] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileItem }
    }

    private func actionPaths() -> [String] {
        let selection = selectedItems.map { $0.copyPath }
        if !selection.isEmpty { return selection }
        if let previewedItem {
            return [previewedItem.copyPath]
        }
        return []
    }

    @objc private func copyPathAction() {
        let paths = actionPaths()
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(paths as [NSString])
    }

    private func showQuickLook() {
        quickLookItems = selectedItems.filter { $0.previewItemURL != nil }
        guard QLPreviewPanel.shared()?.isVisible == false else {
            QLPreviewPanel.shared()?.reloadData()
            return
        }
        guard let panel = QLPreviewPanel.shared(), !quickLookItems.isEmpty else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(self)
    }

    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu(title: "Actions")
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPathAction), keyEquivalent: "")
        return menu
    }()


    private func loadChildren(for item: FileItem, completion: @escaping () -> Void) {
        if item.isArchiveEntry {
            completion()
            return
        }
        if item.childrenLoaded {
            completion()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let start = CFAbsoluteTimeGetCurrent()
                let contents = try FileManager.default.contentsOfDirectory(
                    at: item.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )
                var children: [FileItem] = []
                children.reserveCapacity(contents.count)
                for entry in contents {
                    let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .contentModificationDateKey])
                    children.append(FileItem(url: entry, resourceValues: values, parent: item))
                }
                self.sortFileItems(&children)
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                DispatchQueue.main.async {
                    DebugLogger.shared.log("Loaded \(children.count) children for \(item.name) in \(String(format: "%.1f", elapsed)) ms")
                    item.setChildren(children)
                    completion()
                    self.updateOutlineScrollMetrics()
                }
            } catch {
                DispatchQueue.main.async {
                    DebugLogger.shared.log("Failed to load children for \(item.name): \(error.localizedDescription)")
                    item.setChildren([])
                    completion()
                    self.updateOutlineScrollMetrics()
                }
            }
        }
    }

    private func loadIcon(for item: FileItem, completion: @escaping (NSImage) -> Void) {
        // First check if item already has icon cached
        if let icon = item.icon {
            completion(icon)
            return
        }

        let cacheKey = iconCacheKey(for: item, sizeSuffix: "small")

        // Check NSCache
        if let cached = iconCache.object(forKey: cacheKey) {
            item.icon = cached
            completion(cached)
            return
        }

        let icon = workspaceIcon(for: item, size: NSSize(width: 16, height: 16))
        icon.size = NSSize(width: 16, height: 16)
        iconCache.setObject(icon, forKey: cacheKey)
        item.icon = icon
        completion(icon)
    }

    private func loadLargeIcon(for item: FileItem, completion: @escaping (NSImage) -> Void) {
        let cacheKey = iconCacheKey(for: item, sizeSuffix: "large")

        // Check cache for large icon
        if let cached = iconCache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        let icon = workspaceIcon(for: item, size: NSSize(width: 256, height: 256))
        icon.size = NSSize(width: 256, height: 256)
        iconCache.setObject(icon, forKey: cacheKey)
        completion(icon)
    }

    private func workspaceIcon(for item: FileItem, size: NSSize) -> NSImage {
        let icon: NSImage
        if item.isFolder {
            icon = NSWorkspace.shared.icon(for: .folder)
        } else if let contentType = item.contentType {
            icon = NSWorkspace.shared.icon(for: contentType)
        } else {
            let ext = (item.name as NSString).pathExtension
            icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        icon.size = size
        return icon
    }

    private func iconCacheKey(for item: FileItem, sizeSuffix: String) -> NSString {
        if item.isArchiveEntry {
            if item.isFolder {
                return "archive-entry-folder-\(sizeSuffix)" as NSString
            }
            let ext = (item.name as NSString).pathExtension.lowercased()
            return "archive-entry-\(ext.isEmpty ? "data" : ext)-\(sizeSuffix)" as NSString
        }
        if item.isFolder {
            return "type-folder-\(sizeSuffix)" as NSString
        }
        if let contentType = item.contentType {
            return "type-\(contentType.identifier)-\(sizeSuffix)" as NSString
        }
        let ext = (item.name as NSString).pathExtension.lowercased()
        return "type-\(ext.isEmpty ? "data" : ext)-\(sizeSuffix)" as NSString
    }
}

// MARK: - NSOutlineViewDataSource
extension PreviewViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        return children(of: item as? FileItem).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        return children(of: item as? FileItem)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let fileItem = item as? FileItem else { return false }
        return fileItem.isFolder
    }
}

// MARK: - NSOutlineViewDelegate
extension PreviewViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let fileItem = item as? FileItem,
              let identifier = tableColumn?.identifier else { return nil }
        let reuseIdentifier = NSUserInterfaceItemIdentifier("cell-\(identifier.rawValue)")
        let cellView: NSTableCellView

        if let existing = outlineView.makeView(withIdentifier: reuseIdentifier, owner: self) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = reuseIdentifier
            let stackView = NSStackView()
            stackView.translatesAutoresizingMaskIntoConstraints = false
            stackView.orientation = .horizontal
            stackView.alignment = .centerY
            stackView.spacing = 6
            cellView.addSubview(stackView)
            NSLayoutConstraint.activate([
                stackView.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 6),
                stackView.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -6),
                stackView.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 2),
                stackView.bottomAnchor.constraint(equalTo: cellView.bottomAnchor, constant: -2)
            ])
            if identifier.rawValue == "name" {
                let imageView = NSImageView()
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.imageScaling = .scaleProportionallyDown
                NSLayoutConstraint.activate([
                    imageView.widthAnchor.constraint(equalToConstant: 16),
                    imageView.heightAnchor.constraint(equalToConstant: 16)
                ])
                stackView.addArrangedSubview(imageView)
                cellView.imageView = imageView
            }
            let alignment: NSTextAlignment = identifier.rawValue == "size" ? .right : .left
            let textField = NSTextField()
            textField.isBordered = false
            textField.backgroundColor = .clear
            textField.isEditable = false
            textField.font = NSFont.systemFont(ofSize: 13)
            textField.textColor = .labelColor
            textField.lineBreakMode = .byTruncatingTail
            textField.alignment = alignment
            textField.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(textField)
            cellView.textField = textField
        }
        cellView.objectValue = fileItem

        switch identifier.rawValue {
        case "name":
            cellView.textField?.stringValue = fileItem.name
            loadIcon(for: fileItem) { [weak cellView, weak fileItem] icon in
                guard let cellView, let fileItem, cellView.objectValue as? FileItem === fileItem else { return }
                cellView.imageView?.image = icon
            }
        case "date":
            // Use cached formatted date to avoid repeated formatting
            cellView.textField?.stringValue = fileItem.formattedDate(using: dateFormatter)
        case "size":
            // Use cached formatted size to avoid repeated formatting
            cellView.textField?.stringValue = fileItem.formattedSize(using: byteFormatter)
        case "kind":
            cellView.textField?.stringValue = fileItem.kindDescription
        default:
            cellView.textField?.stringValue = ""
        }
        return cellView
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        currentSortDescriptor = outlineView.sortDescriptors.first

        // Move sorting to background thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            self.sortFileItems(&self.rootItems)
            self.resortDescendants(from: self.rootItems)

            DispatchQueue.main.async {
                // Use targeted reload instead of full reloadData()
                self.outlineView.reloadItem(nil, reloadChildren: true)
                self.updateOutlineScrollMetrics()
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let fileItem = item as? FileItem else { return false }
        loadChildren(for: fileItem) {
            outlineView.reloadItem(fileItem, reloadChildren: true)
            self.updateOutlineScrollMetrics()
        }
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSOutlineView === outlineView else { return }
        guard !suppressOutlineSelectionSync else { return }
        syncPreviewWithSelection()
    }
}

extension PreviewViewController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let location = outlineView.convert(outlineView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let row = outlineView.row(at: location)
        if row >= 0 && !outlineView.isRowSelected(row) {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let hasSelection = !selectedItems.isEmpty
        menu.items.forEach { $0.isEnabled = hasSelection }
    }
}

// MARK: - Quick Look Panel
extension PreviewViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookItems[index]
    }
}

// MARK: - Outline Keyboard Delegate
extension PreviewViewController: FinderOutlineViewKeyboardDelegate {
    func outlineView(_ outlineView: FinderOutlineView, handle event: NSEvent) -> Bool {
        let commandPressed = event.modifierFlags.contains(.command)
        switch (event.keyCode, commandPressed) {
        case (49, false): // Space
            showQuickLook()
            return true
        case (_, true) where event.charactersIgnoringModifiers == "c":
            copyPathAction()
            return true
        default:
            return false
        }
    }
}
