import AppKit
import CoreGraphics
import Foundation

/// Notifies on keyboard activity while an input-monitoring event tap runs.
@MainActor
final class KeyboardActivityMonitor {
    var onActivity: (@Sendable () -> Void)?

    private lazy var eventTap = EventTapController(
        options: .listenOnly,
        events: [.keyDown, .flagsChanged]
    ) { [weak self] event in
        self?.onActivity?()
        return Unmanaged.passUnretained(event)
    }

    func start() {
        stop()
        eventTap.start()
    }

    func stop() {
        eventTap.stop()
    }
}
