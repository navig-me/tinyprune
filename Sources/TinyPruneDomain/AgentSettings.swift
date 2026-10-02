import Foundation

/// Global behavior settings enforced inside the engine so every client (app, CLI, Finder) gets identical results.
///
/// Defaults preserve pre-settings behavior: no extra grace, hidden files are NOT protected, and the
/// activity log is kept forever.
public struct AgentSettings: Codable, Equatable, Sendable {
    /// Grace applied to rules that define no grace period of their own. `0` means none.
    public var defaultGracePeriodSeconds: Double
    /// When true, items whose name or any path component below the rule scope starts with `.` are never
    /// scheduled unless the matched rule explicitly targets a dot-name.
    public var protectHiddenFiles: Bool
    /// Audit events older than this many days are pruned during maintenance. `0` keeps them forever.
    public var activityRetentionDays: Int

    public static let `default` = AgentSettings()

    public init(defaultGracePeriodSeconds: Double = 0, protectHiddenFiles: Bool = false, activityRetentionDays: Int = 0) {
        self.defaultGracePeriodSeconds = Self.sanitizedGrace(defaultGracePeriodSeconds)
        self.protectHiddenFiles = protectHiddenFiles
        self.activityRetentionDays = max(0, activityRetentionDays)
    }

    private enum CodingKeys: String, CodingKey {
        case defaultGracePeriodSeconds, protectHiddenFiles, activityRetentionDays
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            defaultGracePeriodSeconds: try container.decodeIfPresent(Double.self, forKey: .defaultGracePeriodSeconds) ?? 0,
            protectHiddenFiles: try container.decodeIfPresent(Bool.self, forKey: .protectHiddenFiles) ?? false,
            activityRetentionDays: try container.decodeIfPresent(Int.self, forKey: .activityRetentionDays) ?? 0
        )
    }

    private static func sanitizedGrace(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}
