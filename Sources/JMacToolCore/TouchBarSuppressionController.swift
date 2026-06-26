import AppKit
import ObjectiveC.runtime

@MainActor
final class TouchBarSuppressionController: NSObject, NSTouchBarDelegate {
    private static let messageItemIdentifier = NSTouchBarItem.Identifier("local.codex.JMacTool.touchbar.message")
    private static let escapeItemIdentifier = NSTouchBarItem.Identifier("local.codex.JMacTool.touchbar.escape")

    private var modalTouchBar: NSTouchBar?

    func start() {
        guard modalTouchBar == nil else {
            return
        }

        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [
            .flexibleSpace,
            Self.messageItemIdentifier,
            .flexibleSpace
        ]
        touchBar.customizationAllowedItemIdentifiers = []
        touchBar.escapeKeyReplacementItemIdentifier = Self.escapeItemIdentifier

        presentSystemModalTouchBar(touchBar)
        modalTouchBar = touchBar
    }

    func stop() {
        guard let modalTouchBar else {
            return
        }

        dismissSystemModalTouchBar(modalTouchBar)
        self.modalTouchBar = nil
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case Self.messageItemIdentifier:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let label = NSTextField(labelWithString: "TouchPad Only")
            label.alignment = .center
            label.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
            label.textColor = .secondaryLabelColor
            item.view = label
            return item
        case Self.escapeItemIdentifier:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 30))
            return item
        default:
            return nil
        }
    }

    // AppKit exposes stronger Touch Bar replacement only via Objective-C runtime selectors.
    private func presentSystemModalTouchBar(_ touchBar: NSTouchBar) {
        let selector = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        guard let method = class_getClassMethod(NSTouchBar.self, selector) else {
            return
        }

        typealias PresentFunction = @convention(c) (AnyClass, Selector, NSTouchBar, NSString?) -> Void
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: PresentFunction.self)
        function(NSTouchBar.self, selector, touchBar, nil)
    }

    private func dismissSystemModalTouchBar(_ touchBar: NSTouchBar) {
        let selector = NSSelectorFromString("dismissSystemModalTouchBar:")
        guard let method = class_getClassMethod(NSTouchBar.self, selector) else {
            return
        }

        typealias DismissFunction = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: DismissFunction.self)
        function(NSTouchBar.self, selector, touchBar)
    }
}
