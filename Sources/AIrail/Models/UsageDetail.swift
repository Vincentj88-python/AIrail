import Foundation

/// Tokens broken down the way every provider reports them. `input` is the
/// uncached part; the four add up to the total.
struct TokenSplit: Sendable, Equatable {
    var input: Double = 0
    var output: Double = 0
    var cacheWrite: Double = 0
    var cacheRead: Double = 0

    var total: Double { input + output + cacheWrite + cacheRead }

    static func + (lhs: TokenSplit, rhs: TokenSplit) -> TokenSplit {
        TokenSplit(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }

    static func += (lhs: inout TokenSplit, rhs: TokenSplit) {
        lhs = lhs + rhs
    }

    static func * (lhs: TokenSplit, rhs: Double) -> TokenSplit {
        TokenSplit(input: lhs.input * rhs, output: lhs.output * rhs, cacheWrite: lhs.cacheWrite * rhs, cacheRead: lhs.cacheRead * rhs)
    }
}

/// One model in one project — the grain at which token mixes are kept, so
/// cost can be priced per model and summed per project.
struct UsageKey: Hashable, Sendable {
    var model: String? = nil
    var project: String? = nil
}

/// Everything counted within one time bucket (an hour, a day, or a week).
struct UsageAggregate: Sendable, Equatable {
    var tokens = TokenSplit()
    /// Thinking / reasoning tokens, a subset of `tokens.output`.
    var thinking: Double = 0
    /// Requests (assistant messages, Codex turns, Cursor calls).
    var messages = 0
    var models: [String: Double] = [:]
    var toolCalls: [String: Int] = [:]
    var projects: [String: Double] = [:]
    var sessions: Set<String> = []
    /// Money the provider itself attributes to this usage, when it says.
    var cost: Double = 0
    /// The token mix per model and project, for pricing; `models` and
    /// `projects` are the totals of these.
    var splits: [UsageKey: TokenSplit] = [:]
    /// Money the provider itself attributes per model (Cursor's cents), USD.
    var costs: [String: Double] = [:]

    var isEmpty: Bool { messages == 0 && toolCalls.isEmpty && tokens.total == 0 }

    mutating func merge(_ other: UsageAggregate) {
        tokens += other.tokens
        thinking += other.thinking
        messages += other.messages
        models.merge(other.models, uniquingKeysWith: +)
        toolCalls.merge(other.toolCalls, uniquingKeysWith: +)
        projects.merge(other.projects, uniquingKeysWith: +)
        sessions.formUnion(other.sessions)
        cost += other.cost
        splits.merge(other.splits, uniquingKeysWith: +)
        costs.merge(other.costs, uniquingKeysWith: +)
    }

    /// Share of output that was thinking, 0...1; nil without any output.
    var thinkingShare: Double? {
        tokens.output > 0 ? min(1, thinking / tokens.output) : nil
    }
}

struct UsageBucket: Sendable, Identifiable, Equatable {
    var id: Date { start }
    let start: Date
    var usage: UsageAggregate
}

/// One named share of usage — a model, a project — for the "by …" lists.
struct UsageShare: Sendable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let tokens: Double
    /// USD: the provider's own figure, or an estimate at public API prices.
    var cost: Double? = nil
    var costIsEstimate = true
}

/// One of a provider's meters when it has several (Copilot's premium / chat /
/// completions, Cursor's auto / API / total).
struct UsageMeter: Sendable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let percent: Double?
    var used: Double? = nil
    var limit: Double? = nil
    var note: String? = nil
}

/// The detail behind a snapshot's headline numbers. Every field is optional
/// in spirit — providers fill what their source actually exposes.
struct UsageDetail: Sendable, Equatable {
    /// Hourly buckets for the last 24 hours, oldest first.
    var hours: [UsageBucket] = []
    /// Daily buckets for the last 7 local days, oldest first, ending today.
    var days: [UsageBucket] = []
    /// Everything in the last 7 days, summed.
    var week = UsageAggregate()
    var meters: [UsageMeter] = []
    /// When this Mac's tool last wrote a counted transcript line, for the
    /// providers whose history comes from local transcripts.
    var newestLocalEvent: Date? = nil
    /// The seven days before `days`, when the source reaches back that far.
    var previousWeek: UsageAggregate? = nil

    var hasActivity: Bool { !week.isEmpty }

    /// Tokens this week against last week, as a percentage; nil until there
    /// is a last week to compare with.
    var weekOverWeek: Double? {
        UsageFormatting.percentDelta(current: week.tokens.total, previous: previousWeek?.tokens.total)
    }

    /// Each model with its tokens and cost: the provider's own figure when it
    /// keeps one (Cursor), else an estimate priced from that model's own mix.
    var byModel: [UsageShare] {
        let estimates = ModelPricing.estimateByModel(week)
        return week.models
            .filter { $0.value > 0 }
            .map { model, tokens in
                if let real = week.costs[model] {
                    return UsageShare(name: model, tokens: tokens, cost: real, costIsEstimate: false)
                }
                return UsageShare(name: model, tokens: tokens, cost: estimates[model])
            }
            .sorted { $0.tokens > $1.tokens }
    }

    /// Each project with its tokens and an estimated cost summed from the
    /// models used in it.
    var byProject: [UsageShare] {
        let estimates = ModelPricing.estimateByProject(week)
        return week.projects
            .filter { $0.value > 0 }
            .map { UsageShare(name: $0.key, tokens: $0.value, cost: estimates[$0.key]) }
            .sorted { $0.tokens > $1.tokens }
    }

    var topTools: [(name: String, count: Int)] {
        week.toolCalls
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { (name: $0.key, count: $0.value) }
    }
}

enum UsageBucketing {
    /// Sums `usage` into `count` consecutive buckets of `component` ending at the
    /// bucket containing `now`; empty buckets are filled in so charts stay aligned.
    static func series(
        _ buckets: [Date: UsageAggregate],
        count: Int,
        component: Calendar.Component,
        endingAt now: Date,
        calendar: Calendar
    ) -> [UsageBucket] {
        guard let interval = calendar.dateInterval(of: component, for: now) else { return [] }
        return (0..<count).compactMap { index in
            guard let start = calendar.date(byAdding: component, value: index - (count - 1), to: interval.start) else {
                return nil
            }
            return UsageBucket(start: start, usage: buckets[start] ?? UsageAggregate())
        }
    }

    /// Start of the hour/day containing `date`, in `calendar`.
    static func floor(_ date: Date, to component: Calendar.Component, calendar: Calendar) -> Date {
        calendar.dateInterval(of: component, for: date)?.start ?? date
    }
}
