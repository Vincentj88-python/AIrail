import Foundation

/// Runs a local command-line tool and captures its output. Used only to ask
/// a tool for the token it already holds (`gh auth token`).
enum CommandRunner {
    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Finds an executable on the user's PATH plus the usual install prefixes
    /// GUI apps don't see.
    static func locate(_ tool: String) -> String? {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return directories
            .map { $0 + "/" + tool }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 10) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            let finished = OnceFlag()
            process.terminationHandler = { process in
                guard finished.claim() else { return }
                let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: Result(
                    exitCode: process.terminationStatus,
                    stdout: out.trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr: err.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
            do {
                try process.run()
            } catch {
                guard finished.claim() else { return }
                continuation.resume(throwing: ConnectionError.unreadable(error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning, finished.claim() else { return }
                process.terminate()
                continuation.resume(throwing: ConnectionError.network("\(executable) timed out"))
            }
        }
    }
}

/// A one-shot flag safe to flip from whichever thread finishes first.
private final class OnceFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
