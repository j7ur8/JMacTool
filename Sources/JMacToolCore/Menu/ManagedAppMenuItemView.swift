import AppKit

/// Managed-app menu row: the app name on the left and the active proxy on a
/// right-aligned column. A custom view (not `attributedTitle`) is required
/// because AppKit drops attributed titles and redraws the plain title when an
/// item is highlighted, which collapsed the proxy column on hover.
@MainActor
final class ManagedAppMenuItemView: NSView {
    private let nameLabel: NSTextField
    private let proxyLabel: NSTextField
    private var isHighlighted = false {
        didSet {
            updateAppearance()
            needsDisplay = true
        }
    }

    init(name: String, proxy: String) {
        nameLabel = NSTextField(labelWithString: name)
        proxyLabel = NSTextField(labelWithString: proxy)
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.menuFont(ofSize: 0)

        proxyLabel.translatesAutoresizingMaskIntoConstraints = false
        proxyLabel.font = NSFont.menuFont(ofSize: 0)

        addSubview(nameLabel)
        addSubview(proxyLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            // NSTextField offsets its frame 2pt left of the constraint, so a
            // 14pt constant puts the text field at x=12 — exactly where
            // native menu items place their titles.
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Same right edge as the Launch at Login checkmark, so every
            // row in the menu shares one right-aligned column.
            proxyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            proxyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: proxyLabel.leadingAnchor, constant: -12)
        ])

        updateAppearance()
    }

    private func updateAppearance() {
        let textColor = isHighlighted ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        nameLabel.textColor = textColor
        proxyLabel.textColor = textColor
    }
}
