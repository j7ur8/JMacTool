import CoreGraphics
import XCTest
@testable import JMacToolCore

@MainActor
final class ArrowKeyMapperTests: XCTestCase {
    private let option = CGEventFlags.maskAlternate
    private let optionDeviceBits = CGEventFlags(rawValue: 0x60)

    func testMapsIJKLToPlainArrows() {
        // i=34 → up, j=38 → left, k=40 → down, l=37 → right
        XCTAssertEqual(
            ArrowKeyMapper.map(keyCode: 34, flags: option),
            ArrowKeyMapper.MappedKey(keyCode: 126, flags: [])
        )
        XCTAssertEqual(
            ArrowKeyMapper.map(keyCode: 38, flags: option),
            ArrowKeyMapper.MappedKey(keyCode: 123, flags: [])
        )
        XCTAssertEqual(
            ArrowKeyMapper.map(keyCode: 40, flags: option),
            ArrowKeyMapper.MappedKey(keyCode: 125, flags: [])
        )
        XCTAssertEqual(
            ArrowKeyMapper.map(keyCode: 37, flags: option),
            ArrowKeyMapper.MappedKey(keyCode: 124, flags: [])
        )
    }

    func testMapsNMToWordNavigation() {
        // n=45 → option+left, m=46 → option+right (option kept)
        XCTAssertEqual(
            ArrowKeyMapper.map(keyCode: 45, flags: option),
            ArrowKeyMapper.MappedKey(keyCode: 123, flags: option)
        )
        XCTAssertEqual(
            ArrowKeyMapper.map(keyCode: 46, flags: option),
            ArrowKeyMapper.MappedKey(keyCode: 124, flags: option)
        )
    }

    func testKeepsOtherModifiersAndStripsOptionDeviceBits() {
        let flags: CGEventFlags = [option, .maskShift, optionDeviceBits]
        let mapped = ArrowKeyMapper.map(keyCode: 38, flags: flags)

        XCTAssertEqual(mapped?.keyCode, 123)
        XCTAssertEqual(mapped?.flags, CGEventFlags.maskShift)

        let commandCombo = ArrowKeyMapper.map(keyCode: 40, flags: [option, .maskCommand])
        XCTAssertEqual(commandCombo?.keyCode, 125)
        XCTAssertEqual(commandCombo?.flags, CGEventFlags.maskCommand)
    }

    func testPassesThroughUnmappedKeys() {
        // No option modifier.
        XCTAssertNil(ArrowKeyMapper.map(keyCode: 38, flags: []))
        XCTAssertNil(ArrowKeyMapper.map(keyCode: 38, flags: .maskShift))
        // Unmapped letter under option.
        XCTAssertNil(ArrowKeyMapper.map(keyCode: 0x11, flags: option)) // 'w'
        // Real arrow keys are not remapped.
        XCTAssertNil(ArrowKeyMapper.map(keyCode: 123, flags: option))
    }

    func testApplyMappingRewritesMatchingEvent() {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 38, keyDown: true) else {
            XCTFail("failed to create test event")
            return
        }
        event.flags = [option, .maskShift]

        ArrowKeyMapper.applyMapping(to: event)

        XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 123)
        XCTAssertEqual(event.flags, CGEventFlags.maskShift)
    }

    func testApplyMappingLeavesOtherEventsUntouched() {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0x00, keyDown: true) else {
            XCTFail("failed to create test event")
            return
        }
        event.flags = option

        ArrowKeyMapper.applyMapping(to: event)

        XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 0)
        XCTAssertEqual(event.flags, option)
    }
}
