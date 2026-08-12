import Foundation

enum ProjectCacheScanner {
    /// 이름만으로 빌드 캐시라 단정할 수 있는 디렉터리. 다른 용도로 쓰이는 경우가 없다.
    static let unambiguousCacheDirNames: Set<String> = [
        "Pods", "DerivedData", ".gradle", "Carthage", ".dart_tool", ".next", ".expo",
    ]

    /// `build` · `dist` · `target` 같은 범용 이름은 커밋된 소스 디렉터리일 수 있다.
    /// 부모에 해당 빌드 시스템의 마커 파일이 있을 때만 캐시로 인정한다.
    /// 마커 없이 지우면 소스를 휴지통으로 보내는 사고가 난다.
    static let markerGatedCacheDirNames: [String: [String]] = [
        "node_modules": ["package.json"],
        "dist": ["package.json"],
        "target": ["Cargo.toml", "pom.xml", "build.gradle", "build.gradle.kts"],
        "build": ["package.json", "build.gradle", "build.gradle.kts", "CMakeLists.txt", "pom.xml"],
        ".build": ["Package.swift"],
    ]

    static var allCacheDirNames: Set<String> {
        unambiguousCacheDirNames.union(markerGatedCacheDirNames.keys)
    }

    /// 디렉터리가 진짜 빌드 캐시인지 판정. 마커 게이트 대상이 아니면 이름만으로 통과.
    static func isCacheDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if unambiguousCacheDirNames.contains(name) { return true }
        guard let markers = markerGatedCacheDirNames[name] else { return false }
        let parent = url.deletingLastPathComponent()
        return markers.contains {
            FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path)
        }
    }

    static func scan(roots: [URL], maxDepth: Int = 6) -> [CleanableItem] {
        var matches: [URL] = []
        for root in roots {
            // 루트만 링크를 푼다. 고른 폴더 자체가 심볼릭 링크면
            // `contentsOfDirectory(at:)`가 `ENOTDIR`로 실패해 목록이 통째로 빈다
            // — `DirectoryContents` 참고. 하위 항목은 링크를 그대로 둬야
            // 순환에 빠지지 않는다(`collect` 주석 참고).
            collect(in: root.resolvingSymlinksInPath(), currentDepth: 0, maxDepth: maxDepth, into: &matches)
        }

        let sizes = DiskScanner.sizes(of: matches)
        return matches
            .map { url in
                CleanableItem(
                    name: displayName(for: url, roots: roots),
                    path: url,
                    sizeBytes: sizes[url] ?? 0,
                    modifiedDate: FileAttributes.modificationDate(of: url)
                )
            }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// 루트의 부모를 기준으로 상대 경로를 만들어 "MyProject/node_modules" 형태로 보여준다.
    /// 양쪽 다 심볼릭 링크를 푼 뒤 비교한다. `contentsOfDirectory`는 실경로(/private/var/…)를
    /// 주는데 루트는 링크 경로(/var/…)일 수 있어 그대로 비교하면 접두사가 어긋난다.
    static func displayName(for url: URL, roots: [URL]) -> String {
        let resolved = url.resolvingSymlinksInPath().path
        for root in roots {
            let prefix = root.resolvingSymlinksInPath().deletingLastPathComponent().path + "/"
            if resolved.hasPrefix(prefix) {
                return String(resolved.dropFirst(prefix.count))
            }
        }
        return url.path
    }

    private static func collect(
        in url: URL, currentDepth: Int, maxDepth: Int, into matches: inout [URL]
    ) {
        guard currentDepth <= maxDepth else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for entry in entries {
            // contentsOfDirectory가 준 URL의 isDirectory는 심볼릭 링크에 false를 준다.
            // 덕분에 링크 순환을 따라가지 않는다 (실측 확인).
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }

            if allCacheDirNames.contains(entry.lastPathComponent) {
                if isCacheDirectory(entry) { matches.append(entry) }
                continue // 캐시 후보 안으로는 내려가지 않는다
            }
            collect(in: entry, currentDepth: currentDepth + 1, maxDepth: maxDepth, into: &matches)
        }
    }
}
