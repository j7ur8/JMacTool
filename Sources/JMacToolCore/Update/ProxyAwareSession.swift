import Foundation

/// URLSession helpers that survive a broken system proxy path. Two failure
/// shapes trigger one retry bypassing all proxies: connectivity errors (a
/// proxy app configured system-wide but not running) and HTTP 4xx/5xx
/// answers from the proxy chain (the connection is alive, but APIs such as
/// GitHub's reject shared proxy exit IPs outright while a direct connection
/// succeeds).
enum ProxyAwareSession {
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, shouldBypassProxyForStatus(http.statusCode) {
                return try await bypassingSession().data(for: request)
            }
            return (data, response)
        } catch let error as URLError where isConnectivityFailure(error) {
            return try await bypassingSession().data(for: request)
        }
    }

    static func download(from url: URL) async throws -> (URL, URLResponse) {
        do {
            let (downloadedURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, shouldBypassProxyForStatus(http.statusCode) {
                return try await bypassingSession().download(from: url)
            }
            return (downloadedURL, response)
        } catch let error as URLError where isConnectivityFailure(error) {
            return try await bypassingSession().download(from: url)
        }
    }

    /// Whether an HTTP error status received through the system proxy warrants
    /// a direct retry. 4xx/5xx responses complete normally (no URLError), and
    /// the status describes the far end, not the local proxy path, so the
    /// direct route may well succeed.
    static func shouldBypassProxyForStatus(_ statusCode: Int) -> Bool {
        (400...599).contains(statusCode)
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
