import Foundation

/// One profile as stored on disk: sanitized values plus its backing file path.
struct StoredProfile: Equatable, Sendable {
    var profile: ProxyProfile
    var filePath: String

    var name: String { profile.name }
    var state: ProxyState { profile.state }
}

/// Profile store over `~/.jpmanager/profiles/*.yaml`, ported from the
/// jpmanager profile-files/profile-store modules including conflict checks and
/// invalid-file recovery.
enum ProfileStore {
    // MARK: - Slugs and paths

    static func slugifyProfileName(_ profileName: String) -> String {
        let lowered = profileName.trimmingCharacters(in: .whitespaces).lowercased()
        var slug = ""
        var previousWasSeparator = false

        for character in lowered {
            if character.isLetter && character.asciiValue.map({ $0 < 128 }) == true,
               let ascii = character.asciiValue, ascii >= Character("a").asciiValue!, ascii <= Character("z").asciiValue! {
                slug.append(character)
                previousWasSeparator = false
            } else if let ascii = character.asciiValue,
                      (ascii >= Character("0").asciiValue! && ascii <= Character("9").asciiValue!)
                      || character == "." || character == "_" || character == "-" {
                slug.append(character)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                slug.append("-")
                previousWasSeparator = true
            }
        }

        while slug.hasPrefix("-") {
            slug.removeFirst()
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }

        return slug.isEmpty ? "profile" : slug
    }

    static func profileFilePath(_ profileName: String, context: ProxyFileContext) -> String {
        context.profilesDirectory + "/" + slugifyProfileName(profileName) + ".yaml"
    }

    // MARK: - Sanitization

    static func sanitize(_ profile: ProxyProfile) -> ProxyProfile {
        var sanitized = profile
        sanitized.name = profile.name.trimmingCharacters(in: .whitespaces)
        sanitized.state.httpProxy = profile.state.httpProxy.trimmingCharacters(in: .whitespaces)
        sanitized.state.httpsProxy = profile.state.httpsProxy.trimmingCharacters(in: .whitespaces)
        sanitized.state.socks5Proxy = profile.state.socks5Proxy.trimmingCharacters(in: .whitespaces)
        sanitized.state.noProxy = profile.state.noProxy.trimmingCharacters(in: .whitespaces)
        return sanitized
    }

    // MARK: - File IO

    static func parseProxyProfileDocument(_ document: MiniYAML.Value, sourceLabel: String) throws -> StoredProfile {
        let profileNode = document["profile"] ?? document
        var profile = ProxyProfile(name: "", state: .empty)
        profile.name = profileNode.string("name") ?? ""
        profile.state.httpProxy = profileNode.string("http_proxy") ?? ""
        profile.state.httpsProxy = profileNode.string("https_proxy") ?? ""
        profile.state.socks5Proxy = profileNode.string("socks5_proxy") ?? ""
        profile.state.noProxy = profileNode.string("no_proxy") ?? ""
        profile = sanitize(profile)

        guard !profile.name.isEmpty else {
            throw ProxyEngineError(message: "Proxy profile in \(sourceLabel) is missing name.")
        }

        return StoredProfile(profile: profile, filePath: sourceLabel)
    }

    static func readProxyProfileFile(_ filePath: String, context: ProxyFileContext) throws -> StoredProfile {
        let content = context.readTextFile(filePath)
        let document = try MiniYAML.parse(content)
        return try parseProxyProfileDocument(document, sourceLabel: filePath)
    }

    @discardableResult
    static func writeProxyProfileFile(_ profile: ProxyProfile, filePath: String, context: ProxyFileContext) -> StoredProfile {
        let sanitized = sanitize(profile)

        context.writeTextFile(filePath, emitProfileYAML(profile: sanitized))
        return StoredProfile(profile: sanitized, filePath: filePath)
    }

    /// Matches the jpmanager profile file layout, including the untyped
    /// `version: 1` scalar.
    private static func emitProfileYAML(profile: ProxyProfile) -> String {
        var lines = [
            "version: 1",
            "profile:"
        ]
        func field(_ key: String, _ value: String) {
            lines.append("  \(key): \(MiniYAML.quoteScalarIfNeeded(value))")
        }
        field("name", profile.name)
        field("http_proxy", profile.state.httpProxy)
        field("https_proxy", profile.state.httpsProxy)
        field("socks5_proxy", profile.state.socks5Proxy)
        field("no_proxy", profile.state.noProxy)
        return lines.joined(separator: "\n") + "\n"
    }

    static func ensureStore(context: ProxyFileContext) -> [StoredProfile] {
        let profilesDirectory = context.profilesDirectory

        do {
            try FileManager.default.createDirectory(atPath: profilesDirectory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write("Failed to create \(profilesDirectory): \(error.localizedDescription)\n".data(using: .utf8)!)
            return []
        }

        let fileNames = ((try? FileManager.default.contentsOfDirectory(atPath: profilesDirectory)) ?? [])
            .filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }
            .sorted()

        var profiles: [StoredProfile] = []
        for fileName in fileNames {
            let filePath = profilesDirectory + "/" + fileName
            do {
                profiles.append(try readProxyProfileFile(filePath, context: context))
            } catch {
                let backupPath = context.moveInvalidFile(filePath)
                FileHandle.standardError.write(
                    "Recovered invalid proxy profile file at \(filePath); original moved to \(backupPath).\n"
                        .data(using: .utf8)!
                )
            }
        }
        return profiles
    }

    static func findProfileByName(_ profiles: [StoredProfile], _ profileName: String) -> StoredProfile? {
        let normalizedName = profileName.trimmingCharacters(in: .whitespaces)
        return profiles.first(where: { $0.profile.name == normalizedName })
    }

    // MARK: - Validation and conflict checks

    private static func validateWritableProxyProfile(_ profile: ProxyProfile) throws {
        if profile.name.isEmpty {
            throw ProxyEngineError(message: "Proxy profile name is required.")
        }

        if profile.state.httpProxy.isEmpty
            && profile.state.httpsProxy.isEmpty
            && profile.state.socks5Proxy.isEmpty {
            throw ProxyEngineError(message: "At least one proxy value is required.")
        }
    }

    static func saveProxyProfile(
        _ profile: ProxyProfile,
        context: ProxyFileContext,
        allowOverwrite: Bool = false
    ) throws -> StoredProfile {
        let nextProxy = sanitize(profile)
        try validateWritableProxyProfile(nextProxy)

        let profiles = ensureStore(context: context)
        let targetFilePath = profileFilePath(nextProxy.name, context: context)

        if let existingIndex = profiles.firstIndex(where: { $0.profile.name == nextProxy.name }) {
            if !allowOverwrite {
                throw ProxyEngineError(
                    message: "Proxy profile \"\(nextProxy.name)\" already exists. Re-run with --force to override."
                )
            }
            let existingFilePath = profiles[existingIndex].filePath
            if !existingFilePath.isEmpty,
               existingFilePath != targetFilePath,
               FileManager.default.fileExists(atPath: existingFilePath) {
                try? FileManager.default.removeItem(atPath: existingFilePath)
            }
        } else if FileManager.default.fileExists(atPath: targetFilePath), !allowOverwrite {
            throw ProxyEngineError(
                message: "Proxy profile file \"\(targetFilePath)\" already exists. Re-run with --force to override."
            )
        } else if let conflicting = profiles.first(where: { $0.filePath == targetFilePath }), !allowOverwrite {
            _ = conflicting
            throw ProxyEngineError(
                message: "Proxy profile file \"\(targetFilePath)\" already exists. Re-run with --force to override."
            )
        }

        return writeProxyProfileFile(nextProxy, filePath: targetFilePath, context: context)
    }

    struct ProxyProfileUpdates {
        var name: String?
        var httpProxy: String?
        var httpsProxy: String?
        var socks5Proxy: String?
        var noProxy: String?
    }

    static func editProxyProfile(
        _ profileName: String,
        updates: ProxyProfileUpdates,
        context: ProxyFileContext,
        allowOverwrite: Bool = false
    ) throws -> StoredProfile {
        let profiles = ensureStore(context: context)
        let normalizedName = profileName.trimmingCharacters(in: .whitespaces)

        guard let existingIndex = profiles.firstIndex(where: { $0.profile.name == normalizedName }) else {
            throw ProxyEngineError(message: "Proxy profile \"\(normalizedName)\" does not exist.")
        }

        let existingProxy = profiles[existingIndex].profile
        var nextProfile = existingProxy

        if let updatedName = updates.name?.trimmingCharacters(in: .whitespaces), !updatedName.isEmpty {
            nextProfile.name = updatedName
        }
        if let httpProxy = updates.httpProxy {
            nextProfile.state.httpProxy = httpProxy.trimmingCharacters(in: .whitespaces)
        }
        if let httpsProxy = updates.httpsProxy {
            nextProfile.state.httpsProxy = httpsProxy.trimmingCharacters(in: .whitespaces)
        }
        if let socks5Proxy = updates.socks5Proxy {
            nextProfile.state.socks5Proxy = socks5Proxy.trimmingCharacters(in: .whitespaces)
        }
        if let noProxy = updates.noProxy {
            nextProfile.state.noProxy = noProxy.trimmingCharacters(in: .whitespaces)
        }
        nextProfile = sanitize(nextProfile)

        try validateWritableProxyProfile(nextProfile)

        let conflictingIndex = profiles.enumerated()
            .first(where: { index, stored in stored.profile.name == nextProfile.name && index != existingIndex })
            .map(\.offset)

        if let conflictingIndex, !allowOverwrite {
            throw ProxyEngineError(
                message: "Proxy profile \"\(nextProfile.name)\" already exists. Re-run with --force to override."
            )
        }

        let existingFilePath = profiles[existingIndex].filePath
        let nextFilePath = profileFilePath(nextProfile.name, context: context)
        let renamingFile = existingFilePath != nextFilePath
        let conflictingFileIndex = profiles.enumerated()
            .first(where: { index, stored in stored.filePath == nextFilePath && index != existingIndex })
            .map(\.offset)

        if renamingFile,
           (FileManager.default.fileExists(atPath: nextFilePath) || conflictingFileIndex != nil),
           !allowOverwrite {
            throw ProxyEngineError(
                message: "Proxy profile \"\(nextProfile.name)\" already exists. Re-run with --force to override."
            )
        }

        if let conflictingIndex {
            let conflictingFilePath = profiles[conflictingIndex].filePath
            if conflictingFilePath != existingFilePath {
                try? FileManager.default.removeItem(atPath: conflictingFilePath)
            }
        } else if let conflictingFileIndex {
            try? FileManager.default.removeItem(atPath: profiles[conflictingFileIndex].filePath)
        }

        let savedProfile = writeProxyProfileFile(nextProfile, filePath: nextFilePath, context: context)
        if renamingFile {
            try? FileManager.default.removeItem(atPath: existingFilePath)
        }

        return savedProfile
    }
}
