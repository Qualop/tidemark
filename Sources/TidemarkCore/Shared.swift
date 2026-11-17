import Foundation
import Darwin

public enum OverlayPaths {
    public static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tidemark", isDirectory: true)
    public static let config = supportDirectory.appendingPathComponent("config.json")
    public static let status = supportDirectory.appendingPathComponent("status.json")
    public static let model = supportDirectory.appendingPathComponent("model.json")
    public static let overlayLock = supportDirectory.appendingPathComponent("tidemark.lock")
    public static let targetBundleIdentifier = "com.openai.codex"
}

/// Optional overrides in ~/Library/Application Support/Tidemark/config.json.
/// Missing keys keep their defaults.
public struct OverlayConfig: Codable, Sendable {
    public var width: Double = 221
    public var height: Double = 30
    public var visualScale: Double = 0.95
    public var horizontalOffset: Double = 0
    public var bottomOffset: Double = 32
    public var trackingIntervalMs: Int = 8
    public var resizeSettleMs: Int = 120
    public var composerMissingGraceMs: Int = 500
    public var usageRefreshIntervalMs: Int = 60_000
    public var usageMaxAttempts: Int = 3
    public var usageRetryDelayMs: Int = 5_000

    enum CodingKeys: String, CodingKey {
        case width = "Width"
        case height = "Height"
        case visualScale = "VisualScale"
        case horizontalOffset = "HorizontalOffset"
        case bottomOffset = "BottomOffset"
        case trackingIntervalMs = "TrackingIntervalMs"
        case resizeSettleMs = "ResizeSettleMs"
        case composerMissingGraceMs = "ComposerMissingGraceMs"
        case usageRefreshIntervalMs = "UsageRefreshIntervalMs"
        case usageMaxAttempts = "UsageMaxAttempts"
        case usageRetryDelayMs = "UsageRetryDelayMs"
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        width = try values.decodeIfPresent(Double.self, forKey: .width) ?? width
        height = try values.decodeIfPresent(Double.self, forKey: .height) ?? height
        visualScale = try values.decodeIfPresent(Double.self, forKey: .visualScale) ?? visualScale
        horizontalOffset = try values.decodeIfPresent(Double.self, forKey: .horizontalOffset) ?? horizontalOffset
        bottomOffset = try values.decodeIfPresent(Double.self, forKey: .bottomOffset) ?? bottomOffset
        trackingIntervalMs = try values.decodeIfPresent(Int.self, forKey: .trackingIntervalMs) ?? trackingIntervalMs
        resizeSettleMs = try values.decodeIfPresent(Int.self, forKey: .resizeSettleMs) ?? resizeSettleMs
        composerMissingGraceMs = try values.decodeIfPresent(Int.self, forKey: .composerMissingGraceMs) ?? composerMissingGraceMs
        usageRefreshIntervalMs = try values.decodeIfPresent(Int.self, forKey: .usageRefreshIntervalMs) ?? usageRefreshIntervalMs
        usageMaxAttempts = try values.decodeIfPresent(Int.self, forKey: .usageMaxAttempts) ?? usageMaxAttempts
        usageRetryDelayMs = try values.decodeIfPresent(Int.self, forKey: .usageRetryDelayMs) ?? usageRetryDelayMs
    }

    public static func load() -> OverlayConfig {
        guard let data = try? Data(contentsOf: OverlayPaths.config),
              let decoded = try? JSONDecoder().decode(OverlayConfig.self, from: data)
        else { return OverlayConfig() }
        return decoded.validated()
    }

    public func validated() -> OverlayConfig {
        var result = self
        result.width = min(max(width, 80), 800)
        result.height = min(max(height, 12), 200)
        result.visualScale = min(max(visualScale, 0.5), 2)
        result.trackingIntervalMs = min(max(trackingIntervalMs, 8), 1_000)
        result.resizeSettleMs = min(max(resizeSettleMs, 50), 2_000)
        result.composerMissingGraceMs = min(max(composerMissingGraceMs, 100), 5_000)
        result.usageRefreshIntervalMs = min(max(usageRefreshIntervalMs, 10_000), 3_600_000)
        result.usageMaxAttempts = min(max(usageMaxAttempts, 1), 5)
        result.usageRetryDelayMs = min(max(usageRetryDelayMs, 1_000), 60_000)
        return result
    }
}

public final class ProcessLock {
    private var descriptor: Int32 = -1

    public init?(url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            return nil
        }
        ftruncate(descriptor, 0)
        let pidText = "\(getpid())\n"
        _ = pidText.withCString { write(descriptor, $0, strlen($0)) }
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}

public enum SanitizedStatus {
    /// Records which model label the overlay read and which quota source it chose.
    public static func writeModel(label: String, source: QuotaSource) {
        let object: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "modelLabel": label,
            "quotaSource": source.identifier,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: OverlayPaths.model, options: .atomic)
    }

    public static func write(
        success: Bool,
        attempts: Int,
        httpStatus: Int?,
        errorKind: String?
    ) {
        let formatter = ISO8601DateFormatter()
        let object: [String: Any] = [
            "updatedAt": formatter.string(from: Date()),
            "success": success,
            "attempts": attempts,
            "httpStatus": httpStatus as Any,
            "errorKind": errorKind as Any,
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? FileManager.default.createDirectory(
            at: OverlayPaths.supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: OverlayPaths.status, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: OverlayPaths.status.path)
    }
}
