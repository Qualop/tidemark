import Foundation

/// UI strings. The language is chosen at build time (-Xswiftc -DTIDEMARK_KO) so each
/// release ships one language with no localization bundles.
enum L10n {
#if TIDEMARK_KO
    static let noData = "정보 없음"
    static let speedTitle = "토큰 속도 (최근 응답)"

    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "방금" }
        if minutes < 60 { return "\(minutes)분 전" }
        if minutes < 1_440 { return "\(minutes / 60)시간 전" }
        return "\(minutes / 1_440)일 전"
    }

    static func resetText(_ date: Date?, now: Date) -> String {
        guard let parts = parts(date, now: now) else { return date == nil ? "" : "곧 초기화" }
        if parts.days > 0 { return parts.hours > 0 ? "\(parts.days)일 \(parts.hours)시간 후" : "\(parts.days)일 후" }
        if parts.hours > 0 { return parts.minutes > 0 ? "\(parts.hours)시간 \(parts.minutes)분 후" : "\(parts.hours)시간 후" }
        return "\(parts.minutes)분 후"
    }
#else
    static let noData = "No data"
    static let speedTitle = "Token speed (last reply)"

    static func ago(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        if minutes < 1_440 { return "\(minutes / 60)h ago" }
        return "\(minutes / 1_440)d ago"
    }

    static func resetText(_ date: Date?, now: Date) -> String {
        guard let parts = parts(date, now: now) else { return date == nil ? "" : "resets soon" }
        if parts.days > 0 { return parts.hours > 0 ? "in \(parts.days)d \(parts.hours)h" : "in \(parts.days)d" }
        if parts.hours > 0 { return parts.minutes > 0 ? "in \(parts.hours)h \(parts.minutes)m" : "in \(parts.hours)h" }
        return "in \(parts.minutes)m"
    }
#endif

    /// nil when there is no reset time or it is under a minute away.
    private static func parts(_ date: Date?, now: Date) -> (days: Int, hours: Int, minutes: Int)? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds >= 60 else { return nil }
        let minutes = seconds / 60
        return (minutes / 1_440, (minutes / 60) % 24, minutes % 60)
    }
}
