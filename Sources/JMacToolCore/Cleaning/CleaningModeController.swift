import AppKit
import Foundation

@MainActor
final class CleaningModeController {
    var onStateChange: ((Bool) -> Void)?

    private let keyboardSuppressionController = KeyboardSuppressionController()
    private let touchBarSuppressionController = TouchBarSuppressionController()
    private var windows: [CleaningWindow] = []
    private var localEventMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var previousPresentationOptions: NSApplication.PresentationOptions = []
    private(set) var isRunning = false {
        didSet {
            guard oldValue != isRunning else {
                return
            }

            onStateChange?(isRunning)
        }
    }

    func requestInputMonitoringAccessIfNeeded() {
        keyboardSuppressionController.requestAccessIfNeeded()
    }

    func start() {
        guard !isRunning else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        previousPresentationOptions = NSApp.presentationOptions
        NSApp.presentationOptions = AppConstants.presentationOptions

        installLocalEventMonitor()
        installScreenObserver()
        keyboardSuppressionController.start()
        touchBarSuppressionController.start()
        rebuildWindows()
        isRunning = true
        NSApp.activate(ignoringOtherApps: true)
    }

    func stop() {
        guard isRunning else {
            return
        }

        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }

        keyboardSuppressionController.stop()
        touchBarSuppressionController.stop()
        windows.forEach { $0.close() }
        windows.removeAll()
        NSApp.presentationOptions = previousPresentationOptions
        isRunning = false
    }

    private func installLocalEventMonitor() {
        let blockedEvents: NSEvent.EventTypeMask = [
            .keyDown,
            .keyUp,
            .flagsChanged,
            .scrollWheel,
            .swipe,
            .magnify,
            .smartMagnify,
            .rotate,
            .beginGesture,
            .endGesture,
            .systemDefined
        ]

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: blockedEvents) { _ in
            nil
        }
    }

    private func installScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildWindows()
            }
        }
    }

    private func rebuildWindows() {
        windows.forEach { $0.close() }
        windows.removeAll()

        let screens = NSScreen.screens
        let controlScreen = NSScreen.main ?? screens.first

        for screen in screens {
            let window = CleaningWindow(
                screen: screen,
                showsExitButton: screen === controlScreen
            ) { [weak self] in
                self?.finishCleaning()
            }
            windows.append(window)
        }

        windows.first(where: \.showsExitButton)?.makeKeyAndOrderFront(nil)
    }

    private func finishCleaning() {
        stop()
    }
}
