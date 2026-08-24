import Foundation

/// 홈 디렉토리에 쌓이는 패키지 매니저 전역 캐시.
///
/// `ProjectCacheScanner`는 프로젝트 안(node_modules·Pods)만, `AndroidCacheScanner`는
/// Gradle·Android만 본다. 정작 수 GB씩 크는 것은 `~/.npm`·`~/.cocoapods` 같은
/// 홈의 숨김 폴더인데 어느 탭도 안 보여서 여기로 모은다. Gradle은 Android 탭 담당이라 뺀다.
///
/// 전부 "지우면 다음 설치에서 다시 내려받는" 부류만 넣는다. 재생성 불가능한 것
/// (예: 설정 파일이 섞인 `~/.cargo` 루트)은 캐시 하위 경로만 집는다.
enum GlobalCacheScanner {
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CleanableItem] {
        let labeled: [(name: String, url: URL)] = [
            ("npm 캐시", home.appendingPathComponent(".npm/_cacache")),
            ("pnpm 스토어", home.appendingPathComponent("Library/pnpm/store")),
            ("Bun 설치 캐시", home.appendingPathComponent(".bun/install/cache")),
            ("Yarn 캐시", home.appendingPathComponent("Library/Caches/Yarn")),
            ("CocoaPods 스펙 저장소", home.appendingPathComponent(".cocoapods/repos")),
            ("CocoaPods 캐시", home.appendingPathComponent("Library/Caches/CocoaPods")),
            ("SwiftPM 캐시", home.appendingPathComponent("Library/Caches/org.swift.swiftpm")),
            ("Carthage 캐시", home.appendingPathComponent("Library/Caches/org.carthage.CarthageKit")),
            ("pip 캐시", home.appendingPathComponent("Library/Caches/pip")),
            ("uv 캐시", home.appendingPathComponent("Library/Caches/uv")),
            ("Cargo 레지스트리", home.appendingPathComponent(".cargo/registry")),
            ("Homebrew 다운로드 캐시", home.appendingPathComponent("Library/Caches/Homebrew")),
        ]

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
