import Foundation
import Darwin

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func bytes(_ string: String) -> Data { Data(string.utf8) }

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var headers: [String: String] = [:]
    static var body = "{}"
    static var capturedRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.capturedRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes(Self.body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor FetchRecorder {
    var counts: [UsageProvider: Int] = [:]
    func fetch(_ provider: UsageProvider) async -> UsageResult {
        counts[provider, default: 0] += 1
        try? await Task.sleep(nanoseconds: 30_000_000)
        return UsageResult(plan: "fixture", windows: [UsageWindow(name: "5-hour", used: 25, resetsAt: 0)])
    }
    func count(_ provider: UsageProvider) -> Int { counts[provider, default: 0] }
}

@main
struct UsageTests {
    static func fakeCodex(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex")
        try bytes("#!/bin/sh\n" + script).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    static func removeFake(_ executable: URL) { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

    @MainActor
    static func waitForRefresh(_ model: UsageModel) async throws {
        for _ in 0..<100 {
            if !model.loading { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestFailure(description: "refresh did not finish")
    }

    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        var passed = 0
        func test(_ name: String, _ body: () async throws -> Void) async throws {
            try await body()
            passed += 1
            print("PASS \(name)")
        }

        try await test("Claude scoped limits, unknown scopes, and fractional reset timestamps") {
            let windows = try ClaudeClient.windows(from: bytes(#"{"limits":[{"kind":"session","percent":36,"resets_at":"2026-07-14T17:30:00.123Z"},{"kind":"weekly_all","percent":23},{"kind":"weekly_scoped","percent":42,"scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":99},{"kind":"unknown","percent":99}]}"#))
            try expect(windows.map(\.name) == ["5-hour", "7-day · All models", "7-day · Fable"], "wrong scoped names")
            try expect(windows.map(\.used) == [36, 23, 42], "wrong usage")
            try expect(windows[0].resetsAt > 0 && windows[1].resetsAt == 0, "wrong reset timestamps")
        }
        try await test("Claude legacy and empty responses") {
            let windows = try ClaudeClient.windows(from: bytes(#"{"five_hour":{"utilization":36,"resets_at":null},"seven_day":{"utilization":23}}"#))
            try expect(windows.map(\.name) == ["5-hour", "7-day · All models"], "wrong legacy names")
            try expect(windows[0].resetsAt == 0, "invented a reset")
            let empty = try ClaudeClient.windows(from: bytes(#"{"five_hour":null,"seven_day":null}"#))
            try expect(empty.isEmpty, "invented windows")
        }
        try await test("Cache retains last success after failure, then recovers") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            var usage = ServiceUsage(name: "Claude")
            usage.merge(UsageResult(plan: "team", windows: [UsageWindow(name: "5-hour", used: 32, resetsAt: 0)]), now: now, interval: 300)
            usage.merge(UsageResult(error: "rate limited", retry: 900), now: now.addingTimeInterval(60), interval: 300)
            try expect(usage.updatedAt == now.timeIntervalSince1970 && usage.windows?[0].used == 32 && usage.plan == "team", "lost last successful reading")
            try expect(usage.nextAttempt == now.addingTimeInterval(960).timeIntervalSince1970, "lost cooldown")
            usage.merge(UsageResult(plan: "team", windows: [UsageWindow(name: "5-hour", used: 45, resetsAt: 0)]), now: now.addingTimeInterval(960), interval: 300)
            try expect(usage.error.isEmpty && usage.windows?[0].used == 45, "did not recover")
        }
        try await test("Retry-After handles seconds, HTTP date, and invalid values") {
            try expect(ClaudeClient.retryAfter("120") == 120, "wrong seconds")
            for value in [nil, "invalid", "-1", "0"] {
                try expect(ClaudeClient.retryAfter(value) == 900, "wrong default backoff")
            }
            let now = Date(timeIntervalSince1970: 0)
            try expect(ClaudeClient.retryAfter("Thu, 01 Jan 1970 00:05:00 GMT", now: now) == 300, "wrong HTTP date")
        }
        try await test("Codex optional windows and remaining percentage bounds") {
            let result = try CodexClient.usage(from: bytes(#"{"rateLimits":{"planType":"pro","primary":null,"secondary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1790850219}}}"#))
            try expect(result.plan == "pro" && result.windows.count == 1 && result.windows[0].name == "7-day", "wrong Codex reading")
            try expect(result.windows[0].remaining == 97, "wrong remaining usage")
            try expect(UsageWindow(name: "test", used: 120, resetsAt: 0).remaining == 0, "negative remaining usage")
            try expect(UsageWindow(name: "test", used: -10, resetsAt: 0).remaining == 100, "excess remaining usage")
        }
        try await test("Codex rejects missing limits instead of assuming unlimited capacity") {
            do {
                _ = try CodexClient.usage(from: bytes(#"{"rateLimits":{"primary":null,"secondary":null}}"#))
                throw TestFailure(description: "empty limits accepted")
            } catch is UsageFailure {}
        }
        try await test("Codex unknown reset and duration stay unknown") {
            let result = try CodexClient.usage(from: bytes(#"{"rateLimits":{"primary":{"usedPercent":25,"resetsAt":null}}}"#))
            try expect(result.windows[0].resetsAt == 0 && result.windows[0].name == "Session", "invented reset or duration")
        }
        try await test("Credential decoding requires an OAuth token") {
            let credentials = try ClaudeCredentials.decode(bytes(#"{"claudeAiOauth":{"accessToken":"fixture-token","subscriptionType":"team"}}"#))
            try expect(credentials.claudeAiOauth.subscriptionType == "team", "wrong plan")
            do {
                _ = try ClaudeCredentials.decode(bytes(#"{"claudeAiOauth":{"accessToken":""}}"#))
                throw TestFailure(description: "empty token accepted")
            } catch is UsageFailure {}
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credentials = try ClaudeCredentials.decode(bytes(#"{"claudeAiOauth":{"accessToken":"fixture-token","subscriptionType":"team"}}"#))
        try await test("Claude sends OAuth headers and decodes the HTTPS response") {
            StubProtocol.status = 200
            StubProtocol.headers = [:]
            StubProtocol.body = #"{"five_hour":{"utilization":36,"resets_at":null}}"#
            let result = try await ClaudeClient.fetch(credentials: credentials, session: session)
            try expect(result.error == nil && result.plan == "team" && result.windows[0].used == 36, "wrong HTTP result")
            try expect(StubProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "missing bearer token")
            try expect(StubProtocol.capturedRequest?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20", "missing beta header")
        }
        try await test("Claude HTTP errors preserve cooldown and never include response secrets") {
            for status in [401, 403, 429, 500] {
                StubProtocol.status = status
                StubProtocol.headers = ["Retry-After": "120"]
                StubProtocol.body = "sensitive-response-fixture"
                let result = try await ClaudeClient.fetch(credentials: credentials, session: session)
                try expect(result.error != nil && result.retry == (status == 429 ? 120 : 60), "wrong HTTP failure handling")
                try expect(!result.error!.contains(StubProtocol.body), "included response body in error")
            }
        }
        try await test("Claude malformed and empty successful responses are errors") {
            StubProtocol.status = 200
            for body in ["invalid", "{}"] {
                StubProtocol.body = body
                let result = try await ClaudeClient.fetch(credentials: credentials, session: session)
                try expect(result.error != nil, "bad successful response accepted")
            }
        }
        try await test("Codex RPC handshake tolerates notifications and partial lines") {
            let executable = try fakeCodex("""
            read -r init
            case "$init" in *initialize*) ;; *) exit 1 ;; esac
            printf '%s\\n' '{"method":"noise"}' '{"id":1,"result":{}}'
            read -r ready
            read -r request
            case "$ready$request" in *initialized*account/rateLimits/read*) ;; *) exit 1 ;; esac
            printf '%s' '{"id":2,"result":'
            /bin/sleep 0.05
            printf '%s\\n' '{"rateLimits":{"planType":"pro","secondary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1790850219}}}}'
            """)
            defer { removeFake(executable) }
            let result = try await CodexClient.fetch(executable: executable)
            try expect(result.plan == "pro" && result.windows.count == 1 && result.windows[0].used == 3, "wrong RPC result")
        }
        try await test("Codex early exit produces an error") {
            let executable = try fakeCodex("exit 0\n")
            defer { removeFake(executable) }
            do {
                _ = try await CodexClient.fetch(executable: executable)
                throw TestFailure(description: "early exit accepted")
            } catch is TestFailure { throw TestFailure(description: "early exit accepted") }
            catch {}
        }
        try await test("Codex timeout and cancellation terminate a stalled child") {
            let executable = try fakeCodex("echo $$ > \"$0.pid\"\nread -r init\nread -r more\n")
            defer { removeFake(executable) }
            do {
                _ = try await CodexClient.fetch(executable: executable, timeout: 0.15)
                throw TestFailure(description: "missing timeout")
            } catch let error as UsageFailure {
                try expect(error.message.contains("timed out"), "wrong timeout error")
            }
            let task = Task { try await CodexClient.fetch(executable: executable) }
            try await Task.sleep(nanoseconds: 100_000_000)
            task.cancel()
            do {
                _ = try await task.value
                throw TestFailure(description: "missing cancellation")
            } catch is CancellationError {}
            let pid = try String(contentsOfFile: executable.path + ".pid", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            try expect(kill(pid_t(pid)!, 0) == -1 && errno == ESRCH, "left a child process running")
        }
        try await test("Refreshes do not overlap or bypass provider cooldowns") {
            let recorder = FetchRecorder()
            let model = UsageModel(fetchUsage: { await recorder.fetch($0) }, now: { Date(timeIntervalSince1970: 2_000_000_000) })
            model.refresh()
            model.refresh()
            try await waitForRefresh(model)
            let codex = await recorder.count(.codex), claude = await recorder.count(.claude)
            try expect(codex == 1 && claude == 1, "overlapping refreshes")
            model.refresh()
            try expect(!model.loading, "bypassed cooldown")
            model.services[0].nextAttempt = 0
            model.refresh()
            try await waitForRefresh(model)
            let nextCodex = await recorder.count(.codex), nextClaude = await recorder.count(.claude)
            try expect(nextCodex == 2 && nextClaude == 1, "refreshed a provider during cooldown")
        }
        try await test("Stopping cancels refreshes without publishing late results") {
            let recorder = FetchRecorder()
            let model = UsageModel(fetchUsage: { await recorder.fetch($0) })
            model.refresh()
            model.stop()
            try await waitForRefresh(model)
            model.refresh()
            try expect(!model.loading, "started a refresh after shutdown")
            try expect(model.services.allSatisfy { $0.updatedAt == 0 }, "published cancelled results")
        }
        print("\(passed) tests passed")
    }
}
