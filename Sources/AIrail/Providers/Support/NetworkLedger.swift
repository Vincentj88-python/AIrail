import Foundation

/// Every host AIrail has talked to since launch, and when — fed by the one
/// network path (`HTTPClient`), read by the Privacy pane. One row per host,
/// so the list is the allowlist with dates on it, never a log of requests.
@MainActor
final class NetworkLedger: ObservableObject {
    struct Entry: Identifiable, Equatable, Sendable {
        var id: String { host }
        let host: String
        var lastContact: Date
        var method: String
        var path: String
        var status: Int
        var count: Int
    }

    static let shared = NetworkLedger()

    /// When this launch started counting.
    let since: Date
    @Published private(set) var entries: [Entry] = []

    init(since: Date = Date()) {
        self.since = since
    }

    func record(host: String, method: String, path: String, status: Int, at date: Date = Date()) {
        if let index = entries.firstIndex(where: { $0.host == host }) {
            entries[index].lastContact = date
            entries[index].method = method
            entries[index].path = path
            entries[index].status = status
            entries[index].count += 1
        } else {
            entries.append(Entry(host: host, lastContact: date, method: method, path: path, status: status, count: 1))
        }
        entries.sort { $0.lastContact > $1.lastContact }
    }
}

/// What connecting an account makes AIrail touch — the files and Keychain
/// items it reads, the command it runs, the host it asks — so the Privacy
/// pane can list it and the tests can hold every provider to it.
enum FootprintItem: Sendable, Equatable, Hashable {
    case file(path: String, what: String)
    case keychain(item: String, what: String)
    case command(String, what: String)
    case host(String, what: String)

    var host: String? {
        if case .host(let host, _) = self { return host }
        return nil
    }
}

enum Footprint {
    /// Every host AIrail will ever contact and what for — the same seven
    /// `HTTPClient.allowedHosts` refuses everything else against.
    static let hosts: [String: String] = [
        "api.anthropic.com": "Claude Code's usage, and the Anthropic API usage report",
        "chatgpt.com": "Codex's usage windows",
        "api.github.com": "Copilot's quota, and the check for a newer AIrail release",
        "cursor.com": "Cursor's usage and its per-request feed",
        "openrouter.ai": "OpenRouter key limits and credits",
        "api.deepseek.com": "DeepSeek balance",
        "api.openai.com": "The OpenAI API usage and cost reports",
    ]

    static func items(for providerId: String) -> [FootprintItem] {
        switch providerId {
        case "claude":
            return [
                .keychain(item: "Claude Code-credentials", what: "the sign-in Claude Code keeps"),
                .file(path: "~/.claude/projects", what: "session transcripts, for the charts"),
                .host("api.anthropic.com", what: "your plan's session and weekly limits"),
            ]
        case "codex":
            return [
                .file(path: "~/.codex/auth.json", what: "the sign-in Codex keeps"),
                .file(path: "~/.codex/sessions", what: "session logs, for the charts"),
                .host("chatgpt.com", what: "your plan's usage windows"),
            ]
        case "copilot":
            return [
                .command("gh auth token", what: "the GitHub CLI's sign-in"),
                .file(path: "~/.config/github-copilot/apps.json", what: "the editor extension's sign-in, only if gh is missing"),
                .host("api.github.com", what: "your Copilot quota"),
            ]
        case "cursor":
            return [
                .file(path: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb", what: "the sign-in Cursor keeps"),
                .host("cursor.com", what: "your plan's usage and the request feed"),
            ]
        case "openrouter":
            return [.keychain(item: "AIrail", what: "the API key you pasted"), .host("openrouter.ai", what: "key limits and credits")]
        case "deepseek":
            return [.keychain(item: "AIrail", what: "the API key you pasted"), .host("api.deepseek.com", what: "your balance")]
        case "anthropic-api":
            return [.keychain(item: "AIrail", what: "the Admin key you pasted"), .host("api.anthropic.com", what: "the organization usage and cost reports")]
        case "openai-api":
            return [.keychain(item: "AIrail", what: "the Admin key you pasted"), .host("api.openai.com", what: "the organization usage and cost reports")]
        default:
            return []
        }
    }
}
