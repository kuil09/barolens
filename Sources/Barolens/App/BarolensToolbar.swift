import AppKit

struct BarolensToolbarState: Equatable {
    var running = false
    var permissionNeeded = false
    var hasFrame = false
    var recording = false
    var finishing = false
    var choosingDestination = false
    var locked = false
    var captureSucceeded = false

    // Menus and toolbar share eligibility; recording stop must always remain available.
    var canCapture: Bool { hasFrame && !choosingDestination }
    var canToggleRecording: Bool { recording || (!finishing && canCapture) }
}

/// The single vertical action group at the right edge, outside the capture surface.
@MainActor final class BarolensToolbar: NSObject {
    static let actionIdentifiers = ["capture", "folder", "record", "lock", "reader", "settings"]
    private(set) var state = BarolensToolbarState()
    private(set) var buttons: [String: NSButton] = [:]
    private(set) var rail: BarolensActionRail!
    private let onCapture: () -> Void
    private let onRecord: () -> Void
    private let onReader: () -> Void
    private let onSettings: () -> Void
    private let onLock: () -> Void
    private let onOpenFolder: () -> Void

    init(onCapture: @escaping () -> Void, onRecord: @escaping () -> Void,
         onReader: @escaping () -> Void = {}, onSettings: @escaping () -> Void = {}, onLock: @escaping () -> Void = {},
         onOpenFolder: @escaping () -> Void = {}) {
        self.onCapture = onCapture; self.onRecord = onRecord
        self.onReader = onReader; self.onSettings = onSettings
        self.onLock = onLock
        self.onOpenFolder = onOpenFolder
        super.init()
        for identifier in Self.actionIdentifiers {
            let button = NSButton(title: "", target: self, action: #selector(performAction(_:)))
            button.identifier = .init(identifier)
            button.imagePosition = .imageOnly
            button.bezelStyle = .circular
            button.setButtonType(.momentaryPushIn)
            buttons[identifier] = button
        }
        rail = BarolensActionRail(buttons: Self.actionIdentifiers.compactMap { buttons[$0] })
        update(state)
    }

    func attach(to window: BarolensPanel) {
        window.toolbar = nil
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.installActionRail(rail)
        update(state)
    }
    func update(_ state: BarolensToolbarState) {
        self.state = state
        configure("capture", label: L10n.text(state.captureSucceeded ? "Image Saved" : "Capture"),
                  symbol: state.captureSucceeded ? "checkmark" : "camera", enabled: state.canCapture,
                  help: state.captureSucceeded ? L10n.text("Image Saved") : (state.hasFrame ? L10n.text("Save a PNG directly to your chosen folder. ⇧⌘S") : L10n.text("Connect the screen to save an image.")))
        configure("folder", label: L10n.text("Open Save Folder"), symbol: "folder", enabled: true,
                  help: L10n.text("Open Save Folder"))
        configure("record", label: state.recording ? L10n.text("Stop Recording") : (state.finishing ? L10n.text("Saving…") : L10n.text("Start Recording")),
                  symbol: state.recording ? "stop.circle.fill" : (state.finishing ? "arrow.down.circle" : "record.circle"),
                  enabled: state.canToggleRecording,
                  help: state.recording ? L10n.text("Stop and save an MP4 to your chosen folder. ⇧⌘R") :
                    (state.finishing ? L10n.text("Saving video…") :
                        (!state.hasFrame ? L10n.text("Connect the screen to record a video.") : L10n.text("Start recording now. Silent video is saved to your chosen folder. ⇧⌘R"))))
        configure("reader", label: L10n.text("Full Translation"), symbol: "text.alignleft", enabled: true,
                  help: L10n.text("Read and copy full translations. ⌘T"))
        configure("settings", label: L10n.text("Settings"), symbol: "gearshape", enabled: true,
                  help: L10n.text("Set languages and appearance in a separate window. ⌘,"))
        buttons["record"]?.contentTintColor = state.recording ? .systemRed : nil
        configure("lock", label: state.locked ? L10n.text("Turn Off Click-Through") : L10n.text("Pass Through Clicks and Scrolling"), symbol: state.locked ? "cursorarrow.rays" : "cursorarrow", enabled: true,
                  help: L10n.text("Pass Through Clicks and Scrolling"))
        buttons["lock"]?.state = state.locked ? .on : .off
    }
    private func configure(_ key: String, label: String, symbol: String, enabled: Bool, help: String) {
        guard let item = buttons[key] else { return }
        // Circular AppKit buttons can reset their image position when given a title.
        // Keep the localized name for assistive technology, not in the drawn cell.
        item.title = ""
        item.alternateTitle = ""
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.imagePosition = .imageOnly
        item.isEnabled = enabled
        item.toolTip = help
        item.setAccessibilityLabel(label)
    }
    @objc private func performAction(_ item: NSButton) {
        guard item.isEnabled else { return }
        switch item.identifier?.rawValue {
        case "capture": onCapture()
        case "folder": onOpenFolder()
        case "record": onRecord()
        case "reader": onReader()
        case "settings": onSettings()
        case "lock": onLock()
        default: break
        }
    }
}

@MainActor enum BarolensCaptureRegion {
    static func screenRect(surface: NSView, window: NSWindow) -> CGRect {
        surface.layoutSubtreeIfNeeded()
        return window.convertToScreen(surface.convert(surface.bounds, to: nil))
    }
}
