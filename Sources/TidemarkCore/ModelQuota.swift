import Foundation
import CoreFoundation

/// Where the quota for the model currently selected in the composer comes from.
public enum QuotaSource: Equatable, Sendable {
    /// ChatGPT account limits from `wham/usage` (built-in OpenAI models).
    case openAI
    /// A provider routed through OpenCodex, e.g. "anthropic" for "anthropic/claude-opus-5-5".
    case openCodexProvider(String)

    public var identifier: String {
        switch self {
        case .openAI: return "openai"
        case .openCodexProvider(let provider): return provider
        }
    }

    /// Maps the model selector's visible text (for example "anthropic/claude-opus-5-5 High")
    /// to a quota source. Unknown or unreadable labels keep the original OpenAI behaviour.
    public static func from(modelLabel: String?) -> QuotaSource {
        guard let raw = modelLabel?.lowercased(), !raw.isEmpty else { return .openAI }
        for token in raw.split(whereSeparator: { $0.isWhitespace }) {
            guard let slash = token.firstIndex(of: "/"), slash != token.startIndex else { continue }
            let provider = String(token[..<slash])
            guard provider.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { continue }
            return provider == "openai" ? .openAI : .openCodexProvider(provider)
        }
        if ["claude", "opus", "sonnet", "haiku"].contains(where: { raw.contains($0) }) {
            return .openCodexProvider("anthropic")
        }
        return .openAI
    }

    /// The Claude app's picker lists Claude models, plus GPT models that OpenCodex adds
    /// (e.g. "GPT 6.1 Sol (native)"). Anything not clearly another provider is Claude.
    public static func forClaudeApp(modelLabel: String?) -> QuotaSource {
        guard let raw = modelLabel?.lowercased(), !raw.isEmpty else { return .openCodexProvider("anthropic") }
        if ["gpt", "codex", "openai"].contains(where: { raw.contains($0) }) { return .openAI }
        if raw.split(whereSeparator: { $0.isWhitespace }).contains(where: { $0.contains("/") }) {
            return from(modelLabel: raw)
        }
        if raw.contains("gemini") { return .openCodexProvider("google") }
        return .openCodexProvider("anthropic")
    }

    /// True when a control's text plausibly names a model (used to pick the selector).
    public static func looksLikeModelLabel(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.split(whereSeparator: { $0.isWhitespace }).contains(where: { token in
            guard let slash = token.firstIndex(of: "/") else { return false }
            return slash != token.startIndex && token.index(after: slash) != token.endIndex
        }) { return true }
        return ["gpt", "codex", "claude", "opus", "sonnet", "haiku", "gemini"].contains(where: { lowered.contains($0) })
    }
}

/// Reads the per-provider account quota that OpenCodex already keeps up to date.
public enum OpenCodexQuotaReader {
    public static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".opencodex/provider-account-quota-cache.json")

    public static func snapshot(provider: String, now: Date = Date()) -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return parse(data: data, provider: provider, now: now)
    }

    /// All windows (with reset times) for the hover card.
    public static func windows(provider: String, now: Date = Date()) -> [QuotaWindow] {
        guard let data = try? Data(contentsOf: cacheURL), let row = row(data: data, provider: provider) else { return [] }
        return QuotaRow.windows(row, now: now)
    }

    /// Rows are keyed "<provider>\u{0}<account hash>"; percents are *used* percentages.
    public static func parse(data: Data, provider: String, now: Date) -> UsageSnapshot? {
        guard let row = row(data: data, provider: provider) else { return nil }
        let windows = QuotaRow.windows(row, now: now)
        let fiveHour = windows.first { $0.label == "5h" }?.remaining
        let weekly = windows.first { $0.label == "7d" }?.remaining
        guard fiveHour != nil || weekly != nil else { return nil }
        return UsageSnapshot(fiveHourRemaining: fiveHour, weeklyRemaining: weekly)
    }

    private static func row(data: Data, provider: String) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["rows"] as? [String: Any]
        else { return nil }
        let prefix = provider.lowercased() + "\u{0}"
        let matching = rows.compactMap { key, value -> [String: Any]? in
            let lowered = key.lowercased()
            guard lowered == provider.lowercased() || lowered.hasPrefix(prefix) else { return nil }
            return value as? [String: Any]
        }
        return matching.max(by: { (QuotaRow.number($0["updatedAt"]) ?? 0) < (QuotaRow.number($1["updatedAt"]) ?? 0) })
    }
}
