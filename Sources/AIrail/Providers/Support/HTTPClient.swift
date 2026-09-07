import Foundation

/// The only network path in the app: one GET per provider per refresh, to the
/// provider's own usage endpoint, carrying the sign-in that tool already holds
/// (plus the release check). Everything goes through one ephemeral session that
/// keeps no cache and no cookie jar and can only reach `allowedHosts`.
enum HTTPClient {
    struct Response: Sendable {
        let status: Int
        let data: Data
        var retryAfter: Date? = nil
    }

    /// Every host AIrail will ever contact. A request or redirect anywhere
    /// else is refused before a task exists; README names these same seven.
    static let allowedHosts: Set<String> = [
        "api.anthropic.com", // Claude Code's OAuth usage; the Anthropic API usage report
        "chatgpt.com",       // Codex's usage windows
        "api.github.com",    // Copilot's quota; the release check
        "cursor.com",        // Cursor's dashboard reads
        "openrouter.ai",     // OpenRouter key limit and credits
        "api.deepseek.com",  // DeepSeek balance
        "api.openai.com",    // the OpenAI API usage report
    ]

    /// One session for the life of the process: ephemeral, so nothing touches
    /// disk; no URL cache and no cookie storage at all, so a usage body or an
    /// edge-gateway cookie never outlives its request; and a delegate that
    /// refuses redirects off the list. Waiting for connectivity (bounded by
    /// the resource timeout) is what lets a wake-from-sleep read succeed
    /// instead of failing while the network is still coming up.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = ["User-Agent": "AIrail"]
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    /// What the session was built with — a copy, so nothing can change it —
    /// and whether the redirect guard is attached. Read by the tests; nothing
    /// outside this type touches the session itself.
    static var configuration: URLSessionConfiguration { session.configuration }
    static var hasRedirectGuard: Bool { session.delegate is URLSessionTaskDelegate }

    static func get(_ url: URL, headers: [String: String], timeout: TimeInterval = 15) async throws -> Response {
        try await send(url, method: "GET", headers: headers, body: nil, timeout: timeout)
    }

    /// POST with a JSON body; only Cursor's dashboard needs it (its read
    /// endpoints are POSTs that also insist on an `Origin` header).
    static func postJSON(_ url: URL, headers: [String: String], body: [String: Any], timeout: TimeInterval = 20) async throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: body)
        var headers = headers
        headers["Content-Type"] = "application/json"
        return try await send(url, method: "POST", headers: headers, body: data, timeout: timeout)
    }

    /// A test-only tap on every reply, for recording redacted fixtures
    /// (`LiveProviderTests`). Set before any request; never set by the app.
    nonisolated(unsafe) static var recorder: (@Sendable (URL, Data) -> Void)?

    private static func send(_ url: URL, method: String, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> Response {
        try check(url)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ConnectionError.network(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        // Host and status only — headers carry sign-ins, bodies carry usage.
        Log.network.info("\(url.host() ?? "?", privacy: .public) \(status, privacy: .public)")
        recorder?(url, data)
        // A redirect gets this far only because `RedirectGuard` refused to
        // follow it, so say where it pointed rather than "HTTP 302".
        if (300..<400).contains(status), let location = http?.value(forHTTPHeaderField: "Location") {
            let target = URL(string: location, relativeTo: url)?.absoluteURL
            throw ConnectionError.blockedHost(target.map(blockedName) ?? location)
        }
        return Response(
            status: status,
            data: data,
            retryAfter: (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(Self.retryAfterDate)
        )
    }

    // MARK: Allowlist

    /// Refuses, before any task exists, anything that isn't https to a host on
    /// `allowedHosts` — the one guard `send` and the redirect delegate share.
    static func check(_ url: URL) throws {
        guard isAllowed(url) else {
            throw ConnectionError.blockedHost(blockedName(url))
        }
    }

    /// What a `blockedHost` error names: the bare host when the host itself
    /// is off the list, or scheme, host and any port ("http://api.anthropic.com")
    /// when the host is allowed but the way of reaching it is not — the message
    /// must never blame a host AIrail does connect to.
    static func blockedName(_ url: URL) -> String {
        guard let host = url.host()?.lowercased() else { return url.absoluteString }
        guard allowedHosts.contains(host) else { return host }
        let scheme = url.scheme?.lowercased() ?? "?"
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.port == nil,
              let host = url.host()?.lowercased()
        else { return false }
        return allowedHosts.contains(host)
    }

    /// Session delegate: a redirect may only land on the list. Completing
    /// with nil delivers the 3xx itself instead, which `send` then names.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(HTTPClient.isAllowed(request.url) ? request : nil)
        }
    }

    // MARK: Legacy stores

    /// v0.2.0 went through `URLSession.shared`, whose disk cache kept usage
    /// responses under ~/Library/Caches and whose cookie jar kept edge-gateway
    /// cookies under ~/Library/HTTPStorages. The session above never opens
    /// either, so those artefacts — and only those — are removed at launch, a
    /// no-op once gone: the cache database with its journal and body files,
    /// and the cookie file. The cache directory itself, anything else in it,
    /// and the bundle's `HTTPStorages/<id>/httpstorages.sqlite` (Alt-Svc
    /// hints, no personal data) are left alone.
    static func removeLegacyStores(
        bundleId: String? = Bundle.main.bundleIdentifier,
        library: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Library")
    ) {
        guard let bundleId, !bundleId.isEmpty else { return }
        let manager = FileManager.default
        let cache = library.appending(path: "Caches/\(bundleId)")
        let leftovers = [
            cache.appending(path: "Cache.db"),
            cache.appending(path: "Cache.db-shm"),
            cache.appending(path: "Cache.db-wal"),
            cache.appending(path: "fsCachedData"),
            library.appending(path: "HTTPStorages/\(bundleId).binarycookies"),
        ]
        for url in leftovers where manager.fileExists(atPath: url.path) {
            try? manager.removeItem(at: url)
        }
    }

    /// Retry-After is either a number of seconds or an HTTP date.
    private static func retryAfterDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(trimmed) {
            return Date().addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: trimmed)
    }

    /// GET that treats an auth failure as an expired sign-in for `tool`.
    static func authorizedGet(_ url: URL, headers: [String: String], tool: String) async throws -> Data {
        try unwrap(try await get(url, headers: headers), tool: tool)
    }

    static func authorizedPost(_ url: URL, headers: [String: String], body: [String: Any], tool: String) async throws -> Data {
        try unwrap(try await postJSON(url, headers: headers, body: body), tool: tool)
    }

    private static func unwrap(_ response: Response, tool: String) throws -> Data {
        switch response.status {
        case 200..<300:
            // A 2xx that isn't JSON is a captive portal or an edge page, not
            // the service: a retry fixes it, so it must not blank the account.
            guard (try? JSONSerialization.jsonObject(with: response.data)) != nil else {
                throw ConnectionError.network("unexpected response")
            }
            return response.data
        case 401, 403:
            // A JSON refusal is the service saying the sign-in is no good; an
            // HTML page with that status is an edge or proxy, not the service.
            guard (try? JSONSerialization.jsonObject(with: response.data)) != nil else {
                throw ConnectionError.network("HTTP \(response.status), not a reply from the service")
            }
            throw ConnectionError.expired(tool: tool)
        case 429:
            throw ConnectionError.rateLimited(tool: tool, retryAfter: response.retryAfter)
        default:
            throw ConnectionError.network("HTTP \(response.status)")
        }
    }
}

/// Minimal typed access into `JSONSerialization` output.
struct JSONObject {
    let raw: [String: Any]

    init(_ raw: [String: Any]) {
        self.raw = raw
    }

    init(data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectionError.unreadable("unexpected response format")
        }
        raw = object
    }

    subscript(_ key: String) -> JSONObject? {
        (raw[key] as? [String: Any]).map(JSONObject.init)
    }

    /// The top-level keys, sorted — what a shape-drift error reports.
    var keyNames: String {
        "keys: " + (raw.keys.sorted().joined(separator: ", ").isEmpty ? "none" : raw.keys.sorted().joined(separator: ", "))
    }

    func string(_ key: String) -> String? {
        raw[key] as? String
    }

    func double(_ key: String) -> Double? {
        switch raw[key] {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    func bool(_ key: String) -> Bool? {
        raw[key] as? Bool
    }

    func array(_ key: String) -> [JSONObject] {
        (raw[key] as? [[String: Any]])?.map(JSONObject.init) ?? []
    }
}

enum DateParsing {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dayOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Parses ISO 8601 with any number of fractional digits (Anthropic sends
    /// six, Foundation only understands three) or none at all.
    static func iso8601(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = fractional.date(from: text) ?? plain.date(from: text) {
            return date
        }
        // Trim the fraction to three digits: "…:00.479395+00:00" → "…:00.479+00:00".
        guard let dot = text.firstIndex(of: ".") else { return nil }
        var end = text.index(after: dot)
        while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
        let digits = text[text.index(after: dot)..<end]
        let trimmed = text[..<dot] + "." + digits.prefix(3) + text[end...]
        return fractional.date(from: String(trimmed))
    }

    static func unixSeconds(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// "2026-10-01" → that day at 00:00 UTC.
    static func day(_ text: String?) -> Date? {
        guard let text else { return nil }
        return dayOnly.date(from: text)
    }
}
