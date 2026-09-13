import Carbon
import Foundation

/// Switches the active keyboard input source to a known English layout.
@MainActor
enum InputSourceSwitcher {
    private static let englishSourceIDs = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.US"
    ]

    static func switchToEnglishNow() {
        let filter = [
            kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String
        ] as CFDictionary

        guard let sourceList = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return
        }

        for preferredID in englishSourceIDs {
            if let source = sourceList.first(where: { inputSourceIdentifier(for: $0) == preferredID }) {
                TISSelectInputSource(source)
                return
            }
        }
    }

    private static func inputSourceIdentifier(for source: TISInputSource) -> String? {
        guard let rawValue = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }

        return Unmanaged<CFString>.fromOpaque(rawValue).takeUnretainedValue() as String
    }
}
