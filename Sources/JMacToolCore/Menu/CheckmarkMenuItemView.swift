import AppKit

/// Menu row with a title and an enable checkmark on the far right, shared by
/// the menu toggles (Input Change, Option+IJKL → Arrow Keys, Launch at
/// Login). The checkmark's slot keeps a fixed size whether visible or hidden,
/// so toggling never shifts the layout.
@MainActor
final class CheckmarkMenuItemView: NSView {
    var onClick: (() -> Void)?

    private let titleLabel: NSTextField
    private let checkmarkLabel = NSTextField(labelWithString: "✓")
    private var isHighlighted = false {
        didSet {
            updateAppearance()
            needsDisplay = true
        }
    }

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
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
        checkmarkLabel.isHidden = !isEnabled
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

        // Hidden, not removed: the reserved slot keeps the row width stable
        // when the checkmark appears or disappears.
        checkmarkLabel.translatesAutoresizingMaskIntoConstraints = false
        checkmarkLabel.font = NSFont.menuFont(ofSize: 0)

        addSubview(titleLabel)
        addSubview(checkmarkLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            // NSTextField offsets its frame 2pt left of the constraint, so a
            // 14pt constant puts the text field at x=12 — exactly where
            // native menu items place their titles.
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmarkLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            checkmarkLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmarkLabel.widthAnchor.constraint(equalToConstant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmarkLabel.leadingAnchor, constant: -12)
        ])

        updateAppearance()
    }

    private func updateAppearance() {
        let textColor = isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        titleLabel.textColor = textColor
        checkmarkLabel.textColor = textColor
    }
}
