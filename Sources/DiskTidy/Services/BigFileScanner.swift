import Foundation

enum BigFileScanner {
    static func scan(
        roots: [URL], minBytes: Int64 = 200 * 1024 * 1024, maxDepth: Int = 6
    ) -> [CleanableItem] {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        var results: [CleanableItem] = []

        for root in roots {
            let minKB = String(minBytes / 1024)
            // -print0로 받아 파일명에 개행이 있어도 안전하게 분리한다.
            let result = ShellRunner.run("/usr/bin/find", [
                root.path, "-maxdepth", String(maxDepth), "-type", "f", "-size", "+\(minKB)k", "-print0",
            ])
            for path in result.output.split(separator: "\0").map(String.init) {
                guard let size = FileAttributes.size(of: path) else { continue }
                results.append(CleanableItem(
                    name: displayName(for: path, homePath: homePath),
                    path: URL(fileURLWithPath: path),
                    sizeBytes: size,
                    modifiedDate: FileAttributes.modificationDate(of: URL(fileURLWithPath: path))
                ))
            }
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    static func displayName(for path: String, homePath: String) -> String {
        path.hasPrefix(homePath) ? "~" + path.dropFirst(homePath.count) : path
    }
}
