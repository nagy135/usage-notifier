import Combine
import Foundation

@MainActor
final class UsageModel: ObservableObject {
    @Published var services = UsageProvider.allCases.map { ServiceUsage(name: $0.rawValue) }
    @Published var loading = false
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var stopped = false
    private let fetchUsage: @Sendable (UsageProvider) async -> UsageResult
    private let now: @Sendable () -> Date

    init(fetchUsage: @escaping @Sendable (UsageProvider) async -> UsageResult = { await $0.fetch() },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetchUsage = fetchUsage
        self.now = now
    }

    func start() {
        guard timer == nil else { return }
        stopped = false
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !stopped, refreshTask == nil else { return }
        let due = UsageProvider.allCases.filter { provider in
            services.contains { $0.name == provider.rawValue && $0.nextAttempt <= now().timeIntervalSince1970 }
        }
        guard !due.isEmpty else { return }
        loading = true
        let fetch = fetchUsage
        refreshTask = Task { [weak self] in
            await withTaskGroup(of: (UsageProvider, UsageResult).self) { group in
                for provider in due {
                    group.addTask { (provider, await fetch(provider)) }
                }
                for await (provider, result) in group {
                    guard !Task.isCancelled, let self,
                          let index = self.services.firstIndex(where: { $0.name == provider.rawValue }) else { continue }
                    self.services[index].merge(result, now: self.now(), interval: provider.interval)
                }
            }
            self?.loading = false
            self?.refreshTask = nil
        }
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
    }
}
