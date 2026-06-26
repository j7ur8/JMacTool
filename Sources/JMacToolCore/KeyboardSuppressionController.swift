import CoreGraphics
import Foundation

@MainActor
final class KeyboardSuppressionController {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func requestAccessIfNeeded() {
        guard !CGPreflightListenEventAccess() else {
            return
        }

        _ = CGRequestListenEventAccess()
    }

    func start() {
        stop()

        guard CGPreflightListenEventAccess() else {
            return
        }

        let mask = Self.eventMask(for: [
            .keyDown,
            .keyUp,
            .flagsChanged,
            .scrollWheel
        ])

        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let controller = Unmanaged<KeyboardSuppressionController>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return controller.handleEvent(proxy: proxy, type: type, event: event)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            return
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged, .scrollWheel:
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private static func eventMask(for eventTypes: [CGEventType]) -> CGEventMask {
        eventTypes.reduce(CGEventMask(0)) { partialResult, eventType in
            partialResult | (CGEventMask(1) << eventType.rawValue)
        }
    }
}
