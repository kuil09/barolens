import AppKit
import Testing
@testable import Barolens

@Test @MainActor func recordingLocksGeometryButKeepsControlsAndSecurityHide() throws {
    _ = NSApplication.shared
    let overlay = BarolensPanel(overlayRect: CGRect(x: 100, y: 100, width: 600, height: 400))
    overlay.isReleasedWhenClosed = false
    overlay.installBody(surface: NSView(), size: CGSize(width: 600, height: 400))
    defer { overlay.close() }
    overlay.setBodyClickThrough(true)
    overlay.orderFrontRegardless()
    let original = overlay.pairFrame
    var arrangements = 0
    overlay.onBodyArrangement = { _ in arrangements += 1 }
    overlay.setRecordingGeometryLocked(true)
    overlay.setRecordingGeometryLocked(true)
    #expect(!overlay.isMovable && !overlay.styleMask.contains(.resizable))
    #expect(overlay.bodyPanel?.styleMask.contains(.resizable) == false)
    #expect(!overlay.ignoresMouseEvents && overlay.bodyPanel?.ignoresMouseEvents == true)
    #expect(overlay.standardWindowButton(.zoomButton)?.isEnabled == false)
    overlay.beginEdgeResize()
    overlay.resizePair(to: original.insetBy(dx: -50, dy: -50))
    overlay.zoom(nil)
    overlay.endEdgeResize()
    #expect(overlay.pairFrame == original && arrangements == 0 && !overlay.edgeResizing)
    overlay.interactionSuspended = true
    overlay.orderOut(nil)
    #expect(overlay.resizePanels.allSatisfy { !$0.isVisible })
    #expect(overlay.bodyPanel?.isVisible == false)
    overlay.setRecordingGeometryLocked(false)
    #expect(overlay.isMovable && overlay.styleMask.contains(.resizable))
    #expect(overlay.bodyPanel?.styleMask.contains(.resizable) == true)
    overlay.interactionSuspended = false
    overlay.resizePair(to: original.insetBy(dx: -20, dy: -20))
    #expect(overlay.pairFrame != original)
}
@Test @MainActor func roundedResizeCornersStayContinuousAcrossInputStrips() throws {
    _ = NSApplication.shared
    let pair = CGRect(x: 24, y: 24, width: 400, height: 300)
    let contour = BarolensResizeChrome.path(around: pair)
    #expect((0..<contour.elementCount).filter {
        contour.element(at: $0, associatedPoints: nil) == .curveTo
    }.count == 4)
    #expect(contour.lineCapStyle == .round && contour.lineJoinStyle == .round)
    #expect(BarolensResizeChrome.outset + BarolensResizeChrome.outlineWidth / 2 < BarolensResizeGeometry.thickness)

    let overlay = BarolensPanel(overlayRect: pair)
    overlay.isReleasedWhenClosed = false
    overlay.installBody(surface: NSView(), size: CGSize(width: 400, height: 260))
    overlay.resizePair(to: pair)
    defer { overlay.close() }
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("BarolensDesignRenders", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    for scale in [CGFloat(1), CGFloat(2)] {
        func render(strips: Bool, dark: Bool? = nil) throws -> (CGImage, [UInt8]) {
            let width = Int(448 * scale), height = Int(348 * scale)
            let context = try #require(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            if let dark {
                NSColor(white: dark ? 0.09 : 0.94, alpha: 1).setFill()
                NSBezierPath(rect: CGRect(x: 0, y: 0, width: 448, height: 348)).fill()
                NSColor(white: dark ? 0.18 : 1, alpha: 1).setFill()
                NSBezierPath(roundedRect: pair, xRadius: 18, yRadius: 18).fill()
                ("Barolens" as NSString).draw(at: CGPoint(x: 50, y: 283), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                    .foregroundColor: dark ? NSColor.white : NSColor.black])
            }
            if strips {
                for panel in overlay.resizePanels {
                    let view = try #require(panel.contentView)
                    context.saveGState()
                    context.clip(to: panel.frame)
                    context.translateBy(x: panel.frame.minX, y: panel.frame.minY)
                    view.draw(view.bounds)
                    context.restoreGState()
                }
            } else { BarolensResizeChrome.draw(around: pair, recording: overlay.recordingGeometryLocked) }
            let data = try #require(context.data)
            return (try #require(context.makeImage()), Array(UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)))
        }
        let (_, continuous) = try render(strips: false)
        let (_, split) = try render(strips: true)
        // Rendering into four separate native views must not cut the curve or its stroke.
        #expect(zip(continuous, split).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        for dark in [false, true] {
            let (image, _) = try render(strips: true, dark: dark)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("resize-corners-\(dark ? "dark" : "light")-\(Int(scale))x.png"))
        }
        overlay.setRecordingGeometryLocked(true)
        let (_, recordingContinuous) = try render(strips: false)
        let (_, recordingSplit) = try render(strips: true)
        #expect(zip(recordingContinuous, recordingSplit).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
        #expect(recordingSplit != split)
        for dark in [false, true] {
            let (image, _) = try render(strips: true, dark: dark)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("recording-outline-\(dark ? "dark" : "light")-\(Int(scale))x.png"))
        }
        overlay.setRecordingGeometryLocked(false)
    }
}

@Test func resizeRingDoesNotCatchBodyOrHeaderAndHasDirectionalCorners() {
    let pair = CGRect(x: -600, y: 100, width: 500, height: 400)
    let panels = BarolensResizeSide.allCases.map { BarolensResizeGeometry.frame(side: $0, pair: pair) }
    for (index, frame) in panels.enumerated() {
        #expect(!frame.intersects(pair))
        for other in panels.dropFirst(index + 1) { #expect(!frame.intersects(other)) }
    }
    #expect(BarolensResizeGeometry.direction(side: .left, point: CGPoint(x: -604, y: 498), pair: pair) == [.left, .top])
    #expect(BarolensResizeGeometry.direction(side: .bottom, point: CGPoint(x: -104, y: 96), pair: pair) == [.right, .bottom])
    #expect(BarolensResizeGeometry.direction(side: .right, point: CGPoint(x: -96, y: 300), pair: pair) == .right)
}

@Test func resizeHonorsAnchorsMinimumAndDisplayBoundary() {
    let initial = CGRect(x: 100, y: 100, width: 600, height: 400)
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
    let minimum = CGSize(width: 320, height: 300)
    let shrink = BarolensResizeGeometry.resized(initial, delta: CGPoint(x: 500, y: 500), direction: [.bottom, .left], minimum: minimum, screen: screen)
    #expect(shrink.maxX == initial.maxX && shrink.maxY == initial.maxY)
    #expect(shrink.size == minimum)
    let grow = BarolensResizeGeometry.resized(initial, delta: CGPoint(x: 2000, y: 2000), direction: [.top, .right], minimum: minimum, screen: screen)
    #expect(grow.maxX == screen.maxX - 8 && grow.maxY == screen.maxY - 8)
}

@Test @MainActor func resizePanelsMoveHideAndSuspendWithBarolens() throws {
    _ = NSApplication.shared
    let overlay = BarolensPanel(overlayRect: CGRect(x: 100, y: 100, width: 600, height: 400))
    overlay.isReleasedWhenClosed = false
    overlay.installBody(surface: NSView(), size: CGSize(width: 600, height: 400))
    let handoff = BarolensSystemHandoff()
    handoff.show(window: overlay); overlay.setBodyClickThrough(true)
    defer { overlay.close() }
    #expect(overlay.resizePanels.count == 4)
    #expect(overlay.resizePanels.allSatisfy { $0.isVisible && !$0.ignoresMouseEvents && !$0.canBecomeKey })
    var events: [Bool] = []
    overlay.onBodyArrangement = { events.append($0) }
    overlay.beginEdgeResize()
    overlay.resizePair(to: CGRect(x: 150, y: 120, width: 500, height: 400))
    overlay.endEdgeResize()
    #expect(events == [false, true])
    for panel in overlay.resizePanels { #expect(panel.frame == BarolensResizeGeometry.frame(side: panel.side, pair: overlay.pairFrame)) }
    #expect(overlay.bodyPanel?.ignoresMouseEvents == true)
    handoff.begin(window: overlay) {}
    #expect(overlay.resizePanels.allSatisfy { !$0.isVisible })
    handoff.show(window: overlay)
    #expect(overlay.resizePanels.allSatisfy { $0.isVisible })
    overlay.close()
    #expect(overlay.resizePanels.allSatisfy { !$0.isVisible })
}
