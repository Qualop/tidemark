import Foundation

public struct UsageSnapshot: Sendable, Equatable {
    public let fiveHourRemaining: Int?
    public let weeklyRemaining: Int?
    /// Plan name (e.g. "Ultra"), shown in place of the 5h bar when the plan has no 5h limit.
    public let plan: String?
    /// Label of the long window: "7d", or "30d" for monthly-only plans.
    public let longLabel: String

    public init(fiveHourRemaining: Int?, weeklyRemaining: Int?, plan: String? = nil, longLabel: String = "7d") {
        self.fiveHourRemaining = fiveHourRemaining
        self.weeklyRemaining = weeklyRemaining
        self.plan = plan
        self.longLabel = longLabel
    }

    /// True when the first slot shows the plan instead of a 5h bar.
    public var showsPlan: Bool { fiveHourRemaining == nil && plan != nil }

    public static let unavailable = UsageSnapshot(fiveHourRemaining: nil, weeklyRemaining: nil)
}

extension UsageSnapshot {
    /// The bars' values from a list of windows. Without a 5h window (or on a plan with no 5h
    /// limit) the plan name takes that slot; without a 7d window the monthly one is used.
    public init(windows: [QuotaWindow], plan: String? = nil, hideFiveHour: Bool = false) {
        let five = hideFiveHour ? nil : windows.first { $0.label == "5h" }?.remaining
        let long = windows.first { $0.label == "7d" } ?? windows.first { $0.label == "30d" }
        self.init(fiveHourRemaining: five, weeklyRemaining: long?.remaining,
                  plan: plan, longLabel: long?.label ?? "7d")
    }
}

/// Plans whose 5-hour limit is not worth a bar, as "provider:plan" (from config).
public enum PlanRules {
    public static let defaultNoFiveHour = ["claude:ultra", "gpt:pro"]

    public static func hidesFiveHour(provider: String, plan: String?, rules: [String]) -> Bool {
        guard let plan = plan?.lowercased().replacingOccurrences(of: " ", with: "") else { return false }
        return rules.contains("\(provider.lowercased()):\(plan)")
    }

    /// "prolite" -> "Pro Lite", "free" -> "Free".
    public static func displayName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let known = ["prolite": "Pro Lite", "chatgptpro": "Pro", "enterprise": "Enterprise", "edu": "Edu"]
        if let name = known[raw.lowercased()] { return name }
        return raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
    }

    /// Claude app account button, e.g. "성우 Pro" or "Sungwoo · Ultra" -> "Ultra".
    public static func claudePlan(fromAccountLabel label: String) -> String? {
        let plans = ["free", "pro", "max", "ultra", "team", "enterprise"]
        let words = label.lowercased().split { $0.isWhitespace || $0 == "·" || $0 == "•" }
        guard let last = words.last, plans.contains(String(last)) else { return nil }
        return displayName(String(last))
    }
}

/// ChatGPT usage: the bar values plus every window for the hover card.
public struct OpenAIUsage: Sendable {
    public let snapshot: UsageSnapshot
    public let windows: [QuotaWindow]
    /// "free", "plus", "pro", ... as reported by the usage endpoint.
    public let plan: String?
}

private struct AuthMaterial {
    let accessToken: String
    let accountID: String?
}

private struct FetchFailure: Error {
    let kind: String
    let httpStatus: Int?
    let retryable: Bool
}

public actor UsageFetcher {
    private let session: URLSession
    private let maximumAttempts: Int
    private let retryDelayMilliseconds: Int
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public init(maximumAttempts: Int, retryDelayMilliseconds: Int) {
        self.maximumAttempts = maximumAttempts
        self.retryDelayMilliseconds = retryDelayMilliseconds
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    public func refresh() async -> OpenAIUsage? {
        var finalFailure = FetchFailure(kind: "unknown", httpStatus: nil, retryable: false)
        var attempted = 0

        for attempt in 1...maximumAttempts {
            attempted = attempt
            do {
                let snapshot = try await requestOnce()
                SanitizedStatus.write(success: true, attempts: attempt, httpStatus: 200, errorKind: nil)
                return snapshot
            } catch let failure as FetchFailure {
                finalFailure = failure
                if !failure.retryable || attempt == maximumAttempts { break }
            } catch {
                finalFailure = FetchFailure(kind: "unexpected", httpStatus: nil, retryable: true)
                if attempt == maximumAttempts { break }
            }

            try? await Task.sleep(nanoseconds: UInt64(retryDelayMilliseconds) * 1_000_000)
        }

        SanitizedStatus.write(
            success: false,
            attempts: attempted,
            httpStatus: finalFailure.httpStatus,
            errorKind: finalFailure.kind
        )
        return nil
    }

    private func requestOnce() async throws -> OpenAIUsage {
        let auth = try loadAuthMaterial()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = auth.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tidemark/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            let kind = error.code == .timedOut ? "timeout" : "network"
            throw FetchFailure(kind: kind, httpStatus: nil, retryable: true)
        } catch {
            throw FetchFailure(kind: "network", httpStatus: nil, retryable: true)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FetchFailure(kind: "invalid-response", httpStatus: nil, retryable: true)
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw FetchFailure(kind: "authentication", httpStatus: http.statusCode, retryable: false)
            }
            let retryable = http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode)
            throw FetchFailure(kind: retryable ? "http-temporary" : "http-permanent", httpStatus: http.statusCode, retryable: retryable)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = root["rate_limit"] as? [String: Any]
        else {
            throw FetchFailure(kind: "invalid-payload", httpStatus: http.statusCode, retryable: true)
        }

        // Intentionally ignore `additional_rate_limits`: only the top-level default rate_limit is authoritative.
        return OpenAIUsage(snapshot: UsageWindowParser.parse(rateLimit: rateLimit),
                           windows: UsageWindowParser.windows(rateLimit: rateLimit, now: Date()),
                           plan: root["plan_type"] as? String)
    }

    private func loadAuthMaterial() throws -> AuthMaterial {
        let authURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty
        else {
            throw FetchFailure(kind: "authentication-missing", httpStatus: nil, retryable: false)
        }
        let accountID = tokens["account_id"] as? String
        return AuthMaterial(accessToken: accessToken, accountID: accountID)
    }

}
