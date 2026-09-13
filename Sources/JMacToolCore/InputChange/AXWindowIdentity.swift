import ApplicationServices
import CoreGraphics
import Foundation

/// AX helpers that build a stable identity for a focused window even when
/// the window exposes no AX identifier or document path.
enum AXWindowIdentity {
    static func focusedWindowIdentity(for appElement: AXUIElement) -> String? {
        var focusedWindowValue: CFTypeRef?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        )

        guard focusedWindowResult == .success,
              let focusedWindowValue,
              let window = axElement(from: focusedWindowValue) else {
            return nil
        }

        return windowIdentity(for: window)
    }

    static func windowIdentity(for window: AXUIElement) -> String? {
        if let identifier = stringAttribute(kAXIdentifierAttribute as CFString, for: window),
           !identifier.isEmpty {
            return "axid:\(identifier)"
        }

        if let document = stringAttribute(kAXDocumentAttribute as CFString, for: window)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !document.isEmpty {
            return "doc:\(document)"
        }

        guard let role = stringAttribute(kAXRoleAttribute as CFString, for: window)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !role.isEmpty,
            let position = pointAttribute(kAXPositionAttribute as CFString, for: window),
            let size = sizeAttribute(kAXSizeAttribute as CFString, for: window) else {
            return nil
        }

        let subrole = stringAttribute(kAXSubroleAttribute as CFString, for: window)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = normalizedTitle(focusedWindowTitle(for: window))
        let frameIdentity = [
            role,
            subrole,
            "\(rounded(position.x)),\(rounded(position.y))",
            "\(rounded(size.width))x\(rounded(size.height))",
            title
        ].joined(separator: "|")

        return "fallback:\(frameIdentity)"
    }

    static func stringAttribute(_ attribute: CFString, for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )

        guard result == .success, let value else {
            return nil
        }

        return value as? String
    }

    static func axElement(from value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func focusedWindowTitle(for window: AXUIElement) -> String {
        stringAttribute(kAXTitleAttribute as CFString, for: window) ?? ""
    }

    private static func pointAttribute(_ attribute: CFString, for element: AXUIElement) -> CGPoint? {
        valueAttribute(attribute, expectedType: .cgPoint, for: element)
    }

    private static func sizeAttribute(_ attribute: CFString, for element: AXUIElement) -> CGSize? {
        valueAttribute(attribute, expectedType: .cgSize, for: element)
    }

    private static func valueAttribute<T>(
        _ attribute: CFString,
        expectedType: AXValueType,
        for element: AXUIElement
    ) -> T? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )

        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == expectedType else {
            return nil
        }

        switch expectedType {
        case .cgPoint:
            var point = CGPoint.zero
            guard AXValueGetValue(axValue, .cgPoint, &point) else {
                return nil
            }
            return point as? T
        case .cgSize:
            var size = CGSize.zero
            guard AXValueGetValue(axValue, .cgSize, &size) else {
                return nil
            }
            return size as? T
        default:
            return nil
        }
    }

    private static func normalizedTitle(_ title: String) -> String {
        let components = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)

        return components.joined(separator: " ").lowercased()
    }

    private static func rounded(_ value: CGFloat) -> Int {
        Int(value.rounded())
    }
}
