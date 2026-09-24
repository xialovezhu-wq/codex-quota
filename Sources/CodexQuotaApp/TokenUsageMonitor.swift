@preconcurrency import Foundation
import CodexQuotaCore

/// Owns the (non-thread-safe) scanner off the main thread; file reads happen here.
private actor TokenUsageWorker {
    private let scanner: TokenUsageScanner

    init(roots: [TokenUsageScanner.Root]) {
        scanner = TokenUsageScanner(roots: roots)
    }

    func scan(now: Date) -> DailyTokenUsage {
        scanner.scan(now: now)
    }
}

/// Re-totals today's Claude Code and Codex token usage from their local logs every few seconds.
@MainActor
final class TokenUsageMonitor {
    var onUpdate: ((DailyTokenUsage) -> Void)?

    private let worker: TokenUsageWorker
    private let interval: Duration
    private var loopTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    init(
        roots: [TokenUsageScanner.Root] = TokenUsageScanner.defaultRoots(),
        interval: Duration = .seconds(10)
    ) {
        worker = TokenUsageWorker(roots: roots)
        self.interval = interval
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.scanNow()
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        scanTask?.cancel()
        scanTask = nil
    }

    func scanNow() {
        guard scanTask == nil else { return }
        let worker = worker
        scanTask = Task { @MainActor [weak self] in
            let usage = await worker.scan(now: Date())
            guard let self else { return }
            self.scanTask = nil
            guard !Task.isCancelled else { return }
            self.onUpdate?(usage)
        }
    }
}

/// Keeps a USD → CNY reference rate, refreshed a few times a day from free public sources.
@MainActor
final class ExchangeRateProvider {
    var onUpdate: ((ExchangeRate) -> Void)?

    private let defaults: UserDefaults
    private let refreshInterval: Duration
    private var loopTask: Task<Void, Never>?
    private static let key = "fx.usdToCNY.v1"
    private static let sources: [(name: String, url: URL)] = [
        ("open.er-api.com", URL(string: "https://open.er-api.com/v6/latest/USD")!),
        ("frankfurter.dev", URL(string: "https://api.frankfurter.dev/v1/latest?base=USD&symbols=CNY")!)
    ]

    private(set) var rate: ExchangeRate

    init(defaults: UserDefaults = .standard, refreshInterval: Duration = .seconds(6 * 3600)) {
        self.defaults = defaults
        self.refreshInterval = refreshInterval
        rate = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ExchangeRate.self, from: $0) }
            ?? .fallback
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.refreshInterval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func refresh() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        for source in Self.sources {
            guard
                let (data, response) = try? await session.data(from: source.url),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let fresh = ExchangeRate.decode(data, source: source.name)
            else { continue }
            rate = fresh
            if let data = try? JSONEncoder().encode(fresh) {
                defaults.set(data, forKey: Self.key)
            }
            onUpdate?(fresh)
            return
        }
    }
}
