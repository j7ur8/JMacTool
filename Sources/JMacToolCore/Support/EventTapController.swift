import CoreGraphics
import Foundation

/// Owns one CGEventTap: creates it, keeps its run-loop source alive, and
/// re-enables the tap after the system disables it on timeout.
///
/// The `onEvent` closure returns the (unretained) event to pass through, or
/// nil to delete the event; deleting only takes effect for `.defaultTap` taps.
@MainActor
final class EventTapController {
    private let options: CGEventTapOptions
    private let eventMask: CGEventMask
    private let onEvent: (CGEvent) -> Unmanaged<CGEvent>?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(
        options: CGEventTapOptions,
        events: [CGEventType],
        onEvent: @escaping (CGEvent) -> Unmanaged<CGEvent>?
    ) {
        self.options = options
        self.eventMask = Self.combinedMask(for: events)
        self.onEvent = onEvent
    }

    var isRunning: Bool {
        eventTap != nil
    }

    func start() {
        stop()

        guard CGPreflightListenEventAccess() else {
            return
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let controller = Unmanaged<EventTapController>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return controller.handleEvent(type: type, event: event)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: eventMask,
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

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        default:
            return onEvent(event)
        }
    }

    private static func combinedMask(for eventTypes: [CGEventType]) -> CGEventMask {
        eventTypes.reduce(CGEventMask(0)) { partialResult, eventType in
            partialResult | (CGEventMask(1) << eventType.rawValue)
        }
    }
}
