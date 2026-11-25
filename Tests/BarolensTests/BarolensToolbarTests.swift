import AppKit
import Testing
@testable import Barolens

@Test func languagePairStaysSymmetricAndClearOfTranslationSwitch() {
    for windowWidth: CGFloat in [320, 400, 520, 540, 600, 800, 1200] {
        let available = windowWidth - 24 - 28 // Glass inset and content padding.
        let layout = BarolensLanguageBarLayout(width: available)
        let left = layout.pairCenter - layout.pairWidth / 2
        let right = layout.pairCenter + layout.pairWidth / 2
        let sourceCenter = left + layout.fieldWidth / 2
        let targetCenter = right - layout.fieldWidth / 2
        #expect(abs((layout.pairCenter - sourceCenter) - (targetCenter - layout.pairCenter)) < 0.01)
        #expect(left >= 0 && right <= available - 60)
        #expect(layout.fieldWidth >= 82)
        if available >= 480 { #expect(layout.pairCenter == available / 2) }
    }
}

@Test @MainActor func rightRailActionsFollowCaptureRecordingAndLockState() throws {
    _ = NSApplication.shared
    var actions: [String] = []
    let controls = BarolensToolbar(onCapture: { actions.append("capture") }, onRecord: { actions.append("record") },
        onReader: { actions.append("reader") }, onSettings: { actions.append("settings") },
        onLock: { actions.append("lock") }, onOpenFolder: { actions.append("folder") })
    let capture = try #require(controls.buttons["capture"]), record = try #require(controls.buttons["record"])
    #expect(!capture.isEnabled && !record.isEnabled)
    controls.update(.init(running: true, hasFrame: true))
    capture.performClick(nil); record.performClick(nil)
    #expect(actions == ["capture", "record"])
    controls.update(.init(recording: true, choosingDestination: true, locked: true))
    #expect(record.isEnabled && record.accessibilityLabel() == L10n.text("Stop Recording"))
    #expect(record.contentTintColor == .systemRed && !capture.isEnabled)
    #expect(controls.buttons["lock"]?.state == .on)
    record.performClick(nil)
    #expect(actions.last == "record")
    controls.update(.init(hasFrame: true, finishing: true, locked: true))
    #expect(!record.isEnabled && record.accessibilityLabel() == L10n.text("Saving…"))
    #expect(record.contentTintColor == nil)
    for key in ["folder", "lock", "reader", "settings"] {
        let button = try #require(controls.buttons[key])
        #expect(button.isEnabled)
        button.performClick(nil)
        #expect(actions.last == key)
    }
    controls.update(.init(hasFrame: true))
    #expect(controls.buttons.values.allSatisfy { $0.isEnabled })
    #expect(controls.buttons["lock"]?.state == .off)
}

@Test @MainActor func rightRailAndLanguageControlsStayOutsideCaptureAtAnyWindowSize() throws {
    _ = NSApplication.shared
    let panel = BarolensPanel(overlayRect: CGRect(x: 180, y: 130, width: 800, height: 500))
    panel.isReleasedWhenClosed = false
    defer { panel.close() }
    let controls = BarolensToolbar(onCapture: {}, onRecord: {})
    controls.attach(to: panel)
    let languageBar = BarolensLanguageBarController(model: BarolensModel(), onToggle: {})
    panel.addTitlebarAccessoryViewController(languageBar)
    let surface = NSView()
    panel.installBody(surface: surface, size: CGSize(width: 800, height: 500))
    let body = try #require(panel.bodyPanel), actions = try #require(panel.actionPanel)
    for size in [CGSize(width: 800, height: 500), CGSize(width: 320, height: 240)] {
        panel.resizePair(to: CGRect(x: 180, y: 130, width: size.width, height: size.height + panel.frame.height))
        let rect = BarolensCaptureRegion.screenRect(surface: surface, window: body)
        #expect(rect == body.frame && rect.height == size.height && rect.width == size.width - 48)
        #expect(!rect.intersects(actions.frame) && actions.frame.maxY == body.frame.maxY)
        let languageRect = panel.convertToScreen(languageBar.view.convert(languageBar.view.bounds, to: nil))
        #expect(languageRect.minY >= rect.maxY - 1)
        #expect(languageBar.view.bounds.height >= 80)
        #expect(panel.toolbar == nil && !surface.subviews.contains { $0 is NSButton })
    }
}

@Test @MainActor func rightRailCaptureSuccessPreservesActionEligibility() throws {
    let controls = BarolensToolbar(onCapture: {}, onRecord: {})
    let capture = try #require(controls.buttons["capture"]), record = try #require(controls.buttons["record"])
    let camera = try #require(capture.image?.tiffRepresentation)
    for recording in [false, true] {
        for finishing in [false, true] {
            for hasFrame in [false, true] {
                for choosingDestination in [false, true] {
                    var state = BarolensToolbarState(hasFrame: hasFrame, recording: recording, finishing: finishing,
                        choosingDestination: choosingDestination, locked: true)
                    controls.update(state)
                    let recordEnabled = record.isEnabled, title = record.accessibilityLabel()
                    state.captureSucceeded = true
                    controls.update(state)
                    #expect(capture.accessibilityLabel() == L10n.text("Image Saved"))
                    #expect(capture.image?.tiffRepresentation != camera)
                    #expect(capture.isEnabled == (hasFrame && !choosingDestination))
                    #expect(record.isEnabled == recordEnabled && record.accessibilityLabel() == title)
                    #expect(controls.buttons["folder"]?.isEnabled == true && controls.buttons["lock"]?.isEnabled == true)
                }
            }
        }
    }
    controls.update(.init(hasFrame: true))
    #expect(capture.accessibilityLabel() == L10n.text("Capture") && capture.image?.tiffRepresentation == camera)
}

@Test @MainActor func rightRailRecordingTooltipExplainsUnavailableAndSavingStates() {
    let controls = BarolensToolbar(onCapture: {}, onRecord: {})
    #expect(controls.buttons["record"]?.toolTip == L10n.text("Connect the screen to record a video."))
    controls.update(.init(finishing: true))
    #expect(controls.buttons["record"]?.toolTip == L10n.text("Saving video…"))
    #expect(controls.buttons["record"]?.isEnabled == false)
}

@Test @MainActor func rightRailUsesIconsWithoutVisibleTitlesAndKeepsAccessibilityNames() throws {
    _ = NSApplication.shared
    let controls = BarolensToolbar(onCapture: {}, onRecord: {})
    for state in [
        BarolensToolbarState(),
        .init(hasFrame: true, recording: true, locked: true),
        .init(hasFrame: true, finishing: true, captureSucceeded: true)
    ] {
        controls.update(state)
        for key in BarolensToolbar.actionIdentifiers {
            let button = try #require(controls.buttons[key])
            #expect(button.title.isEmpty, "(key) must not draw text over its icon")
            #expect(button.alternateTitle.isEmpty)
            #expect(button.imagePosition == .imageOnly)
            #expect(button.image != nil)
            #expect(button.accessibilityLabel()?.isEmpty == false)
            #expect(button.toolTip?.isEmpty == false)
        }
    }
    #expect(controls.buttons["capture"]?.accessibilityLabel() == L10n.text("Image Saved"))
    #expect(controls.buttons["settings"]?.accessibilityLabel() == L10n.text("Settings"))
}
