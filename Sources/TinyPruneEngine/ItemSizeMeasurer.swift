import Foundation

public struct ItemSizeMeasurement: Equatable, Sendable {
    /// Allocated bytes on disk (resource values only; file contents are never read).
    public let bytes: Int64
    /// Number of entries counted, including the item itself.
    public let items: Int
    /// True when the walk stopped at `maxEntries` or was cancelled, so `bytes` is a lower bound.
    public let truncated: Bool

    public init(bytes: Int64, items: Int, truncated: Bool) {
        self.bytes = bytes
        self.items = items
        self.truncated = truncated
    }
}

public enum ItemSizeMeasurer {
    public static let defaultMaxEntries = 200_000

    /// Synchronous, bounded metadata walk. Call from a detached task, never from an actor that schedules work.
    /// Symlinks are counted but never followed.
    public static func measure(
        path: String,
        maxEntries: Int = defaultMaxEntries,
        shouldStop: @Sendable () -> Bool = { false }
    ) -> ItemSizeMeasurement? {
        if maxEntries <= 0 || Task.isCancelled || shouldStop() {
            return ItemSizeMeasurement(bytes: 0, items: 0, truncated: true)
        }
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let keySet = Set(keys)
        guard let rootValues = try? url.resourceValues(forKeys: keySet) else { return nil }
        var bytes = allocatedSize(rootValues)
        var items = 1
        let isDirectory = rootValues.isDirectory == true && rootValues.isSymbolicLink != true
        guard isDirectory else { return ItemSizeMeasurement(bytes: bytes, items: items, truncated: false) }

        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in enumerationFailed = true; return false }
        ) else { return nil }

        while let child = enumerator.nextObject() as? URL {
            if Task.isCancelled || shouldStop() || items >= maxEntries {
                return ItemSizeMeasurement(bytes: bytes, items: items, truncated: true)
            }
            items += 1
            guard let values = try? child.resourceValues(forKeys: keySet) else { return nil }
            bytes += allocatedSize(values)
        }
        guard !enumerationFailed else { return nil }
        return ItemSizeMeasurement(bytes: bytes, items: items, truncated: false)
    }

    private static func allocatedSize(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}
