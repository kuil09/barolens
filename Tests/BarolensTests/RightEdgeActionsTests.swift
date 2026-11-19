import AppKit
import Testing
@testable import Barolens

@MainActor private func actionButtons(in view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { actionButtons(in: $0) }
}

@Test @MainActor func actionButtonsLiveAtBodyRightEdgeBelowHeader() throws {
    _ = NSApplication.shared
    let identifiers = Set(["capture", "folder", "record", "lock", "reader", "settings"])
    for width: CGFloat in [320, 400, 800] {
        let panel = BarolensPanel(overlayRect: CGRect(x: 1150, y: 150, width: width, height: 240))
        panel.isReleasedWhenClosed = false
        let controls = BarolensToolbar(onCapture: {}, onRecord: {})
        controls.attach(to: panel)
        panel.installBody(surface: NSView(), size: CGSize(width: width, height: 240))
        panel.setBodyClickThrough(true)
        panel.clampPair(to: CGRect(x: 0, y: 0, width: 1200, height: 900))
        panel.orderFrontRegardless()
        defer { panel.close() }
        let body = try #require(panel.bodyPanel)
        #expect(panel.toolbar == nil)
        #expect(body.frame.maxX <= panel.frame.maxX - 44)
        let buttons = (panel.childWindows ?? []).flatMap { window in
            window.contentView.map { actionButtons(in: $0) } ?? []
        }.filter { identifiers.contains($0.identifier?.rawValue ?? "") }
        #expect(buttons.count == 6)
        #expect(Set(buttons.compactMap { $0.identifier?.rawValue }) == identifiers)
        for button in buttons {
            let window = try #require(button.window)
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            #expect(rect.minX >= body.frame.maxX && rect.maxY <= body.frame.maxY)
            #expect(panel.pairFrame.contains(rect))
            #expect(!window.ignoresMouseEvents && body.ignoresMouseEvents)
            #expect(panel.resizePanels.allSatisfy { !$0.frame.intersects(rect) })
            let content = try #require(window.contentView)
            let hit = content.hitTest(content.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button))
            #expect(hit === button || hit?.isDescendant(of: button) == true)
        }
    }
}

@Test @MainActor func shortRightRailScrollsToSettingsAndRetainsActions() throws {
    _ = NSApplication.shared
    var opened = 0
    let controls = BarolensToolbar(onCapture: {}, onRecord: {}, onSettings: { opened += 1 })
    let rail = try #require(controls.rail)
    rail.frame.size.height = 100
    rail.needsLayout = true; rail.layoutSubtreeIfNeeded()
    let document = try #require(rail.scrollView.documentView)
    #expect(document.bounds.height == 224 && rail.scrollView.contentView.bounds.height <= 100)
    rail.scrollView.contentView.scroll(to: CGPoint(x: 0, y: 124))
    rail.scrollView.reflectScrolledClipView(rail.scrollView.contentView)
    let settings = try #require(controls.buttons["settings"])
    #expect(document.visibleRect.contains(settings.frame))
    settings.performClick(nil)
    #expect(opened == 1)
}

@Test @MainActor func rightRailFollowsResizeMinimizeAndPermissionHandoffWithoutDuplication() throws {
    _ = NSApplication.shared
    let panel = BarolensPanel(overlayRect: CGRect(x: 100, y: 100, width: 400, height: 300))
    panel.isReleasedWhenClosed = false
    let controls = BarolensToolbar(onCapture: {}, onRecord: {})
    controls.attach(to: panel)
    panel.installBody(surface: NSView(), size: CGSize(width: 400, height: 300))
    let actions = try #require(panel.actionPanel), body = try #require(panel.bodyPanel)
    panel.orderFrontRegardless()
    defer { panel.close() }
    #expect(actions.isVisible && actions.parent === panel)
    let childCount = panel.childWindows?.count
    controls.attach(to: panel); panel.orderFrontRegardless()
    #expect(panel.childWindows?.count == childCount)
    panel.resizePair(to: CGRect(x: 100, y: 100, width: 320, height: panel.frame.height + 240))
    #expect(actions.frame.maxX == panel.frame.maxX && actions.frame.maxY == body.frame.maxY)
    panel.setBodyClickThrough(true)
    #expect(body.ignoresMouseEvents && !actions.ignoresMouseEvents)
    panel.miniaturize(nil)
    #expect(!actions.isVisible)
    panel.deminiaturize(nil)
    #expect(actions.isVisible)
    let handoff = BarolensSystemHandoff()
    handoff.begin(window: panel) {}
    panel.orderFrontRegardless()
    #expect(!actions.isVisible)
    handoff.show(window: panel)
    #expect(actions.isVisible && panel.childWindows?.count == childCount)
}
