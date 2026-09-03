import Foundation

enum CacheScanner {
    static var defaultCachesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
    }

    static func scan(cachesURL: URL = defaultCachesURL) -> [CleanableItem] {
        let entries = DirectoryContents.ofRoot(cachesURL)
        let sizes = DiskScanner.sizes(of: entries)
        return entries
            // 수정일은 "안 쓰는 캐시"를 가리는 근거다. 다른 스캐너와 같이 채워서 목록의 수정일 열이
            // 이 탭에서만 비지 않게 한다.
            .map {
                CleanableItem(
                    name: $0.lastPathComponent,
                    path: $0,
                    sizeBytes: sizes[$0] ?? 0,
                    modifiedDate: FileAttributes.modificationDate(of: $0)
                )
            }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }
}
