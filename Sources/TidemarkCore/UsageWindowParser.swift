import Foundation
import CoreFoundation

public enum UsageWindowParser {
    /// Window order is not a duration contract: weekly-only plans use primary_window.
    public static func parse(rateLimit: [String: Any]) -> UsageSnapshot {
        var fiveHour: Int?
        var weekly: Int?
        for key in ["primary_window", "secondary_window"] {
            guard let window = rateLimit[key] as? [String: Any],
                  let seconds = finiteNumber(window["limit_window_seconds"]),
                  let remaining = remainingPercent(window) else { continue }
            switch seconds {
            case 18_000:
                fiveHour = min(fiveHour ?? remaining, remaining)
            case 604_800:
                weekly = min(weekly ?? remaining, remaining)
            default:
                // Unknown or missing durations must never be guessed from their slot.
                continue
            }
        }
        return UsageSnapshot(fiveHourRemaining: fiveHour, weeklyRemaining: weekly)
    }

    /// Every window with its reset time, for the hover card (5h, 7d and monthly plans).
    public static func windows(rateLimit: [String: Any], now: Date) -> [QuotaWindow] {
        var result: [QuotaWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let window = rateLimit[key] as? [String: Any],
                  let seconds = finiteNumber(window["limit_window_seconds"]),
                  let remaining = remainingPercent(window) else { continue }
            let label: String
            switch seconds {
            case 18_000: label = "5h"
            case 604_800: label = "7d"
            case 2_419_200...2_678_400: label = "30d"
            default: continue
            }
            var resetAt: Date?
            if let at = finiteNumber(window["reset_at"]) {
                resetAt = Date(timeIntervalSince1970: at > 100_000_000_000 ? at / 1_000 : at)
            } else if let after = finiteNumber(window["reset_after_seconds"]) {
                resetAt = now.addingTimeInterval(after)
            }
            result.append(QuotaWindow(label: label, remaining: remaining, resetAt: resetAt))
        }
        let order = ["5h", "7d", "30d"]
        return result.sorted { (order.firstIndex(of: $0.label) ?? 9) < (order.firstIndex(of: $1.label) ?? 9) }
    }

    private static func remainingPercent(_ window: [String: Any]) -> Int? {
        let remaining = finiteNumber(window["remaining_percent"])
            ?? finiteNumber(window["used_percent"]).map { 100 - $0 }
        guard let remaining else { return nil }
        return Int(min(max(remaining, 0), 100).rounded())
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        let result: Double?
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            result = number.doubleValue
        } else if let string = value as? String {
            result = Double(string)
        } else {
            result = nil
        }
        guard let result, result.isFinite else { return nil }
        return result
    }
}
