import CoreGraphics
import Foundation

/// Swallows keyboard and scroll input while cleaning mode is active.
@MainActor
final class KeyboardSuppressionController {
    private lazy var eventTap = EventTapController(
        options: .defaultTap,
        events: [.keyDown, .keyUp, .flagsChanged, .scrollWheel]
    ) { _ in
        nil
    }

    func requestAccessIfNeeded() {
        guard !CGPreflightListenEventAccess() else {
            return
        }

        _ = CGRequestListenEventAccess()
    }

    func start() {
        stop()
        eventTap.start()
    }

    func stop() {
        eventTap.stop()
    }
}
