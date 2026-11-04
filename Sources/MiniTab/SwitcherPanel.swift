import Cocoa
import QuartzCore

/// The switcher UI in plain AppKit + Core Animation (no SwiftUI).
/// Cell layers are reused between opens, and moving the selection only moves one layer,
/// so holding Tab costs almost nothing.
@MainActor
final class SwitcherPanel {
    var onPick: (Int) -> Void = { _ in }
    var onClose: (Int) -> Void = { _ in }
    /// The mouse moved onto another tile: the selection should follow it.
    var onHover: (Int) -> Void = { _ in }
    private(set) var isVisible = false
    /// Pixel size of one thumbnail slot on the current screen (what ScreenCaptureKit should produce).
    private(set) var thumbnailPixelSize = CGSize(width: 400, height: 260)

    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let canvas = CanvasView()
    private let selection = CALayer()
    private let searchBar = CALayer()
    private let searchText = CATextLayer()
    private let emptyText = CATextLayer()
    private let quitOverlay = CALayer()
    private let quitText = CATextLayer()
    private let quitBar = CALayer()
    private var cells: [Cell] = []
    private var cellFrames: [CGRect] = []
    private var windowIDs: [CGWindowID] = []
    private var iconsOnly = false
    private var selectedIndex = 0
    private var hoveredIndex: Int?
    private var hoveringClose = false
    /// Where the mouse was when the panel opened. Hover only takes over the selection after a
    /// real movement, so a cursor that happens to rest on a tile doesn't hijack a quick ⌥Tab.
    private var mouseAtOpen: CGPoint?

    private static let spacing: CGFloat = 10
    private static let padding: CGFloat = 16
    private static let searchBarHeight: CGFloat = 30
    private static let emptyHeight: CGFloat = 40
    private static let thumbnailCell = CGSize(width: 220, height: 170)
    private static let iconCell = CGSize(width: 132, height: 120)
    private static let maxColumns = 6

    init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.acceptsMouseMovedEvents = true
        // Keep the switcher (thumbnails + titles of every window) out of screen sharing
        // and recordings made by other apps.
        panel.sharingType = .none

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: 18) // cheaper than cornerRadius + masksToBounds
        panel.contentView = background

        canvas.layer = CALayer() // set before wantsLayer => layer-hosting: we own the layer tree
        canvas.wantsLayer = true
        canvas.onClick = { [weak self] point in self?.click(at: point) }
        canvas.onMove = { [weak self] point in self?.mouseMoved(to: point, byUser: true) }
        background.addSubview(canvas)

        selection.cornerRadius = 12
        selection.borderWidth = 2

        searchBar.cornerRadius = 8
        searchBar.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        searchText.font = NSFont.systemFont(ofSize: 14)
        searchText.fontSize = 14
        searchText.truncationMode = .start
        searchText.isWrapped = false

        emptyText.font = NSFont.systemFont(ofSize: 13)
        emptyText.fontSize = 13
        emptyText.alignmentMode = .center
        emptyText.foregroundColor = NSColor.white.withAlphaComponent(0.6).cgColor
        emptyText.string = "No matching windows"

        for layer in [selection, searchBar, searchText, emptyText] as [CALayer] {
            layer.isHidden = true
            canvas.layer?.addSublayer(layer)
        }

        quitOverlay.cornerRadius = 12
        quitOverlay.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        quitOverlay.zPosition = 10 // above the tiles
        quitOverlay.isHidden = true
        quitText.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        quitText.fontSize = 12
        quitText.foregroundColor = NSColor.white.cgColor
        quitText.alignmentMode = .center
        quitText.isWrapped = true
        quitBar.backgroundColor = NSColor.systemRed.cgColor
        quitBar.cornerRadius = 2
        quitBar.anchorPoint = CGPoint(x: 0, y: 0.5) // grows from the left
        quitOverlay.addSublayer(quitText)
        quitOverlay.addSublayer(quitBar)
        canvas.layer?.addSublayer(quitOverlay)
    }

    /// "Keep holding Q" overlay with a progress bar on one tile.
    func showQuitHold(at index: Int, appName: String, duration: TimeInterval) {
        guard isVisible, cellFrames.indices.contains(index) else { return }
        let frame = cellFrames[index]
        let barWidth = max(frame.width - 24, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        quitOverlay.frame = frame
        quitText.frame = CGRect(x: 8, y: frame.height / 2 - 12, width: frame.width - 16, height: 34)
        quitText.contentsScale = panel.backingScaleFactor
        quitText.string = "Hold Q to quit \(appName)"
        quitBar.frame = CGRect(x: 12, y: 14, width: barWidth, height: 4)
        quitOverlay.isHidden = false
        CATransaction.commit()

        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = 0
        grow.toValue = barWidth
        grow.duration = duration
        quitBar.add(grow, forKey: "progress")
    }

    func hideQuitHold() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        quitBar.removeAllAnimations()
        quitOverlay.isHidden = true
        CATransaction.commit()
    }

    /// Draws (or redraws) the switcher. `searchQuery == nil` means search mode is off.
    func show(_ windows: [WindowInfo], selected: Int, thumbnails: [CGWindowID: CGImage],
              iconsOnly: Bool, searchQuery: String?, on screen: NSScreen) {
        self.iconsOnly = iconsOnly
        let count = windows.count
        let searching = searchQuery != nil
        let base = iconsOnly ? Self.iconCell : Self.thumbnailCell
        let columns = max(min(count, Self.maxColumns), 1)
        let rows = count == 0 ? 0 : (count + columns - 1) / columns
        let header = searching ? Self.searchBarHeight + Self.spacing : 0

        func gridWidth(_ cell: CGSize) -> CGFloat {
            CGFloat(columns) * cell.width + CGFloat(columns - 1) * Self.spacing
        }
        func layoutSize(_ cell: CGSize) -> CGSize {
            let gridHeight = rows == 0 ? Self.emptyHeight
                : CGFloat(rows) * cell.height + CGFloat(rows - 1) * Self.spacing
            return CGSize(width: max(gridWidth(cell), searching ? 320 : 0) + 2 * Self.padding,
                          height: gridHeight + header + 2 * Self.padding)
        }

        let visible = screen.visibleFrame
        let full = layoutSize(base)
        let fit = min(1, visible.width * 0.9 / full.width, visible.height * 0.85 / full.height)
        let cell = CGSize(width: floor(base.width * fit), height: floor(base.height * fit))
        let size = layoutSize(cell)
        let scale = screen.backingScaleFactor

        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        canvas.frame = background.bounds

        let gridX = (size.width - gridWidth(cell)) / 2
        let gridTop = size.height - Self.padding - header
        cellFrames = (0..<count).map { i in
            let row = i / columns, column = i % columns
            return CGRect(x: gridX + CGFloat(column) * (cell.width + Self.spacing),
                          y: gridTop - CGFloat(row + 1) * cell.height - CGFloat(row) * Self.spacing,
                          width: cell.width, height: cell.height)
        }
        windowIDs = windows.map(\.id)

        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit animations = no extra frames

        searchBar.isHidden = !searching
        searchText.isHidden = !searching
        if let searchQuery {
            let barFrame = CGRect(x: Self.padding, y: size.height - Self.padding - Self.searchBarHeight,
                                  width: size.width - 2 * Self.padding, height: Self.searchBarHeight)
            searchBar.frame = barFrame
            searchText.frame = barFrame.insetBy(dx: 10, dy: 6)
            searchText.contentsScale = scale
            searchText.string = searchQuery.isEmpty ? "Type to search…" : searchQuery
            searchText.foregroundColor = NSColor.white.withAlphaComponent(searchQuery.isEmpty ? 0.45 : 0.95).cgColor
        }

        emptyText.isHidden = count != 0
        if count == 0 {
            emptyText.frame = CGRect(x: Self.padding, y: Self.padding + 10,
                                     width: size.width - 2 * Self.padding, height: 20)
            emptyText.contentsScale = scale
        }

        while cells.count < count {
            let newCell = Cell()
            canvas.layer?.addSublayer(newCell.root)
            cells.append(newCell)
        }
        for (i, c) in cells.enumerated() {
            if i < count {
                c.root.isHidden = false
                c.configure(window: windows[i], thumbnail: thumbnails[windows[i].id],
                            iconsOnly: iconsOnly, frame: cellFrames[i], scale: scale)
            } else {
                c.root.isHidden = true
                c.clear()
            }
        }

        let accent = NSColor.controlAccentColor
        selection.backgroundColor = accent.withAlphaComponent(0.3).cgColor
        selection.borderColor = accent.cgColor
        selection.isHidden = count == 0
        hoveredIndex = nil
        hoveringClose = false
        moveSelection(to: selected)
        CATransaction.commit()

        let slot = Cell.thumbnailFrame(in: cell).size
        thumbnailPixelSize = CGSize(width: slot.width * scale, height: slot.height * scale)

        panel.invalidateShadow()
        if !isVisible {
            panel.orderFrontRegardless()
            isVisible = true
            mouseAtOpen = NSEvent.mouseLocation
        }
        // The mouse may already be resting on a tile: show its close button right away.
        mouseMoved(to: canvas.convert(panel.mouseLocationOutsideOfEventStream, from: nil), byUser: false)
    }

    func select(_ index: Int) {
        guard isVisible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        moveSelection(to: index)
        CATransaction.commit()
    }

    func setThumbnails(_ images: [CGWindowID: CGImage]) {
        guard isVisible, !iconsOnly else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, id) in windowIDs.enumerated() where i < cells.count {
            if let image = images[id] { cells[i].setThumbnail(image) }
        }
        CATransaction.commit()
    }

    func hide() {
        hideQuitHold()
        mouseAtOpen = nil
        panel.orderOut(nil)
        isVisible = false
    }

    // MARK: - Private

    private func moveSelection(to index: Int) {
        guard cellFrames.indices.contains(index) else { return }
        selectedIndex = index
        selection.frame = cellFrames[index]
        updateCloseButtons()
    }

    private func mouseHasMovedSinceOpen() -> Bool {
        guard let start = mouseAtOpen else { return true }
        let now = NSEvent.mouseLocation
        if hypot(now.x - start.x, now.y - start.y) < 4 { return false }
        mouseAtOpen = nil // moved enough: stop checking
        return true
    }

    private func click(at point: CGPoint) {
        guard let index = cellFrames.firstIndex(where: { $0.contains(point) }), index < cells.count else { return }
        if cells[index].isCloseVisible && cells[index].closeHitFrame(in: cellFrames[index]).contains(point) {
            onClose(index)
        } else {
            onPick(index)
        }
    }

    /// Hover tracking: only touches layers when the hovered tile (or close button) changes.
    private func mouseMoved(to point: CGPoint?, byUser: Bool) {
        var index: Int?
        var overClose = false
        if let point, let i = cellFrames.firstIndex(where: { $0.contains(point) }), i < cells.count {
            index = i
            overClose = cells[i].closeHitFrame(in: cellFrames[i]).contains(point)
        }

        // Selection follows the mouse, once it has really moved since the panel opened.
        if byUser, let index, index != selectedIndex, mouseHasMovedSinceOpen() {
            onHover(index) // the app updates its state and calls select(), which moves the highlight
        }

        guard index != hoveredIndex || overClose != hoveringClose else { return }
        hoveredIndex = index
        hoveringClose = overClose
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateCloseButtons()
        CATransaction.commit()
    }

    /// The close button shows on the selected tile and on the tile under the mouse.
    private func updateCloseButtons() {
        for i in cellFrames.indices where i < cells.count {
            let visible = i == selectedIndex || i == hoveredIndex
            cells[i].setCloseButton(visible: visible, highlighted: visible && hoveringClose && i == hoveredIndex)
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// One window tile: thumbnail (or app icon), small icon, title.
@MainActor
private final class Cell {
    let root = CALayer()
    private let thumb = CALayer()
    private let bigIcon = CALayer()
    private let smallIcon = CALayer()
    private let title = CATextLayer()
    private let closeButton = CALayer()
    private let closeGlyph = CAShapeLayer()

    private static let inset: CGFloat = 8
    private static let closeSize: CGFloat = 20
    private static let titleHeight: CGFloat = 16
    private static let gap: CGFloat = 6

    static func thumbnailFrame(in size: CGSize) -> CGRect {
        let y = inset + titleHeight + gap
        return CGRect(x: inset, y: y, width: max(size.width - 2 * inset, 1), height: max(size.height - y - inset, 1))
    }

    init() {
        thumb.contentsGravity = .resizeAspect
        bigIcon.contentsGravity = .resizeAspect
        smallIcon.contentsGravity = .resizeAspect
        title.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        title.fontSize = 12
        title.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        title.truncationMode = .middle
        title.isWrapped = false
        closeButton.cornerRadius = Self.closeSize / 2
        closeButton.borderWidth = 0.5
        closeButton.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        closeButton.isHidden = true
        closeGlyph.frame = CGRect(x: 0, y: 0, width: Self.closeSize, height: Self.closeSize)
        let glyph = CGMutablePath()
        let a: CGFloat = 6.5, b = Self.closeSize - 6.5
        glyph.move(to: CGPoint(x: a, y: a)); glyph.addLine(to: CGPoint(x: b, y: b))
        glyph.move(to: CGPoint(x: b, y: a)); glyph.addLine(to: CGPoint(x: a, y: b))
        closeGlyph.path = glyph
        closeGlyph.strokeColor = NSColor.white.cgColor
        closeGlyph.lineWidth = 1.8
        closeGlyph.lineCap = .round
        closeButton.addSublayer(closeGlyph)

        for layer in [thumb, bigIcon, smallIcon, title, closeButton] as [CALayer] {
            root.addSublayer(layer)
        }
    }

    var isCloseVisible: Bool { !closeButton.isHidden }

    /// Close button rect in canvas coordinates, with a few points of extra hit area.
    func closeHitFrame(in cellFrame: CGRect) -> CGRect {
        closeButton.frame.offsetBy(dx: cellFrame.minX, dy: cellFrame.minY).insetBy(dx: -4, dy: -4)
    }

    func setCloseButton(visible: Bool, highlighted: Bool) {
        closeButton.isHidden = !visible
        closeButton.backgroundColor = (highlighted ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.6)).cgColor
    }

    func configure(window: WindowInfo, thumbnail: CGImage?, iconsOnly: Bool, frame: CGRect, scale: CGFloat) {
        root.frame = frame
        root.opacity = window.state == .normal ? 1 : 0.6 // dim minimized / hidden

        let slot = Self.thumbnailFrame(in: frame.size)
        thumb.frame = slot
        thumb.isHidden = iconsOnly
        thumb.contents = iconsOnly ? nil : thumbnail

        let side = iconsOnly ? min(72, slot.height * 0.85, slot.width * 0.85) : min(56, slot.height * 0.6)
        bigIcon.frame = CGRect(x: slot.midX - side / 2, y: slot.midY - side / 2, width: side, height: side)
        bigIcon.contents = window.icon
        bigIcon.opacity = iconsOnly ? 1 : 0.7
        bigIcon.isHidden = !iconsOnly && thumbnail != nil

        smallIcon.isHidden = iconsOnly
        smallIcon.frame = CGRect(x: Self.inset, y: Self.inset, width: Self.titleHeight, height: Self.titleHeight)
        smallIcon.contents = iconsOnly ? nil : window.icon

        let titleX = iconsOnly ? Self.inset : Self.inset + Self.titleHeight + Self.gap
        title.frame = CGRect(x: titleX, y: Self.inset - 1,
                             width: max(frame.width - titleX - Self.inset, 1), height: Self.titleHeight)
        title.alignmentMode = iconsOnly ? .center : .left
        title.contentsScale = scale
        title.string = window.label

        // Top-right corner of the tile, slightly overlapping the thumbnail edge.
        closeButton.frame = CGRect(x: slot.maxX - Self.closeSize + 4, y: slot.maxY - Self.closeSize + 4,
                                   width: Self.closeSize, height: Self.closeSize)
        closeButton.contentsScale = scale
        closeGlyph.contentsScale = scale
    }

    func setThumbnail(_ image: CGImage) {
        thumb.contents = image
        bigIcon.isHidden = true
    }

    func clear() {
        closeButton.isHidden = true
        thumb.contents = nil
        bigIcon.contents = nil
        smallIcon.contents = nil
    }
}

private final class CanvasView: NSView {
    var onClick: (CGPoint) -> Void = { _ in }
    var onMove: (CGPoint?) -> Void = { _ in }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { onMove(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onMove(nil) }
    override func mouseDown(with event: NSEvent) {
        onClick(convert(event.locationInWindow, from: nil))
    }
}
