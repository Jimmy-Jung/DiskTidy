import Foundation

enum CacheScanner {
    static func scan() -> [CleanableItem] {
        let cachesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cachesURL, includingPropertiesForKeys: nil
        ) else { return [] }

        let sizes = DiskScanner.sizes(of: entries)
        return entries
            .map { CleanableItem(name: $0.lastPathComponent, path: $0, sizeBytes: sizes[$0] ?? 0) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }
}
