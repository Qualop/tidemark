import Foundation
import CoreFoundation

/// One quota window for the hover card, e.g. 5h at 96% left, resetting in 4 hours.
public struct QuotaWindow: Equatable, Sendable {
    public let label: String
    public let remaining: Int
    public let resetAt: Date?

    public init(label: String, remaining: Int, resetAt: Date?) {
        self.label = label
        self.remaining = remaining
        self.resetAt = resetAt
    }
}

/// Converts OpenCodex quota rows (percent values are *used* percentages) into windows.
public enum QuotaRow {
    private static let specs: [(label: String, percent: [String], reset: [String])] = [
        ("5h", ["fiveHourPercent", "shortPercent"], ["fiveHourResetAt", "shortResetAt"]),
        ("7d", ["weeklyPercent"], ["weeklyResetAt"]),
        ("30d", ["monthlyPercent"], ["monthlyResetAt"]),
    ]

    public static func windows(_ row: [String: Any], now: Date) -> [QuotaWindow] {
        specs.compactMap { spec in
            guard let used = spec.percent.lazy.compactMap({ number(row[$0]) }).first else { return nil }
            var resetAt: Date?
            if var reset = spec.reset.lazy.compactMap({ number(row[$0]) }).first, reset > 0 {
                if reset < 100_000_000_000 { reset *= 1_000 } // seconds -> milliseconds
                resetAt = Date(timeIntervalSince1970: reset / 1_000)
            }
            if let resetAt, resetAt <= now {
                // The window rolled over since OpenCodex sampled it.
                return QuotaWindow(label: spec.label, remaining: 100, resetAt: nil)
            }
            let remaining = Int(min(max(100 - used, 0), 100).rounded())
            return QuotaWindow(label: spec.label, remaining: remaining, resetAt: resetAt)
        }
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Quota of the ChatGPT account OpenCodex currently routes GPT models through.
public enum CodexAccountQuotaReader {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencodex")

    public static func activeWindows(now: Date = Date()) -> [QuotaWindow] {
        guard let cache = QuotaRow.readObject(directory.appendingPathComponent("codex-quota-cache.json")),
              let quotas = cache["quotas"] as? [String: Any]
        else { return [] }
        let config = QuotaRow.readObject(directory.appendingPathComponent("config.json"))
        let active = config?["activeCodexAccountId"] as? String ?? "__main__"
        guard let row = (quotas[active] ?? quotas["__main__"]) as? [String: Any] else { return [] }
        return QuotaRow.windows(row, now: now)
    }
}
