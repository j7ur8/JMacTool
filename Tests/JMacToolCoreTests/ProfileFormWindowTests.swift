import AppKit
import XCTest
@testable import JMacToolCore

final class ProfileFormWindowTests: XCTestCase {
    private let officeFields = ProfileFormWindow.Fields(
        name: "office",
        httpProxy: "http://127.0.0.1:7890",
        httpsProxy: "https://127.0.0.1:7890",
        socks5Proxy: "socks5://127.0.0.1:7890",
        noProxy: "localhost,127.0.0.1"
    )

    @MainActor
    func testPresentRetargetsTitleAndFields() {
        let window = ProfileFormWindow {}
        defer { window.close() }

        XCTAssertEqual(window.title, "Add Proxy Profile")
        XCTAssertEqual(window.fields.name, "")

        window.present(existing: officeFields, onSave: { _ in })

        XCTAssertEqual(window.title, "Edit Proxy Profile")
        XCTAssertEqual(window.fields.name, "office")
        XCTAssertEqual(window.fields.httpProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(window.fields.httpsProxy, "https://127.0.0.1:7890")
        XCTAssertEqual(window.fields.socks5Proxy, "socks5://127.0.0.1:7890")
        XCTAssertEqual(window.fields.noProxy, "localhost,127.0.0.1")

        // Re-targeting back to "add" must clear the previously edited values
        // and restore the no_proxy default.
        window.present(existing: nil, onSave: { _ in })

        XCTAssertEqual(window.title, "Add Proxy Profile")
        XCTAssertEqual(window.fields.name, "")
        XCTAssertEqual(window.fields.httpProxy, "")
        XCTAssertEqual(window.fields.httpsProxy, "")
        XCTAssertEqual(window.fields.socks5Proxy, "")
        XCTAssertEqual(window.fields.noProxy, "localhost,127.0.0.1")
    }

    @MainActor
    func testCommitUsesMostRecentHandlerAndTrimsValues() {
        let window = ProfileFormWindow {}
        defer { window.close() }

        var added: [ProfileFormWindow.Fields] = []
        var edited: [ProfileFormWindow.Fields] = []

        window.present(existing: nil, onSave: { added.append($0) })
        window.present(existing: officeFields, onSave: { edited.append($0) })

        window.fields.name = "  office-renamed  "
        window.fields.noProxy = "  localhost  "
        window.commit()

        XCTAssertTrue(added.isEmpty, "the stale Add handler must not run after re-targeting")
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(edited.first?.name, "office-renamed")
        XCTAssertEqual(edited.first?.httpProxy, "http://127.0.0.1:7890")
        XCTAssertEqual(edited.first?.noProxy, "localhost")
    }

    @MainActor
    func testCloseRunsTheCloseHandler() {
        var closeCount = 0
        let window = ProfileFormWindow { closeCount += 1 }
        window.present(existing: nil, onSave: { _ in })

        window.close()

        XCTAssertEqual(closeCount, 1)
    }

    // MARK: - Editing key equivalents

    private func keyEvent(
        _ characters: String,
        modifiers: NSEvent.ModifierFlags = .command,
        type: NSEvent.EventType = .keyDown
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }

    @MainActor
    func testEditingSelectorMapsTheStandardEditingShortcuts() {
        XCTAssertEqual(ProfileFormWindow.editingSelector(for: keyEvent("x")), #selector(NSText.cut(_:)))
        XCTAssertEqual(ProfileFormWindow.editingSelector(for: keyEvent("c")), #selector(NSText.copy(_:)))
        XCTAssertEqual(ProfileFormWindow.editingSelector(for: keyEvent("v")), #selector(NSText.paste(_:)))
        XCTAssertEqual(ProfileFormWindow.editingSelector(for: keyEvent("a")), #selector(NSText.selectAll(_:)))
    }

    @MainActor
    func testEditingSelectorIgnoresCapsLockAndRejectsModifiedOrUnmappedKeys() {
        // Caps Lock must not stop the shortcut from working.
        XCTAssertEqual(
            ProfileFormWindow.editingSelector(for: keyEvent("C", modifiers: [.capsLock, .command])),
            #selector(NSText.copy(_:))
        )

        // Only Command alone is claimed; everything else stays with AppKit.
        XCTAssertNil(ProfileFormWindow.editingSelector(for: keyEvent("c", modifiers: [.command, .shift])))
        XCTAssertNil(ProfileFormWindow.editingSelector(for: keyEvent("v", modifiers: [.command, .option])))
        XCTAssertNil(ProfileFormWindow.editingSelector(for: keyEvent("a", modifiers: [.command, .control])))
        XCTAssertNil(ProfileFormWindow.editingSelector(for: keyEvent("c", modifiers: [])))

        // Unmapped characters and non-keyDown events are never intercepted.
        XCTAssertNil(ProfileFormWindow.editingSelector(for: keyEvent("s")))
        XCTAssertNil(ProfileFormWindow.editingSelector(for: keyEvent("c", type: .keyUp)))
        XCTAssertNil(ProfileFormWindow.editingSelector(for: keyEvent("c", modifiers: [.command], type: .flagsChanged)))
    }

    @MainActor
    func testPerformKeyEquivalentKeepsReturnSavingAndFallsBackForOtherKeys() {
        var saves = 0
        var closes = 0
        let window = ProfileFormWindow { closes += 1 }
        defer { window.close() }

        window.present(existing: nil, onSave: { _ in saves += 1 })
        window.makeKeyAndOrderFront(nil)

        // Return still reaches the Save button.
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("\r", modifiers: [])))
        XCTAssertEqual(saves, 1)

        // Escape still reaches the Cancel button.
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("\u{1b}", modifiers: [])))
        XCTAssertEqual(closes, 1)

        // Unmapped shortcuts are handed back to AppKit untouched.
        XCTAssertFalse(window.performKeyEquivalent(with: keyEvent("s")))
        XCTAssertEqual(saves, 1)
    }

    @MainActor
    func testPerformKeyEquivalentSendsCopyToTheFocusedFieldEditor() {
        let window = ProfileFormWindow {}
        defer { window.close() }

        window.present(existing: nil, onSave: { _ in })
        window.makeKeyAndOrderFront(nil)

        // `present` focuses the name field, which installs its field editor.
        let editor = window.firstResponder as? NSTextView
        XCTAssertNotNil(editor, "the name field should hold a field editor as first responder")
        editor?.string = "clipboard-check"
        editor?.selectAll(nil)

        let pasteboard = NSPasteboard.general
        let savedClipboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let savedClipboard {
                pasteboard.setString(savedClipboard, forType: .string)
            }
        }

        pasteboard.clearContents()
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("c")))
        XCTAssertEqual(pasteboard.string(forType: .string), "clipboard-check")

        // ⌘V flows the other way: the field editor takes the pasteboard text.
        pasteboard.clearContents()
        pasteboard.setString("pasted-text", forType: .string)
        editor?.selectAll(nil)
        XCTAssertTrue(window.performKeyEquivalent(with: keyEvent("v")))
        XCTAssertEqual(editor?.string, "pasted-text")
    }
}
