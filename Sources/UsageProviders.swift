import Foundation
import Security
import Darwin

enum UsageProvider: String, CaseIterable, Sendable {
    case codex = "Codex", claude = "Claude"
    var interval: TimeInterval { self == .codex ? 60 : 300 }

    func fetch() async -> UsageResult {
        do {
            switch self {
            case .codex: return try await CodexClient.fetch()
            case .claude: return try await ClaudeClient.fetch()
            }
        } catch is CancellationError {
            return UsageResult(error: "Usage request cancelled")
        } catch {
            return UsageResult(error: error.localizedDescription)
        }
    }
}

struct ClaudeCredentials: Decodable, Sendable {
    struct OAuth: Decodable, Sendable {
        let accessToken: String
        let subscriptionType: String?
    }
    let claudeAiOauth: OAuth

    static func decode(_ data: Data) throws -> ClaudeCredentials {
        guard let credentials = try? JSONDecoder().decode(Self.self, from: data),
              !credentials.claudeAiOauth.accessToken.isEmpty else {
            throw UsageFailure("Claude OAuth token not found; run `claude auth login`")
        }
        return credentials
    }

    static func read() throws -> ClaudeCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let credentials = try? decode(data) {
            return credentials
        }
        let directory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".credentials.json")) else {
            throw UsageFailure("Claude credentials not found; run `claude auth login`")
        }
        return try decode(data)
    }
}

enum ClaudeClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()
    private struct Response: Decodable {
        struct Window: Decodable {
            let utilization: Double
            let resets_at: String?
        }
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let display_name: String? }
                let model: Model?
            }
            let kind: String
            let percent: Double
            let resets_at: String?
            let scope: Scope?
        }
        let five_hour: Window?
        let seven_day: Window?
        let limits: [Limit]?
    }

    static func windows(from data: Data) throws -> [UsageWindow] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let scoped = (response.limits ?? []).compactMap { limit -> UsageWindow? in
            let name: String
            switch limit.kind {
            case "session": name = "5-hour"
            case "weekly_all": name = "7-day · All models"
            case "weekly_scoped":
                guard let model = limit.scope?.model?.display_name, !model.isEmpty else { return nil }
                name = "7-day · \(model)"
            default: return nil
            }
            return UsageWindow(name: name, used: limit.percent, resetsAt: resetTimestamp(limit.resets_at))
        }
        if !scoped.isEmpty { return scoped }
        var windows: [UsageWindow] = []
        if let window = response.five_hour {
            windows.append(UsageWindow(name: "5-hour", used: window.utilization, resetsAt: resetTimestamp(window.resets_at)))
        }
        if let window = response.seven_day {
            windows.append(UsageWindow(name: "7-day · All models", used: window.utilization, resetsAt: resetTimestamp(window.resets_at)))
        }
        return windows
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval {
        let value = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Int(value), seconds > 0 { return Double(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value), date > now { return date.timeIntervalSince(now) }
        return 900
    }

    static func fetch() async throws -> UsageResult {
        let credentials: ClaudeCredentials
        do { credentials = try await Task.detached(priority: .utility) { try ClaudeCredentials.read() }.value }
        catch { return UsageResult(error: error.localizedDescription, retry: 60) }
        try Task.checkCancellation()
        return try await fetch(credentials: credentials, session: session)
    }

    static func fetch(credentials: ClaudeCredentials, session: URLSession) async throws -> UsageResult {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.claudeAiOauth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("usage-notifier/1.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            return UsageResult(error: "Could not reach Claude; check your connection", retry: 60)
        }
        guard let http = response as? HTTPURLResponse else {
            return UsageResult(error: "Could not read Claude response", retry: 60)
        }
        switch http.statusCode {
        case 200:
            do {
                let windows = try windows(from: data)
                guard !windows.isEmpty else { return UsageResult(error: "Claude returned no active rate limits") }
                return UsageResult(plan: nonempty(credentials.claudeAiOauth.subscriptionType, fallback: "subscription"), windows: windows)
            } catch { return UsageResult(error: "Could not decode Claude usage") }
        case 401, 403: return UsageResult(error: "Claude login needs attention; run claude auth login", retry: 60)
        case 429:
            return UsageResult(error: "Claude is rate limiting requests; waiting to retry", retry: retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        default: return UsageResult(error: "Claude returned HTTP \(http.statusCode)", retry: 60)
        }
    }
}

enum CodexClient {
    private struct Response: Decodable {
        struct RateLimits: Decodable {
            struct Window: Decodable {
                let usedPercent: Double
                let windowDurationMins: Int?
                let resetsAt: Double?
            }
            let planType: String?
            let primary: Window?
            let secondary: Window?
        }
        let rateLimits: RateLimits
    }

    static func usage(from data: Data) throws -> UsageResult {
        let limits = try JSONDecoder().decode(Response.self, from: data).rateLimits
        let windows = [(limits.primary, "Session"), (limits.secondary, "Weekly")].compactMap { window, fallback -> UsageWindow? in
            guard let window else { return nil }
            return UsageWindow(name: windowName(minutes: window.windowDurationMins ?? 0, fallback: fallback), used: window.usedPercent, resetsAt: window.resetsAt ?? 0)
        }
        guard !windows.isEmpty else { throw UsageFailure("Codex returned no active rate limits") }
        return UsageResult(plan: nonempty(limits.planType, fallback: "subscription"), windows: windows)
    }

    static var environment: [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ProcessInfo.processInfo.environment
        let directories = (environment["PATH"] ?? "").components(separatedBy: ":")
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "\(home)/.local/bin", "\(home)/.nix-profile/bin", "/run/current-system/sw/bin"]
        environment["PATH"] = directories.filter { !$0.isEmpty }.joined(separator: ":")
        return environment
    }

    static func executable() throws -> URL {
        let directories = environment["PATH"]!.components(separatedBy: ":")
        for directory in directories where !directory.isEmpty {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw UsageFailure("codex CLI was not found in PATH")
    }

    static func fetch(executable: URL? = nil, timeout: TimeInterval = 15) async throws -> UsageResult {
        let session = CodexSession(executable: try executable ?? self.executable(), timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try session.readUsage()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { session.cancel() }
    }
}

/// Codex still owns its authentication. Only this CLI process needs stdin/stdout RPC.
private final class CodexSession: @unchecked Sendable {
    private let executable: URL
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false

    init(executable: URL, timeout: TimeInterval) {
        self.executable = executable
        self.timeout = timeout
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private func check(deadline: TimeInterval) throws {
        lock.lock()
        let cancelled = cancelled
        lock.unlock()
        if cancelled { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw UsageFailure("Codex usage request timed out") }
    }

    func readUsage() throws -> UsageResult {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try check(deadline: deadline)
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.environment = CodexClient.environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw UsageFailure("Could not start Codex; check your CLI installation") }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "usage-notifier", "version": "1.0.0"]]])
        var expectedID = 1
        var buffer = Data()
        while true {
            try check(deadline: deadline)
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer[..<end]
                let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                buffer.removeSubrange(...end)
                guard let message, let id = message["id"] as? Int, id == expectedID else { continue }
                if message["error"] != nil { throw UsageFailure("Codex usage request failed; check codex login status") }
                guard let result = message["result"] else { throw UsageFailure("Codex returned an invalid response") }
                if expectedID == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                    expectedID = 2
                } else {
                    return try CodexClient.usage(from: JSONSerialization.data(withJSONObject: result))
                }
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw UsageFailure("Could not read Codex usage")
            }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw UsageFailure("Codex stopped before returning limits; check codex login status") }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 4 * 1024 * 1024 else { throw UsageFailure("Codex response exceeded the size limit") }
        }
    }
}
