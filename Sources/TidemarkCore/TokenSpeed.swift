import Foundation
import CoreServices

/// Output speed of the latest model response, measured from the app's own session log:
/// output tokens divided by the time from the request (or its input) to the end of the reply.
public struct TokenSpeed: Equatable, Sendable {
    public let tokensPerSecond: Double
    public let at: Date
    /// Display name of the model that produced the reply, e.g. "Opus 5.5".
    public let model: String

    public init(tokensPerSecond: Double, at: Date, model: String = "") {
        self.tokensPerSecond = tokensPerSecond
        self.at = at
        self.model = model
    }
}

/// Short, readable model names: "anthropic/claude-opus-5-5" -> "Opus 5.5",
/// "ocx-claude-native--gpt-6.1-sol[1m]" -> "GPT 6.1 Sol", "gpt-5.5-codex" -> "GPT 5.5 Codex".
public enum ModelName {
    public static func display(_ raw: String) -> String {
        var name = raw.lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let range = name.range(of: "--", options: .backwards) { name = String(name[range.upperBound...]) }
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        var parts = name.split(separator: "-").map(String.init)
        if parts.last.map({ $0.count == 8 && $0.allSatisfy(\.isNumber) }) == true { parts.removeLast() } // date suffix
        guard !parts.isEmpty else { return raw }
        if parts.first == "claude", parts.count >= 2 {
            let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
            let version = parts.dropFirst(2).filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            return version.isEmpty ? family : "\(family) \(version)"
        }
        if parts.first == "gpt" {
            return (["GPT"] + parts.dropFirst().map { $0.first?.isLetter == true ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 })
                .joined(separator: " ")
        }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

private func parseTimestamp(_ value: Any?) -> Date? {
    guard let string = value as? String else { return nil }
    return ClaudeUsageParser.isoDate(string)
}

/// Discards durations and counts too small to mean anything.
private func speed(tokens: Int, from start: Date, to end: Date) -> Double? {
    let seconds = end.timeIntervalSince(start)
    guard tokens >= 10, seconds >= 0.25 else { return nil }
    let rate = Double(tokens) / seconds
    return rate < 5_000 ? rate : nil
}

/// Codex rollouts (~/.codex/sessions): the model starts after a user message or tool output,
/// and each reply ends with a token_usage_record carrying its output tokens. (token_count is
/// written after the tools run, so it is only used by older Codex versions without records.)
public struct CodexSpeedTracker {
    private var inputAt: Date?
    private var hasUsageRecords = false
    private var model = ""

    public init() {}

    public mutating func feed(_ line: [String: Any]) -> TokenSpeed? {
        guard let time = parseTimestamp(line["timestamp"]) else { return nil }
        let kind = line["type"] as? String
        if kind == "turn_context", let payload = line["payload"] as? [String: Any], let name = payload["model"] as? String {
            model = ModelName.display(name)
            return nil
        }
        if kind == "token_usage_record" {
            hasUsageRecords = true
            let record = line["payload"] as? [String: Any] ?? line
            guard let start = inputAt,
                  let usage = record["usage"] as? [String: Any],
                  let output = QuotaRow.number(usage["output_tokens"]) else { return nil }
            inputAt = nil
            return speed(tokens: Int(output), from: start, to: time).map { TokenSpeed(tokensPerSecond: $0, at: time, model: model) }
        }
        guard let payload = line["payload"] as? [String: Any] else { return nil }
        let payloadType = payload["type"] as? String
        switch (kind, payloadType) {
        case ("event_msg", "task_started"), ("event_msg", "user_message"),
             ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"),
             ("response_item", "local_shell_call_output"):
            inputAt = time
        case ("response_item", "message") where payload["role"] as? String == "user":
            inputAt = time
        case ("event_msg", "token_count"):
            guard !hasUsageRecords, let start = inputAt,
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let output = QuotaRow.number(last["output_tokens"]) else { return nil }
            inputAt = nil
            return speed(tokens: Int(output), from: start, to: time).map { TokenSpeed(tokensPerSecond: $0, at: time, model: model) }
        default:
            break
        }
        return nil
    }

    /// Only interactive Codex Desktop sessions count (not CLI runs or internal sub-agents).
    public static func isDesktopSession(_ meta: [String: Any]) -> Bool {
        guard let payload = meta["payload"] as? [String: Any] else { return false }
        return payload["originator"] as? String == "Codex Desktop" && !(payload["source"] is [String: Any])
    }
}

/// Claude Code transcripts (~/.claude/projects): an "api-request" line marks the request;
/// the reply's lines share a message id and carry its output tokens.
public struct ClaudeSpeedTracker {
    private var requestAt: Date?
    private var messageID: String?

    public init() {}

    public mutating func feed(_ line: [String: Any]) -> TokenSpeed? {
        guard let time = parseTimestamp(line["timestamp"]) else { return nil }
        switch line["type"] as? String {
        case "api-request":
            requestAt = time
            messageID = nil
        case "assistant":
            // Claude desktop app only; terminal Claude Code sessions are skipped.
            guard line["entrypoint"] as? String == "claude-desktop",
                  let start = requestAt,
                  let message = line["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let output = QuotaRow.number(usage["output_tokens"]) else { return nil }
            messageID = message["id"] as? String ?? messageID
            let model = ModelName.display(message["model"] as? String ?? line["requestedModel"] as? String ?? "")
            return speed(tokens: Int(output), from: start, to: time).map { TokenSpeed(tokensPerSecond: $0, at: time, model: model) }
        default:
            break
        }
        return nil
    }
}

/// Watches one app's session folder with FSEvents and reads only bytes appended since the
/// last change. Costs nothing while the app is idle.
public final class TokenSpeedMonitor {
    public enum App { case codex, claude }

    private struct FileState {
        var offset: UInt64
        var carry = Data()
        var codex = CodexSpeedTracker()
        var claude = ClaudeSpeedTracker()
        var eligible: Bool
    }

    private let app: App
    private let root: URL
    private var stream: FSEventStreamRef?
    private var files: [String: FileState] = [:]
    public private(set) var latest: TokenSpeed?
    /// Called after a reply finishes, so quota can be refreshed right when it changes.
    public var onReply: (() -> Void)?
    private var byModel: [String: TokenSpeed] = [:]

    /// Latest speed of each model used recently, newest first.
    public func recentModels(limit: Int = 3, within interval: TimeInterval = 86_400, now: Date = Date()) -> [TokenSpeed] {
        Array(byModel.values.filter { now.timeIntervalSince($0.at) < interval }.sorted { $0.at > $1.at }.prefix(limit))
    }

    public init(app: App) {
        self.app = app
        let home = FileManager.default.homeDirectoryForCurrentUser
        root = home.appendingPathComponent(app == .codex ? ".codex/sessions" : ".claude/projects")
    }

    deinit { stop() }

    public func start() {
        guard stream == nil, FileManager.default.fileExists(atPath: root.path) else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<TokenSpeedMonitor>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            for index in 0..<count {
                if let path = list[index] as? String { monitor.changed(path) }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
        // Show a speed right after launch: the newest logs that hold a measurable reply.
        for log in recentLogs().prefix(6) where latest == nil {
            changed(log.path)
        }
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        files.removeAll()
    }

    private func changed(_ path: String) {
        guard path.hasSuffix(".jsonl"), let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // A file seen for the first time is read from its last 512 KB only: long sessions
        // grow to tens of MB and only the latest replies matter.
        var state = files[path] ?? FileState(
            offset: size > 512_000 ? size - 512_000 : 0,
            eligible: app == .claude || isCodexDesktop(handle)
        )
        if size < state.offset { state = FileState(offset: 0, eligible: state.eligible) } // truncated/rewritten
        guard state.eligible, size > state.offset else {
            files[path] = state
            return
        }
        try? handle.seek(toOffset: state.offset)
        var data = state.carry
        data.append(handle.readDataToEndOfFile())
        state.offset = size
        // Keep an unfinished last line for the next change.
        if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            state.carry = Data(data[data.index(after: lastNewline)...])
            data = Data(data[..<data.index(after: lastNewline)])
        } else {
            state.carry = data
            data = Data()
        }
        var sawReply = false
        defer { if sawReply { onReply?() } }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            let result = app == .codex ? state.codex.feed(object) : state.claude.feed(object)
            guard let result else { continue }
            sawReply = true
            if result.at >= (latest?.at ?? .distantPast) { latest = result }
            if result.at >= (byModel[result.model]?.at ?? .distantPast) { byModel[result.model] = result }
        }
        files[path] = state
        if files.count > 32 { files = files.filter { $0.key == path } } // only recent sessions matter
    }

    private func isCodexDesktop(_ handle: FileHandle) -> Bool {
        try? handle.seek(toOffset: 0)
        let head = handle.readData(ofLength: 65_536)
        guard let end = head.firstIndex(of: UInt8(ascii: "\n")),
              let meta = (try? JSONSerialization.jsonObject(with: head[..<end])) as? [String: Any] else { return false }
        return CodexSpeedTracker.isDesktopSession(meta)
    }

    /// Logs written most recently first.
    private func recentLogs() -> [URL] {
        let fm = FileManager.default
        var candidates: [URL] = []
        if app == .codex {
            let calendar = Calendar.current
            for dayOffset in [0, -1] {
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: Date()) else { continue }
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
                candidates += (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            }
        } else {
            for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                candidates += (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            }
        }
        return candidates
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0, modified($0)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
