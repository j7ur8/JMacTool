import Foundation

enum ProxyConstants {
    static let storeDirectoryName = ".jpmanager"
    static let profilesDirectoryName = "profiles"
    static let targetsDirectoryName = "targets"
    static let environmentAppName = "environment"
    static let zshManagedBlockStart = "# >>> jpmanager proxy >>>"
    static let zshManagedBlockEnd = "# <<< jpmanager proxy <<<"
    static let mavenManagedProxyID = "jpmanager"

    /// The CLI keeps the historical `jpmanager` command name for compatibility
    /// with existing shell wrappers and docs.
    static let legacyCommandName = "jpmanager"
}

/// Captured result of an external command run on behalf of a proxy target.
struct ProxyCommandOutput: Sendable {
    var exitStatus: Int32
    var stdout: String
    var stderr: String
}

typealias RunCommand = @Sendable (String, [String]) -> ProxyCommandOutput?

/// Filesystem access for the proxy engine with an injectable home directory so
/// tests (and ad-hoc verification) can run against a scratch store.
struct ProxyFileContext: Sendable {
    let homeDirectory: String

    /// Runs an external command for targets whose state lives outside the
    /// filesystem (the macOS system proxy); injectable so tests stay hermetic.
    var runCommand: RunCommand = SystemProxy.defaultRun

    static var live: ProxyFileContext {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return ProxyFileContext(homeDirectory: home)
    }

    var storeDirectory: String {
        homeDirectory + "/" + ProxyConstants.storeDirectoryName
    }

    var profilesDirectory: String {
        storeDirectory + "/" + ProxyConstants.profilesDirectoryName
    }

    var userTargetsDirectory: String {
        storeDirectory + "/" + ProxyConstants.targetsDirectoryName
    }

    func expandHome(_ path: String) -> String {
        guard path.hasPrefix("~") else {
            return path
        }

        let remainder = path.dropFirst()
        if remainder.isEmpty {
            return homeDirectory
        }
        if remainder.hasPrefix("/") {
            return homeDirectory + remainder
        }
        return homeDirectory + "/" + remainder
    }

    func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expandHome(path))
    }

    func readTextFile(_ path: String) -> String {
        let resolved = expandHome(path)
        guard let data = FileManager.default.contents(atPath: resolved) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func writeTextFile(_ path: String, _ content: String) {
        let resolved = expandHome(path)
        let directory = (resolved as NSString).deletingLastPathComponent

        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write("Failed to create directory \(directory): \(error.localizedDescription)\n".data(using: .utf8)!)
            return
        }

        atomicWrite(resolved, content)
    }

    /// Writes only when the target already exists or the content is non-empty,
    /// matching the jpmanager `syncTextFile` semantics.
    func syncTextFile(_ path: String, _ content: String) {
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !fileExists(path) {
            return
        }

        writeTextFile(path, content)
    }

    func atomicWrite(_ resolvedPath: String, _ content: String) {
        let temporaryPath = "\(resolvedPath).tmp-\(getpid())-\(Int(Date().timeIntervalSince1970 * 1000))"
        let data = Data(content.utf8)

        do {
            let attributes: [FileAttributeKey: Any] = (try? FileManager.default.attributesOfItem(atPath: resolvedPath)) ?? [:]
            try data.write(to: URL(fileURLWithPath: temporaryPath), options: .atomic)
            if let permissions = attributes[.posixPermissions] as? NSNumber {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporaryPath)
            }
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: resolvedPath),
                withItemAt: URL(fileURLWithPath: temporaryPath)
            )
        } catch {
            // replaceItemAt can fail when the target does not exist; fall back to rename.
            do {
                if FileManager.default.fileExists(atPath: temporaryPath) {
                    try FileManager.default.moveItem(atPath: temporaryPath, toPath: resolvedPath)
                }
            } catch {
                FileHandle.standardError.write("Failed to write \(resolvedPath): \(error.localizedDescription)\n".data(using: .utf8)!)
            }
        }
    }

    func moveInvalidFile(_ path: String) -> String {
        let basePath = "\(path).invalid-\(Int(Date().timeIntervalSince1970 * 1000))-\(getpid())"
        var backupPath = basePath
        var counter = 1

        while FileManager.default.fileExists(atPath: backupPath) {
            backupPath = "\(basePath)-\(counter)"
            counter += 1
        }

        do {
            try FileManager.default.moveItem(atPath: path, toPath: backupPath)
        } catch {
            FileHandle.standardError.write("Failed to back up invalid file \(path): \(error.localizedDescription)\n".data(using: .utf8)!)
        }
        return backupPath
    }
}
