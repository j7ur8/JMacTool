import AppKit
import Foundation

/// Downloads a release bundle, verifies it, and stages a detached installer
/// script that replaces the running app and relaunches it after quit.
@MainActor
final class AppUpdater {
    /// The self-signed identity set up by Scripts/setup-code-signing.sh.
    /// When present locally, downloaded updates must carry the same identity
    /// so TCC permissions (Accessibility, Input Monitoring) survive updates.
    static let stableIdentityName = "JMacTool Local"

    private(set) var isBusy = false

    func downloadAndPrepareInstall(_ info: UpdateChecker.UpdateInfo) async throws {
        guard !isBusy else {
            return
        }
        isBusy = true
        defer { isBusy = false }

        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            throw UpdateError.notRunningFromAppBundle
        }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JMacToolUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        // Download.
        let (downloadedURL, response) = try await URLSession.shared.download(from: info.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let zipDestination = workDirectory.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: downloadedURL, to: zipDestination)

        // Unpack.
        let extractDirectory = workDirectory.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
        try Self.runProcess(
            "/usr/bin/ditto",
            ["-x", "-k", zipDestination.path, extractDirectory.path],
            failure: { UpdateError.installStepFailed(step: "解压更新包") }
        )

        let newApp = extractDirectory.appendingPathComponent("JMacTool.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            throw UpdateError.extractedAppNotFound
        }

        // The archive must carry a valid signature before it is trusted.
        try Self.runProcess(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", newApp.path],
            failure: { UpdateError.signatureVerificationFailed }
        )

        // When this machine uses the stable identity, updates must carry it
        // too so TCC permissions survive the replacement.
        if Self.stableSigningIdentityInUse() {
            let requirement = Self.designatedRequirement(of: newApp)
            guard requirement.contains(Self.stableIdentityName) else {
                throw UpdateError.identityMismatch(expected: Self.stableIdentityName)
            }
        }

        try Self.writeAndLaunchInstallerScript(newAppBundle: newApp)
    }

    // MARK: - Installer script

    private static func writeAndLaunchInstallerScript(newAppBundle: URL) throws {
        let destination = Bundle.main.bundleURL.path
        let script = """
        #!/bin/zsh
        exec >> "/tmp/jmactool-update.log" 2>&1
        set -x
        SRC='\(Self.shellQuoted(newAppBundle.path))'
        DEST='\(Self.shellQuoted(destination))'
        for i in {1..150}; do
          pgrep -x "JMacTool" >/dev/null || break
          sleep 0.2
        done
        rm -rf "$DEST"
        mv -f "$SRC" "$DEST"
        open "$DEST"
        echo "update finished $(date)"

        """

        let scriptURL = newAppBundle.deletingLastPathComponent()
            .appendingPathComponent("install-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Keep the Process object alive until the app exits; the child itself
        // is detached and survives our termination.
        Self.installerProcess = process
    }

    private static var installerProcess: Process?

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Signing identity helpers

    static func stableSigningIdentityInUse() -> Bool {
        guard let output = runCapturedProcess(
            "/usr/bin/security",
            ["find-identity", "-v", "-p", "codesigning"]
        ) else {
            return false
        }
        return output.contains("\"\(stableIdentityName)\"")
    }

    static func designatedRequirement(of appURL: URL) -> String {
        runCapturedProcess("/usr/bin/codesign", ["-d", "-r-", appURL.path]) ?? ""
    }

    // MARK: - Process helpers

    private static func runCapturedProcess(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func runProcess(
        _ path: String,
        _ arguments: [String],
        failure: @escaping () -> UpdateError
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw failure()
        }
    }
}
