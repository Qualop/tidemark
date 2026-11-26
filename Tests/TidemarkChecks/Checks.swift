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
        checks.testTokenSpeedTrackers()
        print("PASS: 12 quota regression checks")
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
        precondition(QuotaSource.forClaudeApp(modelLabel: "모델: Claude Opus 5 (anthropic2) 높음") == .openCodexProvider("anthropic2"))
        precondition(QuotaSource.forClaudeApp(modelLabel: "ocx-claude-anthropic2--claude-opus-5[1m]") == .openCodexProvider("anthropic2"))
        precondition(QuotaSource.forClaudeApp(modelLabel: "Claude Opus 5 (anthropic)") == .openCodexProvider("anthropic"))
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
          "anthropic2\\u0000x":{"fiveHourPercent":25,"weeklyPercent":70,"updatedAt":3},
          "other\\u0000x":{"fiveHourPercent":1,"weeklyPercent":1,"updatedAt":2}}}
        """
        let data = Data(json.utf8)
        XCTAssertEqual(OpenCodexQuotaReader.parse(data: data, provider: "anthropic", now: now)!,
                       UsageSnapshot(fiveHourRemaining: 96, weeklyRemaining: 51))
        let afterFiveHourReset = Date(timeIntervalSince1970: 1_794_920_401)
        XCTAssertEqual(OpenCodexQuotaReader.parse(data: data, provider: "anthropic", now: afterFiveHourReset)!,
                       UsageSnapshot(fiveHourRemaining: 100, weeklyRemaining: 51))
        precondition(OpenCodexQuotaReader.parse(data: data, provider: "google", now: now) == nil)
        let account = QuotaSource.forClaudeApp(modelLabel: "Claude Opus 5 (anthropic2)")
        XCTAssertEqual(OpenCodexQuotaReader.parse(data: data, provider: account.identifier, now: now)!,
                       UsageSnapshot(fiveHourRemaining: 75, weeklyRemaining: 30))
    }

    func testCodexAccountRowWithSecondResets() {
        let now = Date(timeIntervalSince1970: 1_794_905_600)
        let windows = QuotaRow.windows(["monthlyPercent": 1, "monthlyResetAt": 1_797_494_415, "updatedAt": 1], now: now)
        precondition(windows == [QuotaWindow(label: "30d", remaining: 99,
                                             resetAt: Date(timeIntervalSince1970: 1_797_494_415))], "\(windows)")
    }

    func testTokenSpeedTrackers() {
        // Codex: input (tool output) at :00, reply of 500 output tokens ends at :05 -> 100 tok/s.
        var codex = CodexSpeedTracker()
        _ = codex.feed(["timestamp": "2026-11-17T08:38:00.000Z", "type": "response_item",
                        "payload": ["type": "function_call_output"]])
        let codexSpeed = codex.feed(["timestamp": "2026-11-17T08:38:05.000Z", "type": "event_msg",
                                     "payload": ["type": "token_count", "info": ["last_token_usage": ["output_tokens": 500]]]])
        precondition(codexSpeed.map { Int($0.tokensPerSecond) } == 100, "\(String(describing: codexSpeed))")
        // A token_count without a preceding input is not a measurement.
        precondition(codex.feed(["timestamp": "2026-11-17T08:38:09.000Z", "type": "event_msg",
                                 "payload": ["type": "token_count", "info": ["last_token_usage": ["output_tokens": 50]]]]) == nil)
        // Current Codex: the reply ends at token_usage_record; token_count comes after the tool
        // runs and must not be measured (it would give a near-zero duration).
        var current = CodexSpeedTracker()
        _ = current.feed(["timestamp": "2026-11-17T18:45:00.000Z", "type": "response_item",
                          "payload": ["type": "custom_tool_call_output"]])
        let record = current.feed(["timestamp": "2026-11-17T18:45:10.000Z", "type": "token_usage_record",
                                   "payload": ["usage": ["output_tokens": 900]]])
        precondition(record.map { Int($0.tokensPerSecond) } == 90, "\(String(describing: record))")
        _ = current.feed(["timestamp": "2026-11-17T18:45:14.340Z", "type": "response_item",
                          "payload": ["type": "custom_tool_call_output"]])
        precondition(current.feed(["timestamp": "2026-11-17T18:45:14.341Z", "type": "event_msg",
                                   "payload": ["type": "token_count", "info": ["last_token_usage": ["output_tokens": 900]]]]) == nil)
        precondition(CodexSpeedTracker.isDesktopSession(["payload": ["originator": "Codex Desktop", "source": "vscode"]]))
        precondition(!CodexSpeedTracker.isDesktopSession(["payload": ["originator": "Codex Desktop", "source": ["subagent": ["other": "guardian"]]]]))
        precondition(!CodexSpeedTracker.isDesktopSession(["payload": ["originator": "codex_cli_rs"]]))

        // Claude: api-request at :39.084, 518 tokens, last line at :44.510 -> ~95 tok/s.
        var claude = ClaudeSpeedTracker()
        _ = claude.feed(["timestamp": "2026-11-17T18:44:39.084Z", "type": "api-request"])
        let line: [String: Any] = ["timestamp": "2026-11-17T18:44:44.510Z", "type": "assistant", "entrypoint": "claude-desktop",
                                   "message": ["id": "msg_1", "usage": ["output_tokens": 518]]]
        precondition(claude.feed(line).map { Int($0.tokensPerSecond) } == 95)
        var cli = line
        cli["entrypoint"] = "cli"
        precondition(claude.feed(cli) == nil, "terminal Claude Code is not the app")
        // Model names as shown in the card.
        precondition(ModelName.display("anthropic/claude-opus-5-5") == "Opus 5.5")
        precondition(ModelName.display("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        precondition(ModelName.display("ocx-claude-native--gpt-6.1-sol[1m]") == "GPT 6.1 Sol")
        precondition(ModelName.display("gpt-5.5-codex") == "GPT 5.5 Codex")
        // Plans: Claude Ultra and GPT Pro show the plan instead of a 5h bar.
        let rules = PlanRules.defaultNoFiveHour
        precondition(PlanRules.hidesFiveHour(provider: "claude", plan: "Ultra", rules: rules))
        precondition(!PlanRules.hidesFiveHour(provider: "claude", plan: "Pro", rules: rules))
        precondition(PlanRules.hidesFiveHour(provider: "gpt", plan: "pro", rules: rules))
        precondition(PlanRules.claudePlan(fromAccountLabel: "민지 Pro") == "Pro")
        precondition(PlanRules.claudePlan(fromAccountLabel: "Alex · Ultra") == "Ultra")
        precondition(PlanRules.claudePlan(fromAccountLabel: "새로 만들기") == nil)
        let ultra = UsageSnapshot(windows: [QuotaWindow(label: "5h", remaining: 100, resetAt: nil),
                                            QuotaWindow(label: "7d", remaining: 64, resetAt: nil)], plan: "Ultra", hideFiveHour: true)
        precondition(ultra.showsPlan && ultra.weeklyRemaining == 64 && ultra.longLabel == "7d")
        let monthly = UsageSnapshot(windows: [QuotaWindow(label: "30d", remaining: 96, resetAt: nil)], plan: "Free")
        precondition(monthly.showsPlan && monthly.weeklyRemaining == 96 && monthly.longLabel == "30d")
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
