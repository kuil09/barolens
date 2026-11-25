import AppKit
import Testing
@testable import Barolens

@Suite(.serialized) @MainActor struct TranslationMoveTests {
    private func fixture(_ test: (BarolensModel, BarolensPanel, BarolensAppDelegate) throws -> Void) throws {
        _ = NSApplication.shared
        let name = "BarolensMove.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = BarolensModel(defaults: defaults)
        let panel = BarolensPanel(overlayRect: CGRect(x: 100, y: 100, width: 400, height: 300))
        panel.isReleasedWhenClosed = false
        panel.installBody(surface: NSView(), size: CGSize(width: 400, height: 300))
        defer { panel.close() }
        try test(model, panel, BarolensAppDelegate(model: model, overlay: panel))
    }

    @Test func firstStartIntentSurvivesTitleDragWhileLanguagesAreChecking() throws {
        try fixture { model, panel, delegate in
            #expect(model.startRequest.request(.checking) == .wait)
            let notificationDelegate: any NSWindowDelegate = delegate
            notificationDelegate.windowWillMove?(Notification(name: NSWindow.willMoveNotification, object: panel))
            panel.setFrameOrigin(CGPoint(x: 150, y: 400))
            delegate.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
            #expect(model.startRequest.resolve(.ready) == .start)
        }
    }

    @Test func firstStartIntentSurvivesResizeWhileLanguagesAreChecking() throws {
        try fixture { model, panel, delegate in
            #expect(model.startRequest.request(.checking) == .wait)
            delegate.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: panel))
            delegate.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
            #expect(model.startRequest.resolve(.ready) == .start)
        }
    }

    @Test func oldStreamFailureCannotCancelRestartForMovedWindow() throws {
        try fixture { model, _, _ in
            model.begin()
            let original = model.regionVersion
            model.invalidate()
            model.begin()
            let moved = model.regionVersion
            model.capture.onFailure?("Stopped after relocation", original)
            #expect(model.running && model.regionVersion == moved)
            model.capture.onFailure?("Current stream stopped", moved)
            #expect(!model.running && model.regionVersion != moved)
        }
    }

    @Test func titleMouseDownWithoutRelocationDoesNotSuspendTranslation() throws {
        try fixture { model, panel, delegate in
            model.begin()
            let notificationDelegate: any NSWindowDelegate = delegate
            notificationDelegate.windowWillMove?(Notification(name: NSWindow.willMoveNotification, object: panel))
            #expect(model.running)
        }
    }
}
