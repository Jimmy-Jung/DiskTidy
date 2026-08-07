import Foundation

enum XcodeCacheScanner {
    static var defaultDevURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode")
    }

    static func scan(devURL: URL = defaultDevURL) -> [CleanableItem] {
        var labeled: [(name: String, url: URL)] = []
        labeled += subdirectories(of: devURL.appendingPathComponent("DerivedData"), prefix: "DerivedData")

        for deviceSupport in ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport"] {
            labeled += subdirectories(of: devURL.appendingPathComponent(deviceSupport), prefix: deviceSupport)
        }

        labeled += archives(of: devURL.appendingPathComponent("Archives"))

        let sizes = DiskScanner.sizes(of: labeled.map(\.url))
        return labeled
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

    private static func subdirectories(of url: URL, prefix: String) -> [(name: String, url: URL)] {
        directoryEntries(of: url).map { ("\(prefix)/\($0.lastPathComponent)", $0) }
    }

    private static func archives(of archivesURL: URL) -> [(name: String, url: URL)] {
        directoryEntries(of: archivesURL).flatMap { dateFolder in
            directoryEntries(of: dateFolder).map { archive in
                ("Archives/\(dateFolder.lastPathComponent)/\(archive.lastPathComponent)", archive)
            }
        }
    }

    private static func directoryEntries(of url: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}
