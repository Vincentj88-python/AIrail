import Foundation

/// One pace sample: when, and the ring percent then.
struct PercentSample: Codable, Sendable, Equatable {
    var date: Date
    var percent: Double
}

/// One day's level of a feedless account (Copilot's used count), so the
/// day-to-day difference can stand in for the per-request feed it lacks.
struct UsageLevelSample: Codable, Sendable, Equatable {
    var date: Date
    var used: Double
    var resetsAt: Date?
}

/// What one account keeps on disk between launches: its last real numbers,
/// its daily totals for up to a year, the pace samples, and for a feedless
/// account its daily levels. Never a token, a key, or who is signed in.
struct UsageLedger: Codable, Sendable, Equatable {
    var version = 1
    var lastSnapshot: UsageSnapshot?
    var days: [UsageBucket] = []
    var percentSamples: [PercentSample] = []
    var sampleWindow: Date?
    var levels: [UsageLevelSample] = []

    static let retentionDays = 366

    /// Folds a read in: the snapshot (account stripped), its days upserted by
    /// start date and pruned to a year, and the pace samples as they stand.
    mutating func record(
        _ snapshot: UsageSnapshot, samples: [PercentSample], window: Date?, now: Date, calendar: Calendar = .current
    ) {
        var stored = snapshot
        stored.account = nil
        lastSnapshot = stored
        for bucket in snapshot.detail.days {
            if let index = days.firstIndex(where: { $0.start == bucket.start }) {
                days[index] = bucket
            } else {
                days.append(bucket)
            }
        }
        days.sort { $0.start < $1.start }
        let cutoff = Self.cutoff(now: now, calendar: calendar)
        days.removeAll { $0.start < cutoff }
        levels.removeAll { $0.date < cutoff }
        percentSamples = samples
        sampleWindow = window
    }

    /// Today's level of a feedless account, one sample per day (the latest wins).
    mutating func recordLevel(_ snapshot: UsageSnapshot, now: Date, calendar: Calendar = .current) {
        guard let used = snapshot.weeklyUsed else { return }
        let today = calendar.startOfDay(for: now)
        let sample = UsageLevelSample(date: today, used: used, resetsAt: snapshot.weeklyResetsAt)
        if let index = levels.firstIndex(where: { $0.date == today }) {
            levels[index] = sample
        } else {
            levels.append(sample)
            levels.sort { $0.date < $1.date }
        }
    }

    /// Daily buckets for a feedless account from its levels: a day's usage is
    /// its level minus the day before's when both were sampled in the same
    /// window, or the level itself when the pool reset in between. Days that
    /// weren't sampled on consecutive days stay at zero rather than having a
    /// gap spread across them; nothing at all until two consecutive days exist.
    func derivedDays(count: Int, now: Date, calendar: Calendar = .current) -> [UsageBucket] {
        var byDay: [Date: UsageAggregate] = [:]
        var derivedAny = false
        for (index, sample) in levels.enumerated() where index > 0 {
            let previous = levels[index - 1]
            guard calendar.date(byAdding: .day, value: 1, to: previous.date) == sample.date else { continue }
            var usage = UsageAggregate()
            if sample.used >= previous.used, sample.resetsAt == previous.resetsAt {
                usage.messages = Int((sample.used - previous.used).rounded())
            } else if sample.used < previous.used || sample.resetsAt != previous.resetsAt {
                usage.messages = Int(sample.used.rounded())
            }
            byDay[sample.date] = usage
            derivedAny = true
        }
        guard derivedAny else { return [] }
        return UsageBucketing.series(byDay, count: count, component: .day, endingAt: now, calendar: calendar)
    }

    private static func cutoff(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -(retentionDays - 1), to: calendar.startOfDay(for: now)) ?? now
    }
}

/// The ledgers on disk: one JSON file per account under
/// ~/Library/Application Support/AIrail/usage, written atomically and only
/// when the bytes change, deleted when the account is removed.
actor UsageStore {
    private let directory: URL
    private var lastWritten: [String: Data] = [:]

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The app's own folder in Application Support; tests pass a temporary one.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    static var defaultDirectory: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return support.appending(path: "AIrail/usage", directoryHint: .isDirectory)
    }

    func load(_ providerId: String) -> UsageLedger? {
        guard let data = try? Data(contentsOf: url(for: providerId)) else { return nil }
        lastWritten[providerId] = data
        return try? Self.decoder.decode(UsageLedger.self, from: data)
    }

    func save(_ ledger: UsageLedger, for providerId: String) throws {
        let data = try Self.encoder.encode(ledger)
        guard data != lastWritten[providerId] else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: providerId), options: .atomic)
        lastWritten[providerId] = data
    }

    func delete(_ providerId: String) {
        try? FileManager.default.removeItem(at: url(for: providerId))
        lastWritten[providerId] = nil
    }

    /// Everything AIrail has kept, gone.
    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
        lastWritten = [:]
    }

    private func url(for providerId: String) -> URL {
        let safe = providerId.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" }
        return directory.appending(path: String(safe) + ".json")
    }
}
