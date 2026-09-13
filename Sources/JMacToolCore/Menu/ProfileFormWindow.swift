import AppKit

/// Centered form window used to create and edit proxy profiles, mirroring the
/// tray GUI of the original jpmanager.
@MainActor
final class ProfileFormWindow: NSWindow, NSWindowDelegate {
    struct Fields {
        var name: String
        var httpProxy: String
        var httpsProxy: String
        var socks5Proxy: String
        var noProxy: String
    }

    private let nameField = NSTextField()
    private let httpField = NSTextField()
    private let httpsField = NSTextField()
    private let socks5Field = NSTextField()
    private let noProxyField = NSTextField()
    private let onSave: (Fields) -> Void

    init(existing: Fields?, onSave: @escaping (Fields) -> Void) {
        self.onSave = onSave

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = existing == nil ? "Add Proxy Profile" : "Edit Proxy Profile"
        delegate = self
        isReleasedWhenClosed = false
        center()
        buildForm(existing: existing)
    }

    private func buildForm(existing: Fields?) {
        nameField.stringValue = existing?.name ?? ""
        httpField.stringValue = existing?.httpProxy ?? ""
        httpsField.stringValue = existing?.httpsProxy ?? ""
        socks5Field.stringValue = existing?.socks5Proxy ?? ""
        noProxyField.stringValue = existing?.noProxy ?? ""

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12

        func addRow(_ label: String, _ field: NSTextField) {
            let labelText = NSTextField(labelWithString: label)
            grid.addRow(with: [labelText, field])
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }

        addRow("Name", nameField)
        addRow("http_proxy", httpField)
        addRow("https_proxy", httpsField)
        addRow("socks5_proxy", socks5Field)
        addRow("no_proxy", noProxyField)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(savePressed))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(grid)
        container.addSubview(buttons)
        contentView = container

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        ])
    }

    @objc private func savePressed() {
        onSave(Fields(
            name: nameField.stringValue.trimmingCharacters(in: .whitespaces),
            httpProxy: httpField.stringValue.trimmingCharacters(in: .whitespaces),
            httpsProxy: httpsField.stringValue.trimmingCharacters(in: .whitespaces),
            socks5Proxy: socks5Field.stringValue.trimmingCharacters(in: .whitespaces),
            noProxy: noProxyField.stringValue.trimmingCharacters(in: .whitespaces)
        ))
    }

    @objc private func cancelPressed() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.stopModal()
    }
}
