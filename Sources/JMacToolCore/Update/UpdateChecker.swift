import Foundation

/// Talks to the GitHub Releases API and decides whether an update is newer
/// than the running app.
enum UpdateChecker {
    struct UpdateInfo: Equatable {
        let tag: String
        let version: String
        let downloadURL: URL
    }

    static let repositoryOwner = "j7ur8"
    static let repositoryName = "JMacTool"

    // MARK: - Version comparison

    static func normalizedVersionComponents(_ version: String) -> [Int]? {
        var value = version.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("v") {
            value.removeFirst()
        }

        let parts = value.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else {
            return nil
        }
        return parts.map { $0! }
    }

    static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        guard let candidateComponents = normalizedVersionComponents(candidate),
              let currentComponents = normalizedVersionComponents(current) else {
            return false
        }

        for index in 0 ..< max(candidateComponents.count, currentComponents.count) {
            let candidatePart = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentPart = index < currentComponents.count ? currentComponents[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }
        return false
    }

    static func currentAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // MARK: - GitHub Releases

    static func latestReleaseAPIURL() -> URL {
        URL(string: "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest")!
    }

    struct ReleasePayload: Decodable {
        let tagName: String
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            private enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
    }

    /// Pure parser, unit tested against the real payload shape.
    static func parseLatestRelease(_ data: Data) -> UpdateInfo? {
        guard let payload = try? JSONDecoder().decode(ReleasePayload.self, from: data) else {
            return nil
        }

        let expectedAssetName = "JMacTool-\(payload.tagName)-macos.zip"
        guard let asset = payload.assets.first(where: { $0.name == expectedAssetName }),
              let downloadURL = URL(string: asset.browserDownloadURL) else {
            return nil
        }

        let version = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName
        return UpdateInfo(tag: payload.tagName, version: version, downloadURL: downloadURL)
    }

    /// Returns the newer release, or nil when already up to date.
    static func fetchLatestRelease() async throws -> UpdateInfo? {
        var request = URLRequest(url: latestReleaseAPIURL())
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.releaseLookupFailed
        }

        guard let info = parseLatestRelease(data) else {
            return nil
        }

        return isNewerVersion(info.version, than: currentAppVersion()) ? info : nil
    }
}

enum UpdateError: Error, LocalizedError {
    case releaseLookupFailed
    case notRunningFromAppBundle
    case downloadFailed(statusCode: Int)
    case extractedAppNotFound
    case signatureVerificationFailed
    case identityMismatch(expected: String)
    case installStepFailed(step: String)

    var errorDescription: String? {
        switch self {
        case .releaseLookupFailed:
            return "无法查询 GitHub Releases。"
        case .notRunningFromAppBundle:
            return "当前不是从 JMacTool.app 内运行的，无法自动更新。"
        case .downloadFailed(let statusCode):
            return "下载更新失败（HTTP \(statusCode)）。"
        case .extractedAppNotFound:
            return "下载包中没有找到 JMacTool.app。"
        case .signatureVerificationFailed:
            return "下载包签名校验失败，已取消安装。"
        case .identityMismatch(let expected):
            return "下载包的签名身份与本地不符（期望 \(expected)），已取消安装。"
        case .installStepFailed(let step):
            return "更新准备失败：\(step)。"
        }
    }
}
