import Foundation

enum AndroidEmulatorScanner {
    static var avdRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/avd")
    }

    /// AVD 디렉터리와 짝을 이루는 `<name>.ini` 포인터 파일. 디렉터리만 지우면
    /// Android Studio가 유령 항목을 계속 보여주므로 함께 정리한다.
    static func iniURL(forAVDNamed name: String) -> URL {
        avdRoot.appendingPathComponent("\(name).ini")
    }

    static func scan() -> [CleanableItem] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: avdRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        let avdDirs = entries.filter { entry in
            entry.pathExtension == "avd"
                && (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        let sizes = DiskScanner.sizes(of: avdDirs)
        return avdDirs
            .map { url in
                CleanableItem(
                    name: url.deletingPathExtension().lastPathComponent,
                    path: url,
                    sizeBytes: sizes[url] ?? 0,
                    modifiedDate: FileAttributes.modificationDate(of: url)
                )
            }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }
}
