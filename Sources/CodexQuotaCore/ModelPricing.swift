import Foundation

/// API list prices (USD per million tokens), used to value local token usage as if it were billed by the API.
/// Sources, checked 2026-09-24: platform.claude.com/docs/en/about-claude/pricing and
/// developers.openai.com/api/docs/pricing. Unknown models are left unpriced rather than guessed.
public enum ModelPriceBook {
    public struct ClaudePrice: Equatable, Sendable {
        public let input: Double
        public let output: Double
        /// Cache hits as a fraction of the input rate (0.1 on most models).
        public let cacheReadMultiplier: Double
        /// Fast mode (`usage.speed == "fast"`) replaces the base rates; cache multipliers apply on top.
        public let fastInput: Double?
        public let fastOutput: Double?

        init(_ input: Double, _ output: Double, read: Double = 0.1, fast: (Double, Double)? = nil) {
            self.input = input
            self.output = output
            cacheReadMultiplier = read
            fastInput = fast?.0
            fastOutput = fast?.1
        }
    }

    public struct OpenAIRates: Equatable, Sendable {
        public let input: Double
        public let cachedInput: Double
        public let cacheWrite: Double
        public let output: Double

        init(_ input: Double, cached: Double, write: Double? = nil, output: Double) {
            self.input = input
            cachedInput = cached
            // "Cache writes are billed at 1.25x the uncached input token rate."
            cacheWrite = write ?? input * 1.25
            self.output = output
        }
    }

    public struct OpenAIPrice: Equatable, Sendable {
        public let standard: OpenAIRates
        /// Applies to the whole request once the prompt exceeds `openAILongContextThreshold`.
        public let longContext: OpenAIRates?
    }

    public static let claudeCacheWrite5mMultiplier = 1.25
    public static let claudeCacheWrite1hMultiplier = 2.0
    public static let claudeWebSearchUSD = 0.01
    public static let claudeUSInferenceMultiplier = 1.1
    public static let openAILongContextThreshold: Int64 = 272_000

    static let claude: [String: ClaudePrice] = [
        "claude-fable-5-1": ClaudePrice(10, 50, read: 0.025),
        "claude-mythos-5-1": ClaudePrice(10, 50, read: 0.025),
        "claude-fable-5": ClaudePrice(10, 50),
        "claude-mythos-5": ClaudePrice(10, 50),
        "claude-opus-5-5": ClaudePrice(4, 20, read: 0.05, fast: (8, 40)),
        "claude-opus-5": ClaudePrice(5, 25, fast: (10, 50)),
        "claude-opus-4-8": ClaudePrice(5, 25, fast: (10, 50)),
        "claude-opus-4-7": ClaudePrice(5, 25),
        "claude-opus-4-6": ClaudePrice(5, 25),
        "claude-opus-4-5": ClaudePrice(5, 25),
        "claude-opus-4-1": ClaudePrice(15, 75),
        "claude-opus-4": ClaudePrice(15, 75),
        "claude-sonnet-5": ClaudePrice(2, 10),
        "claude-sonnet-4-6": ClaudePrice(3, 15),
        "claude-sonnet-4-5": ClaudePrice(3, 15),
        "claude-sonnet-4": ClaudePrice(3, 15),
        "claude-3-7-sonnet": ClaudePrice(3, 15),
        "claude-haiku-4-5": ClaudePrice(1, 5),
        "claude-3-5-haiku": ClaudePrice(0.8, 4)
    ]

    static let openAI: [String: OpenAIPrice] = {
        func price(_ standard: OpenAIRates, long: OpenAIRates? = nil) -> OpenAIPrice {
            OpenAIPrice(standard: standard, longContext: long)
        }
        let gpt51 = price(OpenAIRates(1.25, cached: 0.125, output: 10))
        let gpt52 = price(OpenAIRates(1.75, cached: 0.175, output: 14))
        let gpt5Mini = price(OpenAIRates(0.25, cached: 0.025, output: 2))
        return [
            "gpt-6-astra": price(
                OpenAIRates(10, cached: 1, write: 12.5, output: 50),
                long: OpenAIRates(20, cached: 2, write: 25, output: 75)
            ),
            "gpt-6-sol": price(
                OpenAIRates(2, cached: 0.2, write: 2.5, output: 10),
                long: OpenAIRates(4, cached: 0.4, write: 5, output: 15)
            ),
            "gpt-6-luna": price(
                OpenAIRates(0.1, cached: 0.01, write: 0.125, output: 0.5),
                long: OpenAIRates(0.2, cached: 0.02, write: 0.25, output: 0.75)
            ),
            "gpt-5.6-sol": price(
                OpenAIRates(4, cached: 0.4, write: 5, output: 20),
                long: OpenAIRates(8, cached: 0.8, write: 10, output: 30)
            ),
            "gpt-5.6-terra": price(
                OpenAIRates(2, cached: 0.2, write: 2.5, output: 12),
                long: OpenAIRates(4, cached: 0.4, write: 5, output: 18)
            ),
            "gpt-5.6-luna": price(
                OpenAIRates(0.2, cached: 0.02, write: 0.25, output: 1.2),
                long: OpenAIRates(0.4, cached: 0.04, write: 0.5, output: 1.8)
            ),
            "gpt-5.5": price(OpenAIRates(5, cached: 0.5, output: 30), long: OpenAIRates(10, cached: 1, output: 45)),
            "gpt-5.4": price(OpenAIRates(2.5, cached: 0.25, output: 15), long: OpenAIRates(5, cached: 0.5, output: 22.5)),
            "gpt-5.4-mini": price(OpenAIRates(0.75, cached: 0.075, output: 4.5)),
            "gpt-5.4-nano": price(OpenAIRates(0.2, cached: 0.02, output: 1.25)),
            "gpt-5.3-codex": gpt52,
            "gpt-5.2": gpt52,
            "gpt-5.2-codex": gpt52,
            "gpt-5.1": gpt51,
            "gpt-5.1-codex": gpt51,
            "gpt-5.1-codex-max": gpt51,
            "gpt-5.1-codex-mini": gpt5Mini,
            "gpt-5": gpt51,
            "gpt-5-codex": gpt51,
            "gpt-5-mini": gpt5Mini,
            "gpt-5-nano": price(OpenAIRates(0.05, cached: 0.005, output: 0.4))
        ]
    }()

    public static func claudePrice(for model: String) -> ClaudePrice? {
        // "claude-sonnet-4-5-20250929", "claude-opus-4-5@20251101", "claude-opus-5-5[1m]" → the family ID.
        var id = model.lowercased()
        if let cut = id.firstIndex(where: { $0 == "[" || $0 == "@" }) { id = String(id[..<cut]) }
        if let date = id.range(of: #"-\d{8}$"#, options: .regularExpression) { id.removeSubrange(date) }
        return claude[id]
    }

    public static func openAIPrice(for model: String) -> OpenAIPrice? {
        var id = model.lowercased()
        if let date = id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) { id.removeSubrange(date) }
        return openAI[id]
    }

    /// USD value of one request at API list price, or nil when the model has no known price.
    public static func cost(of event: UsageEvent) -> Double? {
        switch event.source {
        case .claude:
            guard let price = claudePrice(for: event.model) else { return nil }
            let fast = event.isFastMode && price.fastInput != nil
            let input = fast ? price.fastInput! : price.input
            let output = fast ? price.fastOutput! : price.output
            var usd = (
                Double(event.uncachedInput) * input
                    + Double(event.cacheWrite) * input * claudeCacheWrite5mMultiplier
                    + Double(event.cacheWriteLong) * input * claudeCacheWrite1hMultiplier
                    + Double(event.cacheRead) * input * price.cacheReadMultiplier
                    + Double(event.output) * output
            ) / 1_000_000
            if event.isUSInference { usd *= claudeUSInferenceMultiplier }
            return usd + Double(event.webSearchRequests) * claudeWebSearchUSD
        case .codex:
            guard let price = openAIPrice(for: event.model) else { return nil }
            let rates = event.promptTokens > openAILongContextThreshold
                ? price.longContext ?? price.standard
                : price.standard
            return (
                Double(event.uncachedInput) * rates.input
                    + Double(event.cacheRead) * rates.cachedInput
                    + Double(event.cacheWrite + event.cacheWriteLong) * rates.cacheWrite
                    + Double(event.output) * rates.output
            ) / 1_000_000
        }
    }
}

/// USD → CNY reference rate.
public struct ExchangeRate: Codable, Equatable, Sendable {
    public let usdToCNY: Double
    /// The day the source published the rate ("2026-09-24").
    public let asOf: String
    public let source: String

    public init(usdToCNY: Double, asOf: String, source: String) {
        self.usdToCNY = usdToCNY
        self.asOf = asOf
        self.source = source
    }

    /// Used only until the first successful download (open.er-api.com, 2026-09-24).
    public static let fallback = ExchangeRate(usdToCNY: 6.7227, asOf: "2026-09-24", source: "内置")

    /// Decodes open.er-api.com (`rates.CNY`, `time_last_update_unix`) or Frankfurter (`rates.CNY`, `date`).
    public static func decode(_ data: Data, source: String) -> ExchangeRate? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rates = object["rates"] as? [String: Any],
            let cny = (rates["CNY"] as? NSNumber)?.doubleValue,
            cny.isFinite, cny > 1, cny < 20
        else { return nil }
        if let result = object["result"] as? String, result != "success" { return nil }

        let asOf: String
        if let date = object["date"] as? String {
            asOf = date
        } else if let unix = (object["time_last_update_unix"] as? NSNumber)?.doubleValue {
            asOf = TokenFormatting.beijingDay(for: Date(timeIntervalSince1970: unix))
        } else {
            asOf = TokenFormatting.beijingDay(for: Date())
        }
        return ExchangeRate(usdToCNY: cny, asOf: asOf, source: source)
    }
}

public enum TokenFormatting {
    public static let beijing = TimeZone(identifier: "Asia/Shanghai")!

    /// Beijing-time calendar day bounds containing `date`.
    public static func beijingDayInterval(containing date: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijing
        return calendar.dateInterval(of: .day, for: date)!
    }

    public static func beijingDay(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = beijing
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Chinese-style magnitudes: 8,532 · 123.4万 · 1711万 · 1.70亿.
    public static func compactTokens(_ count: Int64) -> String {
        let value = Double(max(0, count))
        if value < 10_000 {
            return grouped(value, fractionDigits: 0)
        }
        if value < 100_000_000 {
            let wan = value / 10_000
            return wan < 1_000 ? "\(trimmed(wan, fractionDigits: 1))万" : "\(Int(wan.rounded()))万"
        }
        let yi = value / 100_000_000
        return "\(String(format: yi < 100 ? "%.2f" : "%.1f", yi))亿"
    }

    public static func yuan(_ amount: Double) -> String {
        guard amount.isFinite, amount > 0 else { return "¥0" }
        if amount < 0.01 { return "<¥0.01" }
        if amount < 1_000 { return "¥" + String(format: "%.2f", amount) }
        return "¥" + grouped(amount.rounded(), fractionDigits: 0)
    }

    /// "99.2%"; values that round to 100% but aren't are shown as ">99.9%".
    public static func percent(_ fraction: Double) -> String {
        let value = min(1, max(0, fraction)) * 100
        if value >= 99.95, value < 100 { return ">99.9%" }
        return String(format: "%.1f%%", value)
    }

    public static func dollars(_ amount: Double) -> String {
        guard amount.isFinite, amount > 0 else { return "$0" }
        if amount < 0.01 { return "<$0.01" }
        return "$" + String(format: "%.2f", amount)
    }

    private static func grouped(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = fractionDigits
        formatter.minimumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }

    private static func trimmed(_ value: Double, fractionDigits: Int) -> String {
        let text = String(format: "%.\(fractionDigits)f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
