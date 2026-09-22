import AppKit

/// Centered form window used to create and edit proxy profiles, mirroring the
/// tray GUI of the original jpmanager.
///
/// A single instance is re-targeted by `present(existing:onSave:)` for every
/// Add/Edit request, so the menu can never leave more than one form behind.
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
    private var onSave: ((Fields) -> Void)?
    private let onClose: () -> Void

    /// Current field contents. Re-targeting the window (`present`) rewrites it,
    /// and Save reads it back.
    var fields: Fields {
        get {
            Fields(
                name: nameField.stringValue,
                httpProxy: httpField.stringValue,
                httpsProxy: httpsField.stringValue,
                socks5Proxy: socks5Field.stringValue,
                noProxy: noProxyField.stringValue
            )
        }
        set {
            nameField.stringValue = newValue.name
            httpField.stringValue = newValue.httpProxy
            httpsField.stringValue = newValue.httpsProxy
            socks5Field.stringValue = newValue.socks5Proxy
            noProxyField.stringValue = newValue.noProxy
        }
    }

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        title = "Add Proxy Profile"
        delegate = self
        isReleasedWhenClosed = false
        center()
        buildForm()
    }

    /// Points the window at a create (`existing == nil`) or edit request,
    /// refills every field, and remembers the matching save handler.
    func present(existing: Fields?, onSave: @escaping (Fields) -> Void) {
        title = existing == nil ? "Add Proxy Profile" : "Edit Proxy Profile"
        fields = existing ?? Fields(
            name: "",
            httpProxy: "",
            httpsProxy: "",
            socks5Proxy: "",
            noProxy: ""
        )
        self.onSave = onSave
        // Focus the name field so the form is typeable the moment it appears.
        _ = makeFirstResponder(nameField)
    }

    // MARK: - Editing key equivalents

    /// Maps the standard editing shortcuts (⌘X/⌘C/⌘V/⌘A) to the
    /// responder-chain selectors that perform them.
    ///
    /// The app never installs `NSApp.mainMenu` (the status item owns its own
    /// menu), so there is no Edit menu for AppKit to route these through and
    /// the fields would otherwise ignore them. Anything not mapped here —
    /// Return, Escape, ⌘←/⌘⌫ key bindings, and modified variants such as
    /// ⇧⌘C — keeps its normal AppKit handling.
    static func editingSelector(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown else {
            return nil
        }

        // Caps Lock and the numeric-pad/function flags do not change which
        // command the user means, so drop them; every remaining modifier must
        // be Command alone, which leaves ⌘⇧C, ⌥⌘V and ⌃⌘A to AppKit.
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard flags == .command else {
            return nil
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "x": return #selector(NSText.cut(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSText.selectAll(_:))
        default: return nil
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Dispatch down this window's responder chain exactly like an
        // Edit-menu item would after AppKit picked the key window, so the
        // focused field editor performs the edit. Starting from the window's
        // own first responder keeps the dispatch testable without a key
        // window. Unmapped or unhandled events fall back to AppKit so Save
        // (Return), Cancel (Escape) and the key bindings keep working.
        if let selector = Self.editingSelector(for: event),
           (firstResponder ?? self).tryToPerform(selector, with: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Runs the stored save handler with the trimmed field values. Shared by
    /// the Save button and by tests.
    func commit() {
        let values = fields
        onSave?(Fields(
            name: values.name.trimmingCharacters(in: .whitespaces),
            httpProxy: values.httpProxy.trimmingCharacters(in: .whitespaces),
            httpsProxy: values.httpsProxy.trimmingCharacters(in: .whitespaces),
            socks5Proxy: values.socks5Proxy.trimmingCharacters(in: .whitespaces),
            noProxy: values.noProxy.trimmingCharacters(in: .whitespaces)
        ))
    }

    private func buildForm() {
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
        commit()
    }

    @objc private func cancelPressed() {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
