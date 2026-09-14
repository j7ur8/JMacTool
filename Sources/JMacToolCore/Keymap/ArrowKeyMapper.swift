import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Remaps Option+IJKL/NM to arrow keys system-wide, replicating the
/// Karabiner rule "Map Option+IJKL to up/left/down/right arrows":
/// - Option+I/J/K/L become plain up/left/down/right (option stripped, so
///   Shift/Cmd combos keep working),
/// - Option+N/M become Option+left/right for word-wise navigation.
@MainActor
final class ArrowKeyMapper {
    private lazy var eventTap = EventTapController(
        options: .defaultTap,
        events: [.keyDown, .keyUp]
    ) { event in
        ArrowKeyMapper.applyMapping(to: event)
        return Unmanaged.passUnretained(event)
    }

    private(set) var isEnabled = false

    var hasAccessibilityAccess: Bool {
        AXIsProcessTrusted()
    }

    var hasInputMonitoringAccess: Bool {
        CGPreflightListenEventAccess()
    }

    func requestAccessibilityAccessIfNeeded() {
        guard !hasAccessibilityAccess else {
            return
        }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoringAccessIfNeeded() {
        guard !hasInputMonitoringAccess else {
            return
        }

        _ = CGRequestListenEventAccess()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else {
            return
        }

        isEnabled = enabled

        if enabled {
            eventTap.start()
        } else {
            eventTap.stop()
        }
    }

    // MARK: - Mapping

    struct MappedKey: Equatable {
        let keyCode: UInt64
        let flags: CGEventFlags
    }

    // ANSI key codes: i=34, j=38, k=40, l=37, n=45, m=46;
    // left=123, right=124, down=125, up=126.
    private static let keyCodes: [UInt64: (keyCode: UInt64, keepOption: Bool)] = [
        34: (126, false),
        38: (123, false),
        40: (125, false),
        37: (124, false),
        45: (123, true),
        46: (124, true)
    ]

    /// Option: the generic mask plus the left/right device-specific bits.
    private static let optionFlags: CGEventFlags = [
        .maskAlternate,
        CGEventFlags(rawValue: 0x60)
    ]

    /// Pure mapping decision shared by the event tap and unit tests.
    /// Returns nil when the key does not participate in the mapping.
    static func map(keyCode: UInt64, flags: CGEventFlags) -> MappedKey? {
        guard flags.contains(.maskAlternate),
              let target = keyCodes[keyCode] else {
            return nil
        }

        let nextFlags = target.keepOption ? flags : flags.subtracting(optionFlags)
        return MappedKey(keyCode: target.keyCode, flags: nextFlags)
    }

    /// Mutates a keyboard event in place so the tap can pass it through.
    static func applyMapping(to event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let mapped = map(keyCode: UInt64(keyCode), flags: event.flags) else {
            return
        }

        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(mapped.keyCode))
        event.flags = mapped.flags
    }
}
