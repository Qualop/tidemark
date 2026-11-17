import Foundation
import TidemarkCore

private func XCTAssertEqual(_ actual: UsageSnapshot, _ expected: UsageSnapshot) {
    precondition(actual == expected, "Expected \(expected), got \(actual)")
}

@main
final class UsageWindowParserTests {
    static func main() {
        let checks = UsageWindowParserTests()
        checks.testWeeklyOnlyPrimaryIsNotFiveHour()
        checks.testBothWindowsInEitherOrder()
        checks.testAdditionalModelAndUnknownDurationsCannotSupplyDefaults()
        checks.testInvalidValueDoesNotHideOtherWindow()
        checks.testClampingAndZeroAreNotMissing()
        checks.testExplicitRemainingAndNumericStrings()
        checks.testNoWindowsDoesNotInventFullQuota()
        checks.testModelLabelSelectsQuotaSource()
        checks.testOpenCodexCacheUsesProviderRowAsUsedPercent()
        checks.testCodexAccountRowWithSecondResets()
        checks.testDirectSourceParsers()
        print("PASS: 11 quota regression checks")
    }
    private func window(_ seconds: Int, _ used: Double) -> [String: Any] {
        ["limit_window_seconds": seconds, "used_percent": used]
    }

    func testWeeklyOnlyPrimaryIsNotFiveHour() {
        XCTAssertEqual(UsageWindowParser.parse(rateLimit: [
            "primary_window": window(604_800, 8), "secondary_window": NSNull(),
        ]), UsageSnapshot(fiveHourRemaining: nil, weeklyRemaining: 92))
    }

    func testBothWindowsInEitherOrder() {
        let five = window(18_000, 25)
        let week = window(604_800, 40)
        for pair in [(five, week), (week, five)] {
            XCTAssertEqual(UsageWindowParser.parse(rateLimit: [
                "primary_window": pair.0, "secondary_window": pair.1,
            ]), UsageSnapshot(fiveHourRemaining: 75, weeklyRemaining: 60))
        }
    }

    func testAdditionalModelAndUnknownDurationsCannotSupplyDefaults() {
        XCTAssertEqual(UsageWindowParser.parse(rateLimit: [
            "primary_window": window(3_600, 0),
            "secondary_window": ["used_percent": 0],
            "additional_rate_limits": [["primary_window": window(18_000, 0)]],
        ]), .unavailable)
    }

    func testInvalidValueDoesNotHideOtherWindow() {
        for invalid: Any in [NSNull(), true, "NaN", "inf", "invalid"] {
            XCTAssertEqual(UsageWindowParser.parse(rateLimit: [
                "primary_window": ["limit_window_seconds": 18_000, "used_percent": invalid],
                "secondary_window": window(604_800, 8),
            ]), UsageSnapshot(fiveHourRemaining: nil, weeklyRemaining: 92))
        }
    }

    func testClampingAndZeroAreNotMissing() {
        XCTAssertEqual(UsageWindowParser.parse(rateLimit: [
            "primary_window": window(18_000, 110),
            "secondary_window": window(604_800, -10),
        ]), UsageSnapshot(fiveHourRemaining: 0, weeklyRemaining: 100))
    }

    func testExplicitRemainingAndNumericStrings() {
        XCTAssertEqual(UsageWindowParser.parse(rateLimit: [
            "primary_window": ["limit_window_seconds": "604800",
                               "remaining_percent": "71.6", "used_percent": 90],
        ]), UsageSnapshot(fiveHourRemaining: nil, weeklyRemaining: 72))
    }

    func testNoWindowsDoesNotInventFullQuota() {
        XCTAssertEqual(UsageWindowParser.parse(rateLimit: [:]), .unavailable)
    }

    func testModelLabelSelectsQuotaSource() {
        precondition(QuotaSource.from(modelLabel: "anthropic/claude-opus-5-5 High") == .openCodexProvider("anthropic"))
        precondition(QuotaSource.from(modelLabel: "google/gemini-3-pro Medium") == .openCodexProvider("google"))
        precondition(QuotaSource.from(modelLabel: "GPT-5.5 High") == .openAI)
        precondition(QuotaSource.from(modelLabel: "6.1 Sol High") == .openAI)
        precondition(QuotaSource.from(modelLabel: "6 Astra") == .openAI)
        precondition(QuotaSource.from(modelLabel: "openai/gpt-5.5") == .openAI)
        precondition(QuotaSource.from(modelLabel: nil) == .openAI)
        precondition(QuotaSource.looksLikeModelLabel("anthropic/claude-opus-5-5 High"))
        precondition(QuotaSource.looksLikeModelLabel("GPT-5.5 High"))
        precondition(!QuotaSource.looksLikeModelLabel("Full access"))
        // Claude app picker (OpenCodex adds GPT models there).
        precondition(QuotaSource.forClaudeApp(modelLabel: "모델: Opus 5.5 높음 Opus 5.5 높음") == .openCodexProvider("anthropic"))
        precondition(QuotaSource.forClaudeApp(modelLabel: "Sonnet 5.5") == .openCodexProvider("anthropic"))
        precondition(QuotaSource.forClaudeApp(modelLabel: "모델: GPT 6.1 Sol (native) GPT 6.1 Sol (native)") == .openAI)
        precondition(QuotaSource.forClaudeApp(modelLabel: "GPT 6 Astra (native)") == .openAI)
        precondition(QuotaSource.forClaudeApp(modelLabel: nil) == .openCodexProvider("anthropic"))
    }

    func testOpenCodexCacheUsesProviderRowAsUsedPercent() {
        let now = Date(timeIntervalSince1970: 1_794_903_200)
        let json = """
        {"version":1,"rows":{
          "anthropic\\u0000old":{"fiveHourPercent":90,"weeklyPercent":90,"updatedAt":1},
          "anthropic\\u0000new":{"fiveHourPercent":4,"fiveHourResetAt":1794920400000,
                                 "weeklyPercent":49,"weeklyResetAt":1795050000000,"updatedAt":1794903194606},
          "other\\u0000x":{"fiveHourPercent":1,"weeklyPercent":1,"updatedAt":2}}}
        """
        let data = Data(json.utf8)
        XCTAssertEqual(OpenCodexQuotaReader.parse(data: data, provider: "anthropic", now: now)!,
                       UsageSnapshot(fiveHourRemaining: 96, weeklyRemaining: 51))
        let afterFiveHourReset = Date(timeIntervalSince1970: 1_794_920_401)
        XCTAssertEqual(OpenCodexQuotaReader.parse(data: data, provider: "anthropic", now: afterFiveHourReset)!,
                       UsageSnapshot(fiveHourRemaining: 100, weeklyRemaining: 51))
        precondition(OpenCodexQuotaReader.parse(data: data, provider: "google", now: now) == nil)
    }

    func testCodexAccountRowWithSecondResets() {
        let now = Date(timeIntervalSince1970: 1_794_905_600)
        let windows = QuotaRow.windows(["monthlyPercent": 1, "monthlyResetAt": 1_797_494_415, "updatedAt": 1], now: now)
        precondition(windows == [QuotaWindow(label: "30d", remaining: 99,
                                             resetAt: Date(timeIntervalSince1970: 1_797_494_415))], "\(windows)")
    }

    func testDirectSourceParsers() {
        let now = Date(timeIntervalSince1970: 1_794_905_600)
        // Claude: utilization is the used share (0-100).
        let claude = ClaudeUsageParser.windows([
            "five_hour": ["utilization": 23.0, "resets_at": "2026-11-17T13:00:00.123+00:00"],
            "seven_day": ["utilization": 56, "resets_at": "2026-11-19T01:00:00Z"],
            "seven_day_opus": ["utilization": 10],
        ], now: now)
        precondition(claude.map(\.label) == ["5h", "7d"] && claude.map(\.remaining) == [77, 44], "\(claude)")
        precondition(claude[0].resetAt != nil, "fractional-second ISO date")
        // Gemini: tightest bucket per family; remainingFraction is 0-1.
        let gemini = GeminiQuotaParser.windows(["buckets": [
            ["modelId": "gemini-2.5-pro", "remainingFraction": 0.8, "resetTime": "2026-11-18T00:00:00Z"],
            ["modelId": "gemini-3-pro-preview", "remainingFraction": 0.35],
            ["modelId": "gemini-2.5-flash", "remainingFraction": 1],
        ]], now: now)
        precondition(gemini.map(\.label) == ["Pro", "Flash"] && gemini.map(\.remaining) == [35, 100], "\(gemini)")
        // ChatGPT monthly plan: no 5h/7d bars, but a 30d window for the card.
        let wham = UsageWindowParser.windows(rateLimit: [
            "primary_window": ["limit_window_seconds": 2_592_000, "used_percent": 3, "reset_at": 1_797_494_415],
        ], now: now)
        precondition(wham == [QuotaWindow(label: "30d", remaining: 97, resetAt: Date(timeIntervalSince1970: 1_797_494_415))], "\(wham)")
        // Claude app's own control reports the used share.
        precondition(ClaudeAppUsageParser.fiveHourRemaining(from: "사용량: 5시간 한도의 77% 오후 10:00에 초기화") == 23)
        precondition(ClaudeAppUsageParser.fiveHourRemaining(from: "Usage: 40% of 5-hour limit") == 60)
        precondition(ClaudeAppUsageParser.fiveHourRemaining(from: "모델: Opus 5.5 높음") == nil)
    }
}
