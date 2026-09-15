import XCTest
@testable import JMacToolCore

/// Exercises the jpmanager command layer through the injectable console so
/// dispatch, output messages, and exit codes stay stable.
final class ProxyCLITests: XCTestCase {
    private var homeDirectory: String!
    private var context: ProxyFileContext!
    private var buffer: OutputBuffer!

    private final class OutputBuffer: @unchecked Sendable {
        var stdout = ""
        var stderr = ""
        var pendingInput: [String] = []
        var isTTY = false

        lazy var io: ProxyCLIIO = ProxyCLIIO(
            writeStdout: { [weak self] text in self?.stdout += text },
            writeStderr: { [weak self] text in self?.stderr += text },
            stdinIsTTY: { [weak self] in self?.isTTY ?? false },
            stdoutIsTTY: { false },
            readLine: { [weak self] in
                guard let self, !self.pendingInput.isEmpty else { return nil }
                return self.pendingInput.removeFirst()
            },
            environment: ["HOME": ""]
        )

        func feed(_ lines: String...) {
            pendingInput.append(contentsOf: lines)
        }
    }

    override func setUpWithError() throws {
        homeDirectory = NSTemporaryDirectory() + "JMacToolTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: homeDirectory, withIntermediateDirectories: true)
        context = ProxyFileContext(homeDirectory: homeDirectory)
        buffer = OutputBuffer()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: homeDirectory)
    }

    @discardableResult
    private func run(_ commandLine: String) -> Int32 {
        ProxyCLI.run(arguments: ["JMacTool"] + commandLine.split(separator: " ").map(String.init), context: context, io: buffer.io)
    }

    func testHelpListsCommandsFromTable() {
        let exitCode = run("help")

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(buffer.stdout.contains("Usage: JMacTool proxy"))
        XCTAssertTrue(buffer.stdout.contains("proxy remove <name>"))
        XCTAssertTrue(buffer.stdout.contains("   or: JMacTool list [--json]"))
        XCTAssertTrue(buffer.stdout.contains("   or: JMacTool install-cli"))
    }

    func testNoArgumentsPrintsUsageAndFails() {
        let exitCode = ProxyCLI.run(arguments: ["JMacTool"], context: context, io: buffer.io)

        XCTAssertEqual(exitCode, 1)
        XCTAssertTrue(buffer.stderr.contains("Usage: JMacTool proxy"))
    }

    func testUnknownCommandFailsWithUsage() {
        let exitCode = run("frobnicate")

        XCTAssertEqual(exitCode, 1)
        XCTAssertTrue(buffer.stderr.contains("Unknown command \"frobnicate\""))
        XCTAssertTrue(buffer.stderr.contains("Usage: JMacTool proxy"))
    }

    func testProxyAddDuplicateAndForce() {
        XCTAssertEqual(run("proxy add --name office --http-proxy http://a:1"), 0)
        XCTAssertTrue(buffer.stdout.contains("Saved proxy profile \"office\"."))

        XCTAssertEqual(run("proxy add --name office --http-proxy http://b:2"), 1)
        XCTAssertTrue(buffer.stderr.contains("already exists"))

        XCTAssertEqual(run("proxy add --name office --http-proxy http://b:2 --force"), 0)
        XCTAssertEqual(run("proxy remove office --force"), 0)
        XCTAssertTrue(buffer.stdout.contains("Removed proxy profile \"office\"."))
    }

    func testProxyRemoveRequiresForceOutsideTTY() throws {
        try ProfileStore.saveProxyProfile(
            ProxyProfile(name: "gone", state: ProxyState(httpProxy: "http://a:1", httpsProxy: "", socks5Proxy: "", noProxy: "")),
            context: context
        )

        XCTAssertEqual(run("proxy remove gone"), 1)
        XCTAssertTrue(buffer.stderr.contains("--force"))
        XCTAssertNotNil(ProfileStore.findProfileByName(ProfileStore.ensureStore(context: context), "gone"))

        XCTAssertEqual(run("proxy remove gone --force"), 0)
        XCTAssertNil(ProfileStore.findProfileByName(ProfileStore.ensureStore(context: context), "gone"))

        XCTAssertEqual(run("proxy remove gone --force"), 1)
        XCTAssertTrue(buffer.stderr.contains("does not exist"))
    }

    func testProxyRemoveConfirmFlowInTTY() throws {
        buffer.isTTY = true
        try ProfileStore.saveProxyProfile(
            ProxyProfile(name: "asked", state: ProxyState(httpProxy: "http://a:1", httpsProxy: "", socks5Proxy: "", noProxy: "")),
            context: context
        )

        buffer.feed("n")
        XCTAssertEqual(run("proxy remove asked"), 1)
        XCTAssertTrue(buffer.stderr.contains("Aborted."))
        XCTAssertNotNil(ProfileStore.findProfileByName(ProfileStore.ensureStore(context: context), "asked"))

        buffer.feed("y")
        XCTAssertEqual(run("proxy remove asked"), 0)
        XCTAssertNil(ProfileStore.findProfileByName(ProfileStore.ensureStore(context: context), "asked"))
    }

    func testSetTestUnsetRoundTrip() throws {
        XCTAssertEqual(run("proxy add --name office --http-proxy http://127.0.0.1:7890 --https-proxy http://127.0.0.1:7890"), 0)

        XCTAssertEqual(run("set npm office"), 0)
        XCTAssertTrue(buffer.stdout.contains("Configured npm with proxy profile \"office\" in ~/.npmrc."))

        XCTAssertEqual(run("test npm office"), 0)
        XCTAssertTrue(buffer.stdout.contains("OK: npm matches proxy profile \"office\""))

        // Force a mismatch and expect the failure path.
        let npmrc = homeDirectory + "/.npmrc"
        try "proxy = http://other:9\n".write(toFile: npmrc, atomically: true, encoding: .utf8)
        XCTAssertEqual(run("test npm office"), 1)
        XCTAssertTrue(buffer.stderr.contains("Mismatch: npm config"))

        XCTAssertEqual(run("unset npm"), 0)
        XCTAssertTrue(buffer.stdout.contains("Unset proxy settings for npm in ~/.npmrc."))
    }

    func testSetUnknownAppAndProfile() {
        XCTAssertEqual(run("set nosuchapp office"), 1)
        XCTAssertTrue(buffer.stderr.contains("Unknown app \"nosuchapp\""))

        XCTAssertEqual(run("set npm ghost"), 1)
        XCTAssertTrue(buffer.stderr.contains("Unknown proxy profile \"ghost\""))
    }

    func testProxyEditRenames() {
        XCTAssertEqual(run("proxy add --name old --http-proxy http://a:1"), 0)
        XCTAssertEqual(run("proxy edit --name old --rename renamed --no-proxy localhost"), 0)
        XCTAssertTrue(buffer.stdout.contains("Saved proxy profile \"renamed\"."))

        let profiles = ProfileStore.ensureStore(context: context)
        XCTAssertEqual(profiles.map(\.profile.name), ["renamed"])
        XCTAssertEqual(profiles[0].profile.state.noProxy, "localhost")
    }

    func testListJSONAndUnknownOption() {
        XCTAssertEqual(run("proxy add --name office --http-proxy http://a:1"), 0)

        XCTAssertEqual(run("list --json"), 0)
        XCTAssertTrue(buffer.stdout.contains("\"name\" : \"office\""))

        XCTAssertEqual(run("list --yaml"), 1)
        XCTAssertTrue(buffer.stderr.contains("Unknown option(s): --yaml"))
    }

    func testInteractiveCommandsRequireTTY() {
        XCTAssertEqual(run("proxy"), 1)
        XCTAssertTrue(buffer.stderr.contains("Interactive mode requires a TTY"))

        XCTAssertEqual(run("config"), 1)
        XCTAssertTrue(buffer.stderr.contains("Interactive mode requires a TTY"))
    }

    func testShellInitPrintsWrapper() {
        XCTAssertEqual(run("shell-init zsh"), 0)
        XCTAssertTrue(buffer.stdout.hasPrefix("jpmanager() {"))

        XCTAssertEqual(run("shell-init bash"), 1)
        XCTAssertTrue(buffer.stderr.contains("Unknown shell \"bash\""))
    }
}
