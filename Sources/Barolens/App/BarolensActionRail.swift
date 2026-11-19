import AppKit

/// Own WindowServer region, so locking the captured body never disables these controls.
@MainActor final class BarolensActionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class BarolensActionRail: NSView {
    static let width: CGFloat = 44
    static let gap: CGFloat = 4
    static let preferredHeight: CGFloat = 224
    let scrollView = NSScrollView()
    private let glass = NSGlassEffectView()
    private let column: Column

    init(buttons: [NSButton]) {
        column = Column(buttons: buttons)
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.preferredHeight))
        glass.style = .regular; glass.cornerRadius = 14
        scrollView.drawsBackground = false; scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true; scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = column
        glass.contentView = scrollView
        addSubview(glass)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        glass.frame = bounds; scrollView.frame = glass.bounds
        column.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.preferredHeight)
    }

    @MainActor private final class Column: NSView {
        override var isFlipped: Bool { true }
        init(buttons: [NSButton]) {
            super.init(frame: CGRect(x: 0, y: 0, width: BarolensActionRail.width, height: BarolensActionRail.preferredHeight))
            for (index, button) in buttons.enumerated() {
                button.frame = CGRect(x: 6, y: 6 + CGFloat(index) * 36, width: 32, height: 32)
                addSubview(button)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
