import Foundation

/// What one transcript line contributes. Tool-only lines carry no tokens and
/// don't count as a message; streamed duplicates share a `dedupKey` so their
/// tokens count once while their tool calls still all count.
struct TranscriptEvent: Sendable {
    let date: Date
    var tokens = TokenSplit()
    var thinking: Double = 0
    var model: String? = nil
    var project: String? = nil
    var session: String? = nil
    var toolCalls: [String] = []
    var countsAsMessage = true
    var dedupKey: String? = nil
}

/// Per-file facts that later lines depend on (Codex names the model and
/// working directory once per turn, not on every token event).
struct TranscriptContext: Sendable {
    var model: String?
    var project: String?
    var session: String?
}

/// Incrementally tallies usage from append-only JSONL transcripts (Claude
/// Code's `~/.claude/projects`, Codex's `~/.codex/sessions`). Each file is read
/// from where the previous scan stopped, so a refresh costs roughly what was
/// written since; the full history is parsed only once.
actor TranscriptScanner {
    typealias Extractor = @Sendable (JSONObject, inout TranscriptContext) -> TranscriptEvent?

    struct Summary: Sendable {
        var hours: [UsageBucket]
        var days: [UsageBucket]
        var week: UsageAggregate
        /// The seven days before `days`, summed, for the week-over-week comparison.
        var previousWeek = UsageAggregate()
        /// When the newest counted line was written — the last moment this
        /// Mac's tool did anything, for the "used elsewhere" observation.
        var newestEventDate: Date? = nil
    }

    private struct FileState {
        var offset: UInt64 = 0
        var hours: [Date: UsageAggregate] = [:]
        var days: [Date: UsageAggregate] = [:]
        var seenKeys: Set<String> = []
        var context = TranscriptContext()
        var newestEvent: Date? = nil
    }

    private let roots: [URL]
    private let requiredSubstrings: [Data]
    private let extractor: Extractor
    private let calendar: Calendar
    private var files: [String: FileState] = [:]

    /// - Parameters:
    ///   - roots: directories searched recursively for `.jsonl` files.
    ///   - requiredSubstrings: cheap pre-filter; lines containing none of these are never JSON-decoded.
    ///   - extractor: turns one decoded line into an event, or nil to skip it.
    init(
        roots: [URL],
        requiredSubstrings: [String] = [],
        calendar: Calendar = .current,
        extractor: @escaping Extractor
    ) {
        self.roots = roots
        self.requiredSubstrings = requiredSubstrings.map { Data($0.utf8) }
        self.calendar = calendar
        self.extractor = extractor
    }

    /// The last 24 hours by hour, the last 7 days by day, the week's totals,
    /// and the week before that (`lookbackDays` reaches back far enough for
    /// it; the series and `week` stay `dayCount` long).
    func summary(days dayCount: Int = 7, hours hourCount: Int = 24, lookbackDays: Int = 14, now: Date = Date()) throws -> Summary {
        let today = calendar.startOfDay(for: now)
        let dayCutoff = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? now
        let lookbackCutoff = calendar.date(byAdding: .day, value: -(max(lookbackDays, dayCount) - 1), to: today) ?? dayCutoff
        let hourCutoff = UsageBucketing.floor(now.addingTimeInterval(-Double(hourCount - 1) * 3600), to: .hour, calendar: calendar)
        try scan(since: lookbackCutoff, pruningHoursBefore: hourCutoff)

        var hours: [Date: UsageAggregate] = [:]
        var days: [Date: UsageAggregate] = [:]
        var week = UsageAggregate()
        var previousWeek = UsageAggregate()
        var newest: Date?
        for state in files.values {
            for (hour, usage) in state.hours where hour >= hourCutoff {
                hours[hour, default: UsageAggregate()].merge(usage)
            }
            for (day, usage) in state.days {
                if day >= dayCutoff {
                    days[day, default: UsageAggregate()].merge(usage)
                    week.merge(usage)
                } else if day >= lookbackCutoff {
                    previousWeek.merge(usage)
                }
            }
            if let date = state.newestEvent, newest.map({ date > $0 }) ?? true {
                newest = date
            }
        }
        return Summary(
            hours: UsageBucketing.series(hours, count: hourCount, component: .hour, endingAt: now, calendar: calendar),
            days: UsageBucketing.series(days, count: dayCount, component: .day, endingAt: now, calendar: calendar),
            week: week,
            previousWeek: previousWeek,
            newestEventDate: newest
        )
    }

    // MARK: Scanning

    private func scan(since cutoff: Date, pruningHoursBefore hourCutoff: Date) throws {
        var live: Set<String> = []
        for url in transcriptFiles(modifiedSince: cutoff) {
            live.insert(url.path)
            try scanFile(url)
        }
        files = files.filter { live.contains($0.key) }
        for (path, state) in files {
            var pruned = state
            pruned.hours = state.hours.filter { $0.key >= hourCutoff }
            pruned.days = state.days.filter { $0.key >= cutoff }
            files[path] = pruned
        }
    }

    private func transcriptFiles(modifiedSince cutoff: Date) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        var result: [URL] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      modified >= cutoff
                else { continue }
                result.append(url)
            }
        }
        return result
    }

    private func scanFile(_ url: URL) throws {
        let path = url.path
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        var state = files[path] ?? FileState()
        if size < state.offset {
            state = FileState() // rewritten, start over
        }
        guard size > state.offset else {
            files[path] = state
            return
        }
        try handle.seek(toOffset: state.offset)
        let data = try handle.readToEnd() ?? Data()

        // Consume whole lines only; a half-written last line waits for the next scan.
        var consumed = data.count
        if data.last != 0x0A {
            consumed = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            let tail = data[consumed...]
            if !tail.isEmpty, (try? JSONSerialization.jsonObject(with: tail)) != nil {
                consumed = data.count
            }
        }
        for line in data[..<consumed].split(separator: 0x0A) {
            ingest(line, into: &state)
        }
        state.offset += UInt64(consumed)
        files[path] = state
    }

    private func ingest(_ line: Data.SubSequence, into state: inout FileState) {
        if !requiredSubstrings.isEmpty, !requiredSubstrings.contains(where: { line.range(of: $0) != nil }) {
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = extractor(JSONObject(object), &state.context)
        else { return }

        var contribution = UsageAggregate()
        for tool in event.toolCalls {
            contribution.toolCalls[tool, default: 0] += 1
        }
        let duplicate = event.dedupKey.map { !state.seenKeys.insert($0).inserted } ?? false
        if !duplicate {
            contribution.tokens = event.tokens
            contribution.thinking = event.thinking
            contribution.messages = event.countsAsMessage ? 1 : 0
            if let model = event.model, event.tokens.total > 0 {
                contribution.models[model] = event.tokens.total
            }
            if let project = event.project, event.tokens.total > 0 {
                contribution.projects[project] = event.tokens.total
            }
            if event.tokens.total > 0 {
                contribution.splits[UsageKey(model: event.model, project: event.project)] = event.tokens
            }
            if let session = event.session, event.countsAsMessage {
                contribution.sessions.insert(session)
            }
        }
        guard !contribution.isEmpty else { return }
        if state.newestEvent.map({ event.date > $0 }) ?? true {
            state.newestEvent = event.date
        }

        let hour = UsageBucketing.floor(event.date, to: .hour, calendar: calendar)
        let day = calendar.startOfDay(for: event.date)
        state.hours[hour, default: UsageAggregate()].merge(contribution)
        state.days[day, default: UsageAggregate()].merge(contribution)
    }
}
