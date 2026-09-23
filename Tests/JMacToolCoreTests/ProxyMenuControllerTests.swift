import AppKit
import XCTest
@testable import JMacToolCore

final class ProxyMenuControllerTests: XCTestCase {
    private var homeDirectory: String!

    override func setUpWithError() throws {
        homeDirectory = NSTemporaryDirectory() + "JMacToolTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: homeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: homeDirectory)
    }

    @MainActor
    private func makeInstalledMenu() -> (ProxyMenuController, NSMenu) {
        // The system target shells out (scutil/networksetup); keep tests hermetic.
        let context = ProxyFileContext(homeDirectory: homeDirectory, runCommand: { _, _ in nil })
        let controller = ProxyMenuController(context: context)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Clear Screen", action: nil, keyEquivalent: ""))
        let quit = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "")
        menu.addItem(quit)
        let updates = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
        controller.install(into: menu, before: quit, updatesItem: updates)
        return (controller, menu)
    }

    @MainActor
    func testProxySectionsLiveInMainMenu() throws {
        let (_, menu) = makeInstalledMenu()
        let titles = menu.items.map(\.title)

        XCTAssertTrue(titles.contains("Managed Apps"))
        XCTAssertTrue(titles.contains("Profiles"))
        XCTAssertTrue(titles.contains("Launch at Login"))
        XCTAssertTrue(titles.contains("Add Profile…"))
        XCTAssertTrue(titles.contains("Quit"))
        // The bundled CLI needs no installer, so no Proxy submenu is offered.
        XCTAssertFalse(titles.contains("Proxy"))
        // Check for Updates shares the Launch at Login group (no separator
        // between them).
        if let launchIndex = titles.firstIndex(of: "Launch at Login") {
            XCTAssertEqual(titles[launchIndex + 1], "Check for Updates…")
        } else {
            XCTFail("Launch at Login is missing")
        }
        // Managed apps are rendered as top-level items, one per built-in
        // target except the dashboard-hidden zsh alias. App rows carry an
        // attributed two-column title ("app\talias"), so AppKit mirrors that
        // plain text back into `title`.
        for app in ["environment", "conda", "curl", "git", "go", "gradle", "maven", "npm", "pip", "system", "wget", "yarn"] {
            XCTAssertTrue(titles.contains { $0.hasPrefix("\(app)\t") }, "missing app item: \(app)")
        }
        XCTAssertFalse(titles.contains { $0.hasPrefix("zsh\t") })
        // Empty store shows the hint and no profile rows.
        XCTAssertTrue(titles.contains("No proxy profiles saved yet"))
    }

    @MainActor
    func testRefreshReplacesInsteadOfDuplicating() throws {
        let (controller, menu) = makeInstalledMenu()
        controller.refreshDynamicSection()
        controller.refreshDynamicSection()

        XCTAssertEqual(menu.items.filter { $0.title == "Managed Apps" }.count, 1)
        XCTAssertEqual(menu.items.filter { $0.title == "Launch at Login" }.count, 1)
        XCTAssertEqual(menu.items.filter { $0.title == "Quit" }.count, 1)
    }

    @MainActor
    func testAppAndProfileSubmenus() throws {
        var profile = ProxyProfile(name: "office", state: .empty)
        profile.state.httpProxy = "http://127.0.0.1:7890"
        _ = try ProfileStore.saveProxyProfile(profile, context: ProxyFileContext(homeDirectory: homeDirectory))

        let (_, menu) = makeInstalledMenu()

        let npmItem = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("npm\t") })
        let npmSubmenu = try XCTUnwrap(npmItem.submenu)
        XCTAssertTrue(npmSubmenu.items.contains { $0.title == "None" })
        XCTAssertTrue(npmSubmenu.items.contains { $0.title == "office" })

        XCTAssertFalse(menu.items.contains { $0.title == "No proxy profiles saved yet" })
        let profileItem = try XCTUnwrap(menu.items.first { $0.title == "office" })
        let profileSubmenu = try XCTUnwrap(profileItem.submenu)
        XCTAssertTrue(profileSubmenu.items.contains { $0.title == "Edit…" })
    }

    /// Fires a menu item the way the status menu does, so the controller's
    /// target/action wiring is exercised rather than the private methods.
    @MainActor
    @discardableResult
    private func fire(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else {
            return false
        }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    @MainActor
    func testAddAndEditReuseOneFormWindow() throws {
        var profile = ProxyProfile(name: "office", state: .empty)
        profile.state.httpProxy = "http://127.0.0.1:7890"
        _ = try ProfileStore.saveProxyProfile(profile, context: ProxyFileContext(homeDirectory: homeDirectory))

        let (controller, menu) = makeInstalledMenu()
        let addItem = try XCTUnwrap(menu.items.first { $0.title == "Add Profile…" })

        XCTAssertTrue(fire(addItem))
        let window = try XCTUnwrap(controller.profileFormWindow)
        XCTAssertEqual(window.title, "Add Proxy Profile")
        // A new profile starts with a sane no_proxy default.
        XCTAssertEqual(window.fields.noProxy, "localhost,127.0.0.1")

        // Clicking Add again (the reported duplicate-window bug) must reuse the
        // window that is already open.
        XCTAssertTrue(fire(addItem))
        XCTAssertTrue(controller.profileFormWindow === window)

        // Editing a profile while the form is open re-targets that same window.
        let profileItem = try XCTUnwrap(menu.items.first { $0.title == "office" })
        let editItem = try XCTUnwrap(profileItem.submenu?.items.first { $0.title == "Edit…" })

        XCTAssertTrue(fire(editItem))
        XCTAssertTrue(controller.profileFormWindow === window)
        XCTAssertEqual(window.title, "Edit Proxy Profile")
        XCTAssertEqual(window.fields.name, "office")
        XCTAssertEqual(window.fields.httpProxy, "http://127.0.0.1:7890")

        window.close()
        XCTAssertNil(controller.profileFormWindow)
    }

    @MainActor
    func testReusedFormSavesToTheProfileItWasRetargetedTo() throws {
        let context = ProxyFileContext(homeDirectory: homeDirectory, runCommand: { _, _ in nil })
        var profile = ProxyProfile(name: "office", state: .empty)
        profile.state.httpProxy = "http://127.0.0.1:7890"
        _ = try ProfileStore.saveProxyProfile(profile, context: context)

        let (controller, menu) = makeInstalledMenu()
        let addItem = try XCTUnwrap(menu.items.first { $0.title == "Add Profile…" })
        XCTAssertTrue(fire(addItem))

        let profileItem = try XCTUnwrap(menu.items.first { $0.title == "office" })
        let editItem = try XCTUnwrap(profileItem.submenu?.items.first { $0.title == "Edit…" })
        XCTAssertTrue(fire(editItem))

        let window = try XCTUnwrap(controller.profileFormWindow)
        window.fields.httpProxy = "http://127.0.0.1:8080"
        window.commit()

        // The re-targeted form edited "office" instead of creating a second,
        // half-filled profile from the earlier Add request.
        let stored = ProfileStore.ensureStore(context: context)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(ProfileStore.findProfileByName(stored, "office")?.profile.state.httpProxy, "http://127.0.0.1:8080")

        // Saving closes the form and clears the controller's reference.
        XCTAssertNil(controller.profileFormWindow)
        XCTAssertFalse(window.isVisible)
    }
}
