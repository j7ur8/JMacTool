import XCTest
@testable import JMacToolCore

final class ProfileStoreTests: XCTestCase {
    private var homeDirectory: String!

    override func setUpWithError() throws {
        homeDirectory = NSTemporaryDirectory() + "JMacToolTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: homeDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: homeDirectory)
    }

    private var context: ProxyFileContext {
        ProxyFileContext(homeDirectory: homeDirectory)
    }

    private func makeProfile(name: String, http: String = "http://127.0.0.1:7890") -> ProxyProfile {
        var profile = ProxyProfile(name: name, state: .empty)
        profile.state.httpProxy = http
        return profile
    }

    func testSlugify() {
        XCTAssertEqual(ProfileStore.slugifyProfileName("Office Proxy"), "office-proxy")
        XCTAssertEqual(ProfileStore.slugifyProfileName("  direct  "), "direct")
        XCTAssertEqual(ProfileStore.slugifyProfileName("a_b.c-d"), "a_b.c-d")
        XCTAssertEqual(ProfileStore.slugifyProfileName("///"), "profile")
        XCTAssertEqual(ProfileStore.slugifyProfileName("中文"), "profile")
    }

    func testSaveWritesCompatibleYAML() throws {
        var profile = ProxyProfile(name: "office", state: .empty)
        profile.state.httpProxy = "http://127.0.0.1:7890"
        profile.state.httpsProxy = "http://127.0.0.1:7890"
        profile.state.noProxy = "localhost,127.0.0.1"

        let saved = try ProfileStore.saveProxyProfile(profile, context: context)

        XCTAssertEqual(saved.filePath, context.profilesDirectory + "/office.yaml")
        XCTAssertEqual(try String(contentsOfFile: saved.filePath, encoding: .utf8), """
        version: 1
        profile:
          name: office
          http_proxy: http://127.0.0.1:7890
          https_proxy: http://127.0.0.1:7890
          socks5_proxy: ""
          no_proxy: localhost,127.0.0.1
        """ + "\n")

        let loaded = ProfileStore.ensureStore(context: context)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].profile.name, "office")
        XCTAssertEqual(loaded[0].profile.state.httpProxy, "http://127.0.0.1:7890")
    }

    func testSaveRejectsDuplicateWithoutForce() throws {
        _ = try ProfileStore.saveProxyProfile(makeProfile(name: "office"), context: context)

        XCTAssertThrowsError(try ProfileStore.saveProxyProfile(makeProfile(name: "office"), context: context)) { error in
            XCTAssertTrue("\(error)".contains("already exists"))
        }

        XCTAssertNoThrow(try ProfileStore.saveProxyProfile(makeProfile(name: "office", http: "http://other:1"), context: context, allowOverwrite: true))

        let profiles = ProfileStore.ensureStore(context: context)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].profile.state.httpProxy, "http://other:1")
    }

    func testSaveRejectsEmptyNameAndEmptyValues() {
        XCTAssertThrowsError(try ProfileStore.saveProxyProfile(makeProfile(name: ""), context: context))
        XCTAssertThrowsError(try ProfileStore.saveProxyProfile(ProxyProfile(name: "no-values", state: .empty), context: context))
    }

    func testEditRenamesAndClearsValues() throws {
        _ = try ProfileStore.saveProxyProfile(makeProfile(name: "old"), context: context)

        let saved = try ProfileStore.editProxyProfile(
            "old",
            updates: ProfileStore.ProxyProfileUpdates(name: "renamed", noProxy: "localhost"),
            context: context
        )

        XCTAssertEqual(saved.profile.name, "renamed")
        XCTAssertEqual(saved.profile.state.noProxy, "localhost")
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.profilesDirectory + "/old.yaml"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.profilesDirectory + "/renamed.yaml"))

        let profiles = ProfileStore.ensureStore(context: context)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].profile.name, "renamed")
    }

    func testEditMissingProfileThrows() {
        XCTAssertThrowsError(
            try ProfileStore.editProxyProfile("ghost", updates: .init(), context: context)
        )
    }

    func testInvalidProfileFileIsRecovered() throws {
        let profilesDirectory = context.profilesDirectory
        try FileManager.default.createDirectory(atPath: profilesDirectory, withIntermediateDirectories: true)
        try "not: [valid: yaml".write(toFile: profilesDirectory + "/broken.yaml", atomically: true, encoding: .utf8)
        _ = try ProfileStore.saveProxyProfile(makeProfile(name: "ok"), context: context)

        let profiles = ProfileStore.ensureStore(context: context)

        XCTAssertEqual(profiles.map(\.profile.name), ["ok"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: profilesDirectory).filter { $0.contains("broken.yaml.invalid") }
        XCTAssertEqual(leftovers.count, 1)
    }
}
