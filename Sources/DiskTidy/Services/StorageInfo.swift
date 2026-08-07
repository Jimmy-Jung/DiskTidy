import Foundation

enum StorageInfo {
    static func current() -> StorageSnapshot? {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? homeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else { return nil }
        guard let total = values.volumeTotalCapacity else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        return StorageSnapshot(totalBytes: Int64(total), availableBytes: available)
    }
}
