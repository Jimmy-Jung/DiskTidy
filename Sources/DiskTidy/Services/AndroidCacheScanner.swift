import Foundation

enum AndroidCacheScanner {
    static func scan() -> [CleanableItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser

        var labeled: [(name: String, url: URL)] = [
            ("Gradle 캐시", home.appendingPathComponent(".gradle/caches")),
            ("Gradle 배포판", home.appendingPathComponent(".gradle/wrapper/dists")),
            ("Android 캐시", home.appendingPathComponent(".android/cache")),
            ("Android 빌드캐시", home.appendingPathComponent(".android/build-cache")),
        ]

        let studioRoot = home.appendingPathComponent("Library/Application Support/Google")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: studioRoot, includingPropertiesForKeys: nil
        ) {
            for entry in entries where entry.lastPathComponent.hasPrefix("AndroidStudio") {
                labeled.append(("\(entry.lastPathComponent)/caches", entry.appendingPathComponent("caches")))
            }
        }

        let existing = labeled.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        let sizes = DiskScanner.sizes(of: existing.map(\.url))

        return existing
            .map { entry in
                CleanableItem(
                    name: entry.name,
                    path: entry.url,
                    sizeBytes: sizes[entry.url] ?? 0,
                    modifiedDate: FileAttributes.modificationDate(of: entry.url)
                )
            }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }
}
