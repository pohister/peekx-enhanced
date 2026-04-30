// PeekX - Custom Views
// Copyright © 2025 ALTIC. All rights reserved.

import Cocoa

// MARK: - Keyboard Delegate Protocol

protocol FinderOutlineViewKeyboardDelegate: AnyObject {
    func outlineView(_ outlineView: FinderOutlineView, handle event: NSEvent) -> Bool
}

// MARK: - Custom Outline View

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
            // Defer first-responder so the selection highlight renders first
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

// MARK: - Custom Scroller

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
        super.draw(dirtyRect)
    }
}

// MARK: - Custom Scroll View

class FinderScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if Self.scrollHorizontallyIfNeeded(self, with: event) {
            return
        }

        super.scrollWheel(with: event)
    }

    func installTranslucentScrollers() {
        verticalScroller?.alphaValue = 0.58
        horizontalScroller?.alphaValue = 0.58
    }

    static func scrollHorizontallyIfNeeded(_ scrollView: NSScrollView, with event: NSEvent) -> Bool {
        let point = scrollView.convert(event.locationInWindow, from: nil)
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

// MARK: - Image Preview View

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

// MARK: - Image Preview Scroll View

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

// MARK: - Preview Metrics

enum PreviewMetrics {
    static let cornerRadius: CGFloat = 12
    static let dividerContentGap: CGFloat = 28
}
