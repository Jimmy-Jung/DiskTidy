import Foundation

enum CacheScanner {
    static var defaultCachesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
    }

    static func scan(cachesURL: URL = defaultCachesURL) -> [CleanableItem] {
        let entries = DirectoryContents.ofRoot(cachesURL)
        let sizes = DiskScanner.sizes(of: entries)
        return entries
            .map { CleanableItem(name: $0.lastPathComponent, path: $0, sizeBytes: sizes[$0] ?? 0) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }
}
