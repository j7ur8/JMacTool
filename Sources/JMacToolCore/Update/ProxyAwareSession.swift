import Foundation

/// URLSession helpers that survive a dead system proxy: when the proxied
/// connection fails with a connectivity error, retry once bypassing all
/// proxies (common case: a proxy app that is configured system-wide but not
/// currently running).
enum ProxyAwareSession {
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where isConnectivityFailure(error) {
            return try await bypassingSession().data(for: request)
        }
    }

    static func download(from url: URL) async throws -> (URL, URLResponse) {
        do {
            return try await URLSession.shared.download(from: url)
        } catch let error as URLError where isConnectivityFailure(error) {
            return try await bypassingSession().download(from: url)
        }
    }

    static func isConnectivityFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    private static func bypassingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }
}
