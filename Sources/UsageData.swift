import Foundation

struct UsageWindow: Codable, Sendable {
    let name: String
    let used: Double
    let resetsAt: Double
    var remaining: Double { max(0, min(100, 100 - used)) }
}

struct ServiceUsage: Codable, Sendable {
    let name: String
    var plan = ""
    var windows: [UsageWindow]? = nil
    var error = ""
    var updatedAt: Double = 0
    var nextAttempt: Double = 0

    mutating func merge(_ result: UsageResult, now: Date, interval: TimeInterval) {
        nextAttempt = now.timeIntervalSince1970 + (result.retry ?? interval)
        if let message = result.error {
            error = message
            return
        }
        plan = result.plan
        windows = result.windows
        error = ""
        updatedAt = now.timeIntervalSince1970
    }
}

struct UsageResult: Sendable {
    var plan = ""
    var windows: [UsageWindow] = []
    var error: String? = nil
    var retry: TimeInterval? = nil
}

struct UsageFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func windowName(minutes: Int, fallback: String) -> String {
    guard minutes > 0 else { return fallback }
    if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
    if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
    return "\(minutes)-minute"
}

func resetTimestamp(_ value: String?) -> Double {
    guard let value else { return 0 }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date.timeIntervalSince1970 }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)?.timeIntervalSince1970 ?? 0
}

func nonempty(_ value: String?, fallback: String) -> String {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
    return value
}
