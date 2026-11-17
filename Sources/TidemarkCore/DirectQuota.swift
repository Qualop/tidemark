import Foundation
import Security

/// Quota straight from each vendor, so Tidemark works without OpenCodex.
/// Credentials are read on demand, kept in memory only, and never written anywhere.
/// Claude and Gemini are separate actors so a pending Keychain prompt never delays Gemini.
private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 15
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration)
}

public actor ClaudeQuotaFetcher {
    private let session = makeSession()
    private var claudeToken: (value: String, expires: Date)?
    private var claudeBackoffUntil = Date.distantPast
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    public init() {}

    // MARK: Claude (Claude Code's OAuth login)

    /// nil when Claude Code is not signed in, its token has expired, or the request failed.
    /// The Keychain is only touched when useKeychain is set (macOS asks once).
    public func claudeWindows(useKeychain: Bool, now: Date = Date()) async -> [QuotaWindow]? {
        guard now >= claudeBackoffUntil, let token = claudeAccessToken(useKeychain: useKeychain, now: now) else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tidemark/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        switch http.statusCode {
        case 200:
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return ClaudeUsageParser.windows(root, now: now)
        case 401, 403:
            claudeToken = nil // re-read next time; Claude Code refreshes its own token
            return nil
        case 429:
            claudeBackoffUntil = now.addingTimeInterval(300)
            return nil
        default:
            return nil
        }
    }

    /// Read-only: refreshing would rotate Claude Code's refresh token and sign it out.
    private func claudeAccessToken(useKeychain: Bool, now: Date) -> String? {
        if let claudeToken, claudeToken.expires > now.addingTimeInterval(30) { return claudeToken.value }
        claudeToken = nil
        var data: Data?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if useKeychain, SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess { data = item as? Data }
        if data == nil { data = try? Data(contentsOf: Self.home.appendingPathComponent(".claude/.credentials.json")) }
        guard let data,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expires = QuotaRow.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1_000) } ?? now.addingTimeInterval(600)
        guard expires > now.addingTimeInterval(30) else { return nil }
        claudeToken = (token, expires)
        return token
    }

}

public actor GeminiQuotaFetcher {
    private let session = makeSession()
    private var geminiClient: (id: String, secret: String)?
    private var geminiClientSearched = false
    private var geminiToken: (value: String, expires: Date)?
    private var geminiProject: String?
    private var geminiFetchedAt = Date.distantPast
    private var geminiCache: [QuotaWindow] = []
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    public init() {}

    // MARK: Gemini (Gemini CLI's Google login)

    /// Empty when Gemini CLI is not installed or signed in. Fetched at most every 5 minutes.
    public func geminiWindows(now: Date = Date()) async -> [QuotaWindow] {
        let credentials = Self.home.appendingPathComponent(".gemini/oauth_creds.json")
        guard FileManager.default.fileExists(atPath: credentials.path) else { return [] }
        guard now.timeIntervalSince(geminiFetchedAt) >= 300 else { return geminiCache }
        geminiFetchedAt = now
        guard let token = await geminiAccessToken(credentials: credentials, now: now) else { return geminiCache }
        if geminiProject == nil { geminiProject = await geminiLoadProject(token: token) }
        let body: [String: Any] = geminiProject.map { ["project": $0] } ?? [:]
        guard let root = await geminiPost("retrieveUserQuota", token: token, body: body) else { return geminiCache }
        geminiCache = GeminiQuotaParser.windows(root, now: now)
        return geminiCache
    }

    private func geminiAccessToken(credentials: URL, now: Date) async -> String? {
        if let geminiToken, geminiToken.expires > now.addingTimeInterval(60) { return geminiToken.value }
        guard let data = try? Data(contentsOf: credentials),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let token = root["access_token"] as? String,
           let expiry = QuotaRow.number(root["expiry_date"]),
           Date(timeIntervalSince1970: expiry / 1_000) > now.addingTimeInterval(60) {
            return token
        }
        // Expired: refresh in memory. Google refresh tokens do not rotate, so Gemini CLI is unaffected.
        guard let refresh = root["refresh_token"] as? String, let client = geminiOAuthClient() else { return nil }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "client_secret", value: client.secret),
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        guard let (body, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let token = json["access_token"] as? String
        else { return nil }
        let lifetime = QuotaRow.number(json["expires_in"]) ?? 3_000
        geminiToken = (token, now.addingTimeInterval(lifetime))
        return token
    }

    private func geminiLoadProject(token: String) async -> String? {
        let metadata = ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]
        guard let root = await geminiPost("loadCodeAssist", token: token, body: ["metadata": metadata]) else { return nil }
        if let project = root["cloudaicompanionProject"] as? String { return project }
        return (root["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
    }

    private func geminiPost(_ method: String, token: String, body: [String: Any]) async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:\(method)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Gemini CLI's public installed-app OAuth client, read from the CLI's own bundle so it
    /// never has to be copied into this repository. Looked up once.
    private func geminiOAuthClient() -> (id: String, secret: String)? {
        if geminiClientSearched { return geminiClient }
        geminiClientSearched = true
        let fm = FileManager.default
        var bundles = [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle",
            "/usr/local/lib/node_modules/@google/gemini-cli/bundle",
        ]
        let nvm = Self.home.appendingPathComponent(".nvm/versions/node").path
        for version in (try? fm.contentsOfDirectory(atPath: nvm)) ?? [] {
            bundles.append("\(nvm)/\(version)/lib/node_modules/@google/gemini-cli/bundle")
        }
        for cellar in ["/opt/homebrew/Cellar/gemini-cli", "/usr/local/Cellar/gemini-cli"] {
            for version in (try? fm.contentsOfDirectory(atPath: cellar)) ?? [] {
                bundles.append("\(cellar)/\(version)/libexec/lib/node_modules/@google/gemini-cli/bundle")
            }
        }
        for directory in bundles {
            for file in ((try? fm.contentsOfDirectory(atPath: directory)) ?? []) where file.hasSuffix(".js") {
                // Memory-mapped: nothing is copied unless the marker is present.
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(directory)/\(file)"), options: .alwaysMapped),
                      let id = Self.quotedValue(after: "OAUTH_CLIENT_ID = \"", in: data),
                      let secret = Self.quotedValue(after: "OAUTH_CLIENT_SECRET = \"", in: data)
                else { continue }
                geminiClient = (id, secret)
                return geminiClient
            }
        }
        return nil
    }

    private static func quotedValue(after marker: String, in data: Data) -> String? {
        guard let start = data.range(of: Data(marker.utf8))?.upperBound,
              let end = data[start...].firstIndex(of: UInt8(ascii: "\"")),
              end - start < 200
        else { return nil }
        return String(data: data[start..<end], encoding: .utf8)
    }
}

/// `GET api.anthropic.com/api/oauth/usage`: five_hour / seven_day with utilization (0-100).
public enum ClaudeUsageParser {
    public static func windows(_ root: [String: Any], now: Date) -> [QuotaWindow] {
        [("five_hour", "5h"), ("seven_day", "7d")].compactMap { key, label in
            guard let window = root[key] as? [String: Any],
                  let used = QuotaRow.number(window["utilization"]) else { return nil }
            let resetAt = (window["resets_at"] as? String).flatMap(isoDate)
            if let resetAt, resetAt <= now { return QuotaWindow(label: label, remaining: 100, resetAt: nil) }
            return QuotaWindow(label: label, remaining: Int(min(max(100 - used, 0), 100).rounded()), resetAt: resetAt)
        }
    }

    static func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// `retrieveUserQuota`: per-model buckets with remainingFraction (0-1) and resetTime.
/// Shown as the tightest Pro and Flash buckets.
public enum GeminiQuotaParser {
    public static func windows(_ root: [String: Any], now: Date) -> [QuotaWindow] {
        guard let buckets = root["buckets"] as? [[String: Any]] else { return [] }
        var tightest: [String: (remaining: Int, reset: Date?)] = [:]
        for bucket in buckets {
            guard let fraction = QuotaRow.number(bucket["remainingFraction"]) else { continue }
            let model = (bucket["modelId"] as? String ?? "").lowercased()
            let family = model.contains("flash") ? "Flash" : model.contains("pro") ? "Pro" : "1d"
            var reset = (bucket["resetTime"] as? String).flatMap(ClaudeUsageParser.isoDate)
            var remaining = Int(min(max(fraction * 100, 0), 100).rounded())
            if let date = reset, date <= now { remaining = 100; reset = nil }
            if let current = tightest[family], current.remaining <= remaining { continue }
            tightest[family] = (remaining, reset)
        }
        return ["Pro", "Flash", "1d"].compactMap { family in
            tightest[family].map { QuotaWindow(label: family, remaining: $0.remaining, resetAt: $0.reset) }
        }
    }
}

/// The Claude desktop app's own usage control, e.g. "사용량: 5시간 한도의 77% 오후 10:00에 초기화"
/// ("Usage: 77% of the 5-hour limit ..."). The percentage is the share already used.
public enum ClaudeAppUsageParser {
    public static func fiveHourRemaining(from text: String) -> Int? {
        let lowered = text.lowercased()
        guard lowered.contains("사용량") || lowered.contains("usage") else { return nil }
        guard let range = lowered.range(of: #"\d{1,3}(?=\s*%)"#, options: .regularExpression),
              let used = Int(lowered[range]), used <= 100 else { return nil }
        return 100 - used
    }
}
