import Foundation

public struct UsageSnapshot: Sendable, Equatable {
    public let fiveHourRemaining: Int?
    public let weeklyRemaining: Int?

    public init(fiveHourRemaining: Int?, weeklyRemaining: Int?) {
        self.fiveHourRemaining = fiveHourRemaining
        self.weeklyRemaining = weeklyRemaining
    }

    public static let unavailable = UsageSnapshot(fiveHourRemaining: nil, weeklyRemaining: nil)
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

    public func refresh() async -> UsageSnapshot? {
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

    private func requestOnce() async throws -> UsageSnapshot {
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
        return UsageWindowParser.parse(rateLimit: rateLimit)
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
