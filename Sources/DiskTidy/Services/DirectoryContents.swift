import Foundation

/// 스캔 루트의 하위 항목을 읽는다.
///
/// `FileManager.contentsOfDirectory(at:)`(URL 버전)는 **심볼릭 링크로 걸린 디렉터리에서
/// `ENOTDIR`로 실패한다**. 같은 경로를 문자열 버전에 주면 정상으로 읽힌다(실측).
/// `~/Library/Developer/Xcode/DerivedData`를 외장 디스크로 빼 두는 구성이 흔한데,
/// 그 환경에서 Xcode 캐시 화면이 통째로 비어 보였다.
///
/// 그래서 루트의 링크를 먼저 푼다. 덤으로 결과 경로가 실경로가 되어, 삭제할 때
/// 링크만 지우고 공간은 그대로인 사고도 막는다.
///
/// **재귀 하강에는 쓰지 않는다.** `ProjectCacheScanner`는 링크 자식의 `isDirectory`가
/// `false`로 오는 성질에 기대어 링크 순환을 피한다 — 거기서 링크를 풀면 순환에 빠진다.
enum DirectoryContents {
    static func ofRoot(_ url: URL, includingPropertiesForKeys keys: [URLResourceKey]? = nil) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url.resolvingSymlinksInPath(), includingPropertiesForKeys: keys
        )) ?? []
    }
}
