import AppKit

@MainActor
final class CleaningWindow: NSWindow {
    private(set) var showsExitButton = false

    convenience init(screen: NSScreen, showsExitButton: Bool, onExit: @escaping () -> Void) {
        self.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.showsExitButton = showsExitButton
        contentViewController = CleaningViewController(
            showsExitButton: showsExitButton,
            onExit: onExit
        )
        setFrame(screen.frame, display: true)
        orderFrontRegardless()
    }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing bufferingType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: bufferingType,
            defer: flag
        )

        configureWindow()
    }

    private func configureWindow() {
        backgroundColor = .black
        isOpaque = true
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {}

    override func keyUp(with event: NSEvent) {}

    override func flagsChanged(with event: NSEvent) {}

    override func cancelOperation(_ sender: Any?) {}

    override func makeTouchBar() -> NSTouchBar? {
        let touchBar = NSTouchBar()
        touchBar.defaultItemIdentifiers = []
        touchBar.customizationAllowedItemIdentifiers = []
        return touchBar
    }
}
