// PeekX - 自定义视图
// Copyright © 2025 ALTIC. All rights reserved.

import Cocoa

enum EventLatency {
    static func uptimeEventAgeMilliseconds(for event: NSEvent) -> TimeInterval {
        (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000
    }

    static func cgEventAgeMilliseconds(for event: NSEvent) -> TimeInterval? {
        guard let timestamp = event.cgEvent?.timestamp else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= timestamp else { return nil }
        return TimeInterval(now - timestamp) / 1_000_000
    }

    static func formattedCGAge(for event: NSEvent) -> String {
        guard let age = cgEventAgeMilliseconds(for: event) else { return "nil" }
        return String(format: "%.1fms", age)
    }
}

// MARK: - 键盘代理协议

protocol FinderOutlineViewKeyboardDelegate: AnyObject {
    func outlineView(_ outlineView: FinderOutlineView, handle event: NSEvent) -> Bool
    func outlineViewWillHandleMouseDown(_ outlineView: FinderOutlineView, row: Int, eventAge: TimeInterval)
}

extension FinderOutlineViewKeyboardDelegate {
    func outlineViewWillHandleMouseDown(_ outlineView: FinderOutlineView, row: Int, eventAge: TimeInterval) {}
}

// MARK: - 自定义大纲列表

final class FinderOutlineView: NSOutlineView {
    weak var keyboardDelegate: FinderOutlineViewKeyboardDelegate?

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let uptime = ProcessInfo.processInfo.systemUptime
        let eventTs = event.timestamp
        let eventAge = EventLatency.uptimeEventAgeMilliseconds(for: event)
        let cgAge = EventLatency.formattedCGAge(for: event)
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 {
            keyboardDelegate?.outlineViewWillHandleMouseDown(self, row: row, eventAge: eventAge)
            // 在 mouseDown 阶段同步选中行，让高亮先于后续较重的预览任务更新。
            let shouldExtend = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: shouldExtend)
            let t1 = CFAbsoluteTimeGetCurrent()
            DebugLogger.shared.log(String(format: "[PERF] mouseDown: eventAge=%.1fms cgAge=%@ code=%.1fms row=%d (uptime=%.1f eventTs=%.1f)",
                                          eventAge, cgAge, (t1 - t0) * 1000, row, uptime, eventTs))
            // 预览任务由 outlineViewSelectionDidChange 调度。
            // 第一响应者延后一拍，避免抢在选中高亮绘制之前触发额外工作。
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
            if frameOfOutlineCell(atRow: row).contains(point) {
                super.mouseDown(with: event)
            }
            return
        }
        super.mouseDown(with: event)
    }

    func markSelectionForDisplay(row: Int? = nil) {
        let t0 = CFAbsoluteTimeGetCurrent()
        // 只标记受影响的行需要重绘，不在这里强制 layout/display。
        // 预览流水线会单独延迟启动，让 AppKit 先完成选中态绘制。
        if let row, row >= 0 {
            setNeedsDisplay(rect(ofRow: row))
            rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
        }
        selectedRowIndexes.forEach { selectedRow in
            setNeedsDisplay(rect(ofRow: selectedRow))
            rowView(atRow: selectedRow, makeIfNecessary: false)?.needsDisplay = true
        }
        DebugLogger.shared.log(String(format: "[PERF] markSelectionForDisplay done in %.1fms",
                                      (CFAbsoluteTimeGetCurrent() - t0) * 1000))
    }

    override func keyDown(with event: NSEvent) {
        if keyboardDelegate?.outlineView(self, handle: event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Finder 风格选中行

final class FinderSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }

        // Finder 列表选中态不是贴边直角矩形，而是在行内留出一点边距并使用小圆角。
        let selectionRect = bounds.insetBy(dx: 2, dy: 1)
        let color: NSColor = isEmphasized
            ? .controlAccentColor
            : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: selectionRect, xRadius: 5, yRadius: 5).fill()
    }
}

// MARK: - 自定义滚动视图

class FinderScrollView: NSScrollView {
    func installTranslucentScrollers() {
        verticalScroller?.alphaValue = 0.58
        horizontalScroller?.alphaValue = 0.58
    }

    static func scrollHorizontally(_ scrollView: NSScrollView, with event: NSEvent) -> Bool {
        let verticalDelta = event.scrollingDeltaY
        guard abs(verticalDelta) > abs(event.scrollingDeltaX) else {
            return false
        }

        // 触控板提供精确 delta；鼠标滚轮悬停在横向滚动条附近时需要更大的倍率才自然。
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

// MARK: - 图片预览视图

final class ImagePreviewView: NSImageView {
    enum RenderMode {
        case centeredIcon
        case fit
        /// 保持原始比例并填满主方向；超出部分保留滚动条查看，不裁切也不拉伸。
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
            // 新图片打开时居中；之后窗口尺寸变化时保留用户当前看到的中心位置。
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

// MARK: - 图片预览滚动视图

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

// MARK: - 预览布局常量

enum PreviewMetrics {
    static let cornerRadius: CGFloat = 12
    static let dividerContentGap: CGFloat = 28
    static let selectionPreviewDelay: TimeInterval = 0.12
    static let pointerInteractionPriorityWindow: TimeInterval = 0.18
    static let previewSurfaceUpdateDelay: TimeInterval = 0.025
}
