import AppKit

@MainActor
final class InputChangeMenuItemView: NSView {
    var onClick: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Input Change")
    private let statusDot = NSView()
    private var isHighlighted = false {
        didSet {
            updateAppearance()
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(isEnabled: Bool, toolTip: String) {
        setEnabledState(isEnabled)
        self.toolTip = toolTip
    }

    func setEnabledState(_ isEnabled: Bool) {
        statusDot.layer?.backgroundColor = (isEnabled ? NSColor.systemGreen : NSColor.systemRed).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
    }

    override func mouseDown(with event: NSEvent) {
        isHighlighted = true
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else {
            isHighlighted = false
            return
        }

        isHighlighted = false
        let action = onClick
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async {
            action?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
            dirtyRect.fill()
        }

        super.draw(dirtyRect)
    }

    private func configure() {
        frame = NSRect(x: 0, y: 0, width: 190, height: 24)
        wantsLayer = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.menuFont(ofSize: 0)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.masksToBounds = true

        addSubview(titleLabel)
        addSubview(statusDot)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusDot.leadingAnchor, constant: -12)
        ])

        updateAppearance()
    }

    private func updateAppearance() {
        titleLabel.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
    }
}
