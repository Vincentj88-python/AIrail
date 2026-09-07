import Foundation
import XCTest
@testable import AIrail

/// The shape of a JSON document, for catching an endpoint that moved: every
/// key path it contains, and a copy with nothing personal left in it.
enum JSONShape {
    /// Every key path, dotted, with arrays as "[]": a fixture's paths must
    /// all still appear in the live reply for the parser to be safe.
    static func paths(of object: Any, prefix: String = "") -> Set<String> {
        var result: Set<String> = []
        switch object {
        case let dictionary as [String: Any]:
            for (key, value) in dictionary {
                let path = prefix.isEmpty ? key : prefix + "." + key
                result.insert(path)
                result.formUnion(paths(of: value, prefix: path))
            }
        case let array as [Any]:
            let path = prefix + "[]"
            for element in array { result.formUnion(paths(of: element, prefix: path)) }
        default:
            break
        }
        return result
    }

    /// Strings are kept only under keys known to carry no personal data
    /// (plan names, model ids, dates, currencies); every other string becomes
    /// "…". Numbers, booleans, null and the structure stay, which is all a
    /// parser test needs.
    static let safeStringKeys: Set<String> = [
        "plan_type", "copilot_plan", "membershipType", "model", "label", "currency", "limit_reset", "limit_id",
        "starting_at", "ending_at", "resets_at", "reset_at", "start_time", "end_time",
        "billingCycleStart", "billingCycleEnd", "quota_reset_date", "quota_reset_date_utc",
        "autoModelSelectedDisplayMessage", "namedModelSelectedDisplayMessage", "bucket_width",
    ]

    static func redacted(_ object: Any, key: String? = nil) -> Any {
        switch object {
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [String: Any]()) { $0[$1.key] = redacted($1.value, key: $1.key) }
        case let array as [Any]:
            return array.map { redacted($0, key: key) }
        case is String:
            return key.map { safeStringKeys.contains($0) } == true ? object : "…"
        default:
            return object
        }
    }

    /// The fixture folder next to the tests, whatever the working directory.
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures", directoryHint: .isDirectory)
    }

    /// One file per endpoint: "api.anthropic.com_api_oauth_usage.json".
    static func fixtureURL(for url: URL) -> URL {
        let name = ((url.host() ?? "host") + url.path()).replacingOccurrences(of: "/", with: "_")
        return directory.appending(path: name + ".json")
    }
}

/// Records every live reply, redacted, when `AIRAIL_RECORD_FIXTURES=1`, and
/// otherwise checks each reply against the fixture on disk: every key path
/// the fixture had must still be there, or the endpoint has moved.
final class FixtureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(url: URL, data: Data)] = []
    let recording: Bool

    init(recording: Bool) {
        self.recording = recording
    }

    func note(_ url: URL, _ data: Data) {
        lock.lock()
        replies.append((url, data))
        lock.unlock()
    }

    /// Writes (when recording) or verifies (otherwise) everything noted so far.
    func settle(file: StaticString = #filePath, line: UInt = #line) throws {
        lock.lock()
        let noted = replies
        replies = []
        lock.unlock()
        for (url, data) in noted {
            guard let live = try? JSONSerialization.jsonObject(with: data) else { continue }
            let fixtureURL = JSONShape.fixtureURL(for: url)
            if recording {
                try FileManager.default.createDirectory(at: JSONShape.directory, withIntermediateDirectories: true)
                let redacted = try JSONSerialization.data(withJSONObject: JSONShape.redacted(live), options: [.prettyPrinted, .sortedKeys])
                try redacted.write(to: fixtureURL, options: .atomic)
                print("recorded", fixtureURL.lastPathComponent)
            } else if let data = try? Data(contentsOf: fixtureURL), let fixture = try? JSONSerialization.jsonObject(with: data) {
                let missing = JSONShape.paths(of: fixture).subtracting(JSONShape.paths(of: live))
                XCTAssertTrue(missing.isEmpty, "\(url.host() ?? "") no longer sends \(missing.sorted().joined(separator: ", ")) — the endpoint moved", file: file, line: line)
            }
        }
    }
}
