// PeekX - macOS Quick Look 预览扩展
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
// MARK: - 预览主控制器

@objc(PreviewViewController)
/// Quick Look 扩展的主控制器。
///
/// 本文件负责 AppKit 视图层级、大纲列表的数据源/代理、分割视图、图标缓存、
/// 键盘快捷键和共享预览容器。具体文件类型的加载流程放在
/// `PreviewViewController+Previews.swift`，让界面骨架和预览流水线分开。
final class PreviewViewController: NSViewController, QLPreviewingController, NSSplitViewDelegate {

    // MARK: - 界面组件

    var mainStack: NSStackView!
    var scrollView: FinderScrollView!
    var splitView: NSSplitView!
    var outlineView: FinderOutlineView!
    var headerView: NSView!
    var iconImageView: NSImageView!
    var titleLabel: NSTextField!
    var infoLabel: NSTextField!
    var previewPane: NSView!
    var previewContainerView: NSView!
    var previewImageScrollView: ImagePreviewScrollView!
    var previewImageView: ImagePreviewView!
    var nativePreviewView: QLPreviewView?
    var pdfView: PDFView?
    var mediaPlayerView: AVPlayerView?
    var mediaPlayer: AVPlayer?
    var activeMediaSecurityScopedURL: URL?
    var textScrollView: NSScrollView!
    var textView: NSTextView!
    var singleFileScrollView: NSScrollView!
    var singleFileTextView: NSTextView!
    var previewSpinner: NSProgressIndicator!
    var previewTitleLabel: NSTextField!
    var previewInfoLabel: NSTextField!
    var previewMessageLabel: NSTextField!

    // MARK: - 性能缓存

    let iconCache = NSCache<NSString, NSImage>()

    // MARK: - 数据状态

    var rootItems: [FileItem] = []
    var currentSortDescriptor: NSSortDescriptor? = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))
    var previewedItem: FileItem?
    var previewImageLoadTask: DispatchWorkItem?
    var archivePreviewLoadTask: DispatchWorkItem?
    var previewTimeoutWorkItem: DispatchWorkItem?
    var contentLoadTimeoutWorkItem: DispatchWorkItem?
    var activeInlinePreviewRequestID: UUID?
    var previewRequestID = UUID()
    var contentLoadRequestID = UUID()
    var previewRootURL: URL?
    var quickLookItems: [FileItem] = []
    var activeNativePreviewItem: QLPreviewItem?
    var suppressOutlineSelectionSync = false
    var didSetInitialSplitPosition = false
    var selectionPreviewWorkItem: DispatchWorkItem?
    var previewUpdateWorkItem: DispatchWorkItem?
    var scrollWheelMonitor: Any?
    var mouseDownLatencyMonitor: Any?
    var pointerInteractionPriorityUntil: CFAbsoluteTime = 0
    var pointerInteractionGeneration: UInt64 = 0
    var extractedPreviewCache: [String: URL] = [:]
    var extractedPreviewDirectoryURL: URL?
    lazy var extractedPreviewDirectory: URL = {
        // 需要交给系统 Quick Look 预览的压缩包成员会先解到该控制器专属临时目录，
        // 控制器释放时统一清理。
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PeekXArchivePreviews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        extractedPreviewDirectoryURL = directory
        return directory
    }()

    // MARK: - 格式化器

    lazy var byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    deinit {
        previewUpdateWorkItem?.cancel()
        selectionPreviewWorkItem?.cancel()
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
        if let mouseDownLatencyMonitor {
            NSEvent.removeMonitor(mouseDownLatencyMonitor)
        }
    }

    // MARK: - 视图生命周期

    private var latencyCriticalActivity: NSObjectProtocol?

    override func loadView() {
        // Quick Look 面板打开期间尽量避免 App Nap/进程节流增加事件投递延迟。
        latencyCriticalActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "PeekX preview interaction requires low-latency event delivery"
        )
        DebugLogger.shared.log("loadView started. Diagnostics log: \(DebugLogger.shared.locationDescription())")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        container.translatesAutoresizingMaskIntoConstraints = false

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
        // 使用 legacy scroller 并关闭自动隐藏，保证横向/纵向滚动条始终可见。
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
        installMouseDownLatencyMonitorIfNeeded()
        outlineView.window?.makeFirstResponder(outlineView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !didSetInitialSplitPosition {
            didSetInitialSplitPosition = true
            setDefaultSplitPosition()
        }
        // 让大纲视图至少和可见区域一样高，使交替行背景能铺满空白区域。
        // 这里不改变滚动位置。
        let clipSize = scrollView.contentView.bounds.size
        let frame = outlineView.frame
        if frame.height < clipSize.height + 1 {
            outlineView.setFrameSize(NSSize(width: frame.width, height: clipSize.height + 1))
        }
    }

    // MARK: - 滚轮监控

    func installScrollWheelMonitorIfNeeded() {
        guard scrollWheelMonitor == nil else { return }
        // 原生 AppKit 不会把悬停在底部滚动条附近的纵向滚轮转换为横向滚动；
        // 这里为左侧列表和右侧预览区域统一补上该交互。
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                  let target = self.scrollViewForHorizontalScroll(in: self.view, event: event)
            else {
                return event
            }
            return FinderScrollView.scrollHorizontally(target, with: event) ? nil : event
        }
    }

    func installMouseDownLatencyMonitorIfNeeded() {
        guard mouseDownLatencyMonitor == nil else { return }
        mouseDownLatencyMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  event.window === self.view.window else {
                return event
            }

            let eventAge = EventLatency.uptimeEventAgeMilliseconds(for: event)
            let cgAge = EventLatency.formattedCGAge(for: event)
            guard let point = self.visibleOutlinePoint(for: event) else {
                DebugLogger.shared.log(String(format: "[PERF] localMouseDownMonitor outside outline: eventAge=%.1fms cgAge=%@",
                                              eventAge, cgAge))
                return event
            }
            let row = self.outlineView.row(at: point)
            DebugLogger.shared.log(String(format: "[PERF] localMouseDownMonitor: eventAge=%.1fms cgAge=%@ row=%d",
                                          eventAge, cgAge, row))
            return self.handleFastOutlineMouseDown(event, point: point, row: row, eventAge: eventAge) ? nil : event
        }
    }

    func visibleOutlinePoint(for event: NSEvent) -> NSPoint? {
        let clipPoint = scrollView.contentView.convert(event.locationInWindow, from: nil)
        guard scrollView.contentView.bounds.contains(clipPoint) else {
            return nil
        }

        let point = outlineView.convert(event.locationInWindow, from: nil)
        guard outlineView.visibleRect.contains(point) else {
            return nil
        }
        return point
    }

    func handleFastOutlineMouseDown(_ event: NSEvent, point: NSPoint, row: Int, eventAge: TimeInterval) -> Bool {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard row >= 0,
              outlineView.visibleRect.contains(point),
              !event.modifierFlags.contains(.control)
        else {
            return false
        }

        notePointerInteraction(row: row, eventAge: eventAge)
        let shouldExtend = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: shouldExtend)
        outlineView.markSelectionForDisplay(row: row)
        outlineView.displayIfNeeded()
        outlineView.window?.makeFirstResponder(outlineView)

        if outlineView.frameOfOutlineCell(atRow: row).contains(point),
           let fileItem = outlineView.item(atRow: row) as? FileItem,
           fileItem.isFolder {
            if outlineView.isItemExpanded(fileItem) {
                outlineView.collapseItem(fileItem)
            } else {
                outlineView.expandItem(fileItem)
            }
            updateOutlineScrollMetrics()
            DebugLogger.shared.log(String(format: "[PERF] localMouseDownFastPath toggled row=%d expanded=%@ code=%.1fms",
                                          row,
                                          outlineView.isItemExpanded(fileItem) ? "true" : "false",
                                          (CFAbsoluteTimeGetCurrent() - t0) * 1000))
            return true
        }

        DebugLogger.shared.log(String(format: "[PERF] localMouseDownFastPath handled row=%d code=%.1fms",
                                      row, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        return true
    }

    func scrollViewForHorizontalScroll(in root: NSView, event: NSEvent) -> NSScrollView? {
        for subview in root.subviews.reversed() {
            if let found = scrollViewForHorizontalScroll(in: subview, event: event) {
                return found
            }
        }
        guard let scrollView = root as? NSScrollView,
              !scrollView.isHiddenOrHasHiddenAncestor,
              scrollView.hasHorizontalScroller
        else { return nil }

        let point = scrollView.convert(event.locationInWindow, from: nil)
        let overScroller = scrollView.horizontalScroller?.frame.contains(point) == true
        let inBottomBand = point.y >= -2 && point.y <= scrollView.contentView.frame.minY + 28
        return (overScroller || inBottomBand) ? scrollView : nil
    }

    func applySystemPreviewCornerStyle(to view: NSView, backgroundColor: NSColor? = nil) {
        view.wantsLayer = true
        if let backgroundColor {
            view.layer?.backgroundColor = backgroundColor.cgColor
        }
        view.layer?.cornerRadius = PreviewMetrics.cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }

    // MARK: - 界面构建

    func createHeaderView() -> NSView {
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

    func setDefaultSplitPosition() {
        view.layoutSubtreeIfNeeded()
        let totalWidth = splitView.bounds.width
        guard totalWidth > 0 else { return }
        // 分割线两侧留出空隙，避免视觉上贴住左侧圆角列表容器。
        let previewMin: CGFloat = 360
        let outlineMin: CGFloat = 320 + PreviewMetrics.dividerContentGap
        let desiredLeft = max(outlineMin, min(totalWidth - previewMin, totalWidth * 0.4 + PreviewMetrics.dividerContentGap))
        splitView.setPosition(desiredLeft, ofDividerAt: 0)
    }

    // MARK: - 分割视图代理

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let leftMin: CGFloat = 280 + PreviewMetrics.dividerContentGap
        return leftMin
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let totalWidth = splitView.bounds.width
        let rightMin = totalWidth / 3
        return totalWidth - rightMin - splitView.dividerThickness
    }

    func createColumns() {
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

    func createTextPreviewScrollView() -> (scrollView: NSScrollView, textView: NSTextView) {
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
        // 文本预览按面板宽度换行；图片和表格由各自预览容器处理滚动。
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor

        scrollView.documentView = textView
        return (scrollView, textView)
    }

    func createPreviewPane() -> NSView {
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

    func constrainPreviewSurface(_ surface: NSView) {
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: previewContainerView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: previewContainerView.trailingAnchor),
            surface.topAnchor.constraint(equalTo: previewContainerView.topAnchor),
            surface.bottomAnchor.constraint(equalTo: previewContainerView.bottomAnchor)
        ])
    }

    // MARK: - 预览表面管理

    func ensureNativePreviewView() -> QLPreviewView? {
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

    func ensurePDFView() -> PDFView {
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

    func ensureMediaPlayerView() -> AVPlayerView {
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

    func hidePreviewSurfaces(clearNativePreview: Bool = true) {
        if clearNativePreview {
            // 离开系统 Quick Look 预览时必须清空 previewItem，
            // 否则旧的系统渲染内容可能残留在右侧。
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

    func showPreviewPlaceholderIcon(for item: FileItem) {
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

    func prepareLoadingPreview(for item: FileItem, message: String) {
        if !hasVisiblePreviewSurface {
            showPreviewPlaceholderIcon(for: item)
        }
        previewMessageLabel.stringValue = message
        previewMessageLabel.isHidden = false
        previewSpinner.startAnimation(nil)
    }

    var hasVisiblePreviewSurface: Bool {
        if previewImageView.isHidden == false, previewImageView.image != nil { return true }
        if textScrollView.isHidden == false { return true }
        if nativePreviewView?.isHidden == false { return true }
        if pdfView?.isHidden == false { return true }
        if mediaPlayerView?.isHidden == false { return true }
        return false
    }

    func stopActiveMediaPreview() {
        mediaPlayer?.pause()
        mediaPlayerView?.player = nil
        mediaPlayer = nil
        if let activeMediaSecurityScopedURL {
            activeMediaSecurityScopedURL.stopAccessingSecurityScopedResource()
            self.activeMediaSecurityScopedURL = nil
        }
    }

    // MARK: - 布局切换

    func applySingleFileLayout(_ enabled: Bool) {
        mainStack.isHidden = enabled
        if !enabled {
            singleFileScrollView.isHidden = true
        }
    }

    // MARK: - 头部图标

    func headerIcon(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 48, height: 48)
        return icon
    }

    // MARK: - 排序

    func sortFileItems(_ items: inout [FileItem]) {
        guard !items.isEmpty else { return }
        let comparator = makeItemComparator()
        items.sort(by: comparator)
    }

    func makeItemComparator() -> (FileItem, FileItem) -> Bool {
        if let descriptor = currentSortDescriptor {
            return { lhs, rhs in
                self.compareFileItems(lhs, rhs, with: descriptor)
            }
        }
        return { lhs, rhs in
            self.defaultItemComparator(lhs, rhs)
        }
    }

    func compareFileItems(_ lhs: FileItem, _ rhs: FileItem, with descriptor: NSSortDescriptor) -> Bool {
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

    func defaultItemComparator(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        if lhs.isFolder != rhs.isFolder {
            return lhs.isFolder && !rhs.isFolder
        }
        return lhs.name.localizedStandardCompare(rhs.name) != .orderedDescending
    }

    func resortDescendants(from items: [FileItem]) {
        guard !items.isEmpty else { return }
        let comparator = makeItemComparator()
        resortDescendants(items, comparator: comparator)
    }

    func resortDescendants(_ items: [FileItem], comparator: @escaping (FileItem, FileItem) -> Bool) {
        for item in items {
            if var children = item.children {
                children.sort(by: comparator)
                item.children = children
                resortDescendants(children, comparator: comparator)
            }
        }
    }

    func children(of item: FileItem?) -> [FileItem] {
        if let item {
            return item.children ?? []
        }
        return rootItems
    }

    // MARK: - 选中与操作

    var selectedItems: [FileItem] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileItem }
    }

    func notePointerInteraction(row: Int, eventAge: TimeInterval) {
        pointerInteractionGeneration &+= 1
        pointerInteractionPriorityUntil = CFAbsoluteTimeGetCurrent() + PreviewMetrics.pointerInteractionPriorityWindow

        // 鼠标点击已经到达且将改变选择时，先取消还没开始的旧预览上屏任务；
        // 新选择会重新调度预览，这样右侧重绘不会抢在选中高亮之前执行。
        if outlineView.selectedRowIndexes != IndexSet(integer: row) {
            previewUpdateWorkItem?.cancel()
            previewUpdateWorkItem = nil
            selectionPreviewWorkItem?.cancel()
            selectionPreviewWorkItem = nil
        }

        DebugLogger.shared.log(String(format: "[PERF] pointer priority window opened row=%d eventAge=%.1fms gen=%llu",
                                      row, eventAge, pointerInteractionGeneration))
    }

    func enqueuePreviewSurfaceUpdate(
        label: String,
        requestID: UUID,
        item: FileItem?,
        delay minimumDelay: TimeInterval = PreviewMetrics.previewSurfaceUpdateDelay,
        update: @escaping (PreviewViewController) -> Void
    ) {
        previewUpdateWorkItem?.cancel()

        let now = CFAbsoluteTimeGetCurrent()
        let interactionDelay = max(pointerInteractionPriorityUntil - now, 0)
        let delay = max(minimumDelay, interactionDelay)
        let expectedItem = item

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewUpdateWorkItem = nil

            guard self.previewRequestID == requestID else { return }
            if let expectedItem {
                guard self.previewedItem === expectedItem else { return }
            }

            let remainingInteractionDelay = self.pointerInteractionPriorityUntil - CFAbsoluteTimeGetCurrent()
            if remainingInteractionDelay > 0 {
                self.enqueuePreviewSurfaceUpdate(
                    label: label,
                    requestID: requestID,
                    item: expectedItem,
                    delay: remainingInteractionDelay,
                    update: update
                )
                return
            }

            let start = CFAbsoluteTimeGetCurrent()
            update(self)
            DebugLogger.shared.log(String(format: "[PERF] preview surface update %@ ran in %.1fms",
                                          label, (CFAbsoluteTimeGetCurrent() - start) * 1000))
        }

        previewUpdateWorkItem = workItem
        DebugLogger.shared.log(String(format: "[PERF] preview surface update %@ scheduled after %.1fms",
                                      label, delay * 1000))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func actionPaths() -> [String] {
        let selection = selectedItems.map { $0.copyPath }
        if !selection.isEmpty { return selection }
        if let previewedItem {
            return [previewedItem.copyPath]
        }
        return []
    }

    @objc func copyPathAction() {
        let paths = actionPaths()
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(paths as [NSString])
    }

    func showQuickLook() {
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

    lazy var contextMenu: NSMenu = {
        let menu = NSMenu(title: "Actions")
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPathAction), keyEquivalent: "")
        return menu
    }()

    // MARK: - 子节点加载

    func loadChildren(for item: FileItem, completion: @escaping () -> Void) {
        if item.isArchiveEntry {
            completion()
            return
        }
        if item.childrenLoaded {
            completion()
            return
        }
        // 展开文件夹可能访问慢速磁盘或 iCloud 占位文件，因此后台枚举，
        // 主线程只接收最终 children 数组并刷新 UI。
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

    // MARK: - 图标加载

    func loadIcon(for item: FileItem, completion: @escaping (NSImage) -> Void) {
        if let icon = item.icon {
            completion(icon)
            return
        }

        let cacheKey = iconCacheKey(for: item, sizeSuffix: "small")

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

    func loadLargeIcon(for item: FileItem, completion: @escaping (NSImage) -> Void) {
        let cacheKey = iconCacheKey(for: item, sizeSuffix: "large")

        if let cached = iconCache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        let icon = workspaceIcon(for: item, size: NSSize(width: 256, height: 256))
        icon.size = NSSize(width: 256, height: 256)
        iconCache.setObject(icon, forKey: cacheKey)
        completion(icon)
    }

    func workspaceIcon(for item: FileItem, size: NSSize) -> NSImage {
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

    func iconCacheKey(for item: FileItem, sizeSuffix: String) -> NSString {
        // 按类型缓存而不是按完整路径缓存，避免大文件夹中相同扩展名文件反复创建 NSImage。
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

// MARK: - 大纲列表数据源

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

// MARK: - 大纲列表代理

extension PreviewViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        FinderSelectionRowView()
    }

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
            cellView.textField?.stringValue = fileItem.formattedDate(using: dateFormatter)
        case "size":
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            self.sortFileItems(&self.rootItems)
            self.resortDescendants(from: self.rootItems)

            DispatchQueue.main.async {
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
        let t0 = CFAbsoluteTimeGetCurrent()
        outlineView.markSelectionForDisplay(row: outlineView.selectedRow)
        DebugLogger.shared.log(String(format: "[PERF] markSelectionForDisplay scheduled in %.1f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        // 元信息标签立即更新；真正的文件解码/渲染延后到
        // `schedulePreviewWithCurrentSelection`，让大图、Markdown、PDF、iCloud 文件
        // 也不阻塞选中反馈。
        schedulePreviewWithCurrentSelection(after: PreviewMetrics.selectionPreviewDelay)
    }
}

// MARK: - 菜单代理

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

// MARK: - Quick Look 面板

extension PreviewViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookItems.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookItems[index]
    }
}

// MARK: - 大纲列表键盘代理

extension PreviewViewController: FinderOutlineViewKeyboardDelegate {
    func outlineViewWillHandleMouseDown(_ outlineView: FinderOutlineView, row: Int, eventAge: TimeInterval) {
        notePointerInteraction(row: row, eventAge: eventAge)
    }

    func outlineView(_ outlineView: FinderOutlineView, handle event: NSEvent) -> Bool {
        let commandPressed = event.modifierFlags.contains(.command)
        switch (event.keyCode, commandPressed) {
        case (49, false): // 空格
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
