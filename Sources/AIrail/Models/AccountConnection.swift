import Foundation

/// How a provider reaches the sign-in that already exists on this Mac.
/// AIrail never signs in on its own: it borrows what the tool holds, read-only.
struct ConnectionMethod: Sendable {
    /// The tool whose sign-in is used, e.g. "Claude Code".
    let toolName: String
    /// One line for the Add Account picker, e.g. "Uses your Claude Code sign-in".
    let summary: String
    /// Plain-language paragraph for the account page: what is read, what is sent where.
    let explainer: String
    /// Subdued footnote for known fragility or merged products; nil when there is nothing to flag.
    var caveat: String? = nil
    /// False for providers that are listed but cannot be connected yet.
    var isSupported = true
}

/// How an account gets its data: a tool's borrowed sign-in, or a key the user
/// pasted for a platform with a documented usage API.
enum ProviderKind: Sendable {
    case tool, apiKey
}

enum ConnectionError: LocalizedError, Sendable {
    case notInstalled(tool: String)
    case notSignedIn(tool: String)
    case accessDenied(tool: String)
    case expired(tool: String)
    case missingKey(platform: String)
    case invalidKey(platform: String, hint: String?)
    case rateLimited(tool: String, retryAfter: Date?)
    /// A read that should just be retried — the Keychain is mid-unlock after
    /// login, or the tool is rotating its credential right now.
    case temporarilyUnavailable(tool: String)
    case unreadable(String)
    case network(String)
    /// The Mac has no network path at all; nothing was tried.
    case offline
    /// A request or redirect to a host that isn't on `HTTPClient.allowedHosts`
    /// — a bug in AIrail's own code paths, never something a retry fixes.
    case blockedHost(String)
    case unsupported

    var errorDescription: String? {
        switch self {
        case .notInstalled(let tool):
            return "\(tool) isn't installed on this Mac."
        case .notSignedIn(let tool):
            return "\(tool) isn't signed in. Sign in there first, then try again."
        case .accessDenied(let tool):
            return "macOS didn't allow AIrail to read the \(tool) sign-in. Choose Allow when asked."
        case .expired(let tool):
            return "The \(tool) sign-in has expired. Open \(tool) to refresh it."
        case .missingKey(let platform):
            return "No API key stored for \(platform). Remove the account and add it again."
        case .invalidKey(let platform, let hint):
            return "\(platform) rejected the API key." + (hint.map { " " + $0 } ?? "")
        case .rateLimited(let tool, let retryAfter):
            let when = retryAfter.map { " Trying again " + UsageFormatting.clockString($0) + "." } ?? " Trying again shortly."
            return "\(tool) is limiting how often usage can be checked." + when
        case .temporarilyUnavailable(let tool):
            return "Couldn't read the \(tool) sign-in just now (the Keychain may be locking after sleep). AIrail will keep trying."
        case .unreadable(let detail):
            return "Couldn't read the local data: \(detail)"
        case .network(let detail):
            return "Couldn't reach the service: \(detail)"
        case .offline:
            return "You're offline. The last numbers stay until the network is back."
        case .blockedHost(let host):
            return "AIrail doesn't connect to \(host); it only talks to the services it lists."
        case .unsupported:
            return "This account isn't supported yet."
        }
    }

    /// Short caption for the Accounts list, where the full sentence is too much.
    var shortDescription: String {
        switch self {
        case .notInstalled(let tool): return "\(tool) not installed"
        case .notSignedIn(let tool): return "\(tool) not signed in"
        case .accessDenied: return "Access not allowed"
        case .expired(let tool): return "Sign-in expired — open \(tool)"
        case .missingKey: return "No API key stored"
        case .invalidKey: return "API key rejected"
        case .rateLimited: return "Checked too often — waiting"
        case .temporarilyUnavailable: return "Reading sign-in — retrying"
        case .unreadable: return "Couldn't read local data"
        case .network: return "Couldn't reach service"
        case .offline: return "Offline"
        case .blockedHost: return "Host not on AIrail's list"
        case .unsupported: return "Not supported yet"
        }
    }

    /// A failure that keeps the last real numbers meaningful (nothing changed,
    /// we just couldn't refresh) as opposed to one that means the data is gone.
    var isTransient: Bool {
        switch self {
        case .expired, .network, .offline, .accessDenied, .rateLimited, .temporarilyUnavailable: return true
        case .notInstalled, .notSignedIn, .missingKey, .invalidKey, .unreadable, .blockedHost, .unsupported: return false
        }
    }

    /// A failure the network path explains: clear its backoff when the path returns.
    var isNetworkOutage: Bool {
        switch self {
        case .offline, .network: return true
        default: return false
        }
    }

    /// The symbol beside the message: no Wi-Fi for offline, a warning otherwise.
    var symbolName: String {
        if case .offline = self { return "wifi.slash" }
        return "exclamationmark.triangle"
    }
}
