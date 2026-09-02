import Foundation

/// The only network path in the app: one GET per provider per refresh, to the
/// provider's own usage endpoint, carrying the sign-in that tool already holds.
enum HTTPClient {
    struct Response: Sendable {
        let status: Int
        let data: Data
    }

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

    private static func send(_ url: URL, method: String, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> Response {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("AIrail", forHTTPHeaderField: "User-Agent")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Response(status: status, data: data)
        } catch {
            throw ConnectionError.network(error.localizedDescription)
        }
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
            return response.data
        case 401, 403:
            throw ConnectionError.expired(tool: tool)
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
