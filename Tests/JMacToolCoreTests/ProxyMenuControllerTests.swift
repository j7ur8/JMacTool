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
        let controller = ProxyMenuController(context: ProxyFileContext(homeDirectory: homeDirectory))
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Clear Screen", action: nil, keyEquivalent: ""))
        let quit = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "")
        menu.addItem(quit)
        controller.install(into: menu, before: quit)
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
        // Managed apps are rendered as top-level items, one per built-in
        // target except the dashboard-hidden zsh alias.
        for app in ["environment", "conda", "curl", "git", "go", "gradle", "maven", "npm", "pip", "wget", "yarn"] {
            XCTAssertTrue(titles.contains { $0.hasPrefix("\(app):") }, "missing app item: \(app)")
        }
        XCTAssertFalse(titles.contains { $0.hasPrefix("zsh:") })
        // Empty store shows the hint and no profile rows.
        XCTAssertTrue(titles.contains("No proxy profiles saved yet"))
    }

    @MainActor
    func testProxySubmenuOnlyKeepsCLIInstaller() throws {
        let (_, menu) = makeInstalledMenu()
        let proxyItem = try XCTUnwrap(menu.items.first { $0.title == "Proxy" })
        let submenu = try XCTUnwrap(proxyItem.submenu)

        XCTAssertEqual(submenu.items.count, 1)
        XCTAssertTrue(submenu.items[0].title.hasPrefix("Install"))
        XCTAssertTrue(submenu.items[0].title.contains("jpmanager"))
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

        let npmItem = try XCTUnwrap(menu.items.first { $0.title.hasPrefix("npm:") })
        let npmSubmenu = try XCTUnwrap(npmItem.submenu)
        XCTAssertTrue(npmSubmenu.items.contains { $0.title == "None" })
        XCTAssertTrue(npmSubmenu.items.contains { $0.title == "office" })

        XCTAssertFalse(menu.items.contains { $0.title == "No proxy profiles saved yet" })
        let profileItem = try XCTUnwrap(menu.items.first { $0.title == "office" })
        let profileSubmenu = try XCTUnwrap(profileItem.submenu)
        XCTAssertTrue(profileSubmenu.items.contains { $0.title == "Edit…" })
    }
}
