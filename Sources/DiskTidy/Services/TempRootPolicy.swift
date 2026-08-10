import Darwin
import Foundation

/// 경로를 문자열 그대로 비교하면 `/tmp`과 `/private/tmp`이 서로 다른 경로로 보이고,
/// 단순 `hasPrefix`만 쓰면 `/private/tmp2`가 `/private/tmp` 하위로 오인된다.
enum CanonicalPath {
    /// 존재하는 경로를 `realpath(3)`로 정규화한다. 심볼릭 링크·`..`·중복 슬래시가 사라진다.
    /// 경로가 없거나 접근할 수 없으면 nil.
    static func resolve(_ path: String) -> String? {
        guard !path.isEmpty, let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 존재를 보장할 수 없는 경로(lsof 출력, 이미 사라진 파일)의 표기만 맞춘다.
    /// 열린 경로 89,000개에 `realpath`를 부르면 스캔이 수십 초 느려지므로,
    /// macOS에서 실제로 갈라지는 `/tmp`·`/var` 두 접두사만 문자열로 교정한다.
    static func normalizingPrefix(_ path: String) -> String {
        for prefix in ["/tmp", "/var"] {
            if path == prefix { return "/private" + prefix }
            if path.hasPrefix(prefix + "/") { return "/private" + path }
        }
        return path
    }

    /// `path`가 `parent`의 **하위**인지 component 경계로 판정한다. 같은 경로는 하위가 아니다.
    ///
    /// `String.hasPrefix`를 쓰면 안 된다. grapheme cluster 단위라 결합문자로 시작하는
    /// 파일명(`/private/tmp/` + U+0301)에서 구분자 `/`가 다음 글자와 한 덩어리로 묶여
    /// 진짜 하위 경로가 "하위 아님"으로 판정된다(실측). 경로는 파일시스템에서 온 바이트열이므로
    /// UTF-8 바이트로 비교한다.
    static func contains(_ parent: String, _ path: String) -> Bool {
        let base = parent.hasSuffix("/") ? String(parent.dropLast()) : parent
        return path.utf8.starts(with: (base + "/").utf8)
    }
}

/// 스캔과 삭제가 서로 다른 루트 판정을 하면 안전 규칙이 통째로 무너진다.
/// 두 서비스는 같은 `production` 정책만 쓰고, UI·삭제 호출부는 루트를 주입할 수 없다.
struct TempRootPolicy {
    /// canonical path. 중복이 제거된 순서 보존 목록.
    let roots: [String]

    static let production = TempRootPolicy(
        candidateRoots: ["/private/tmp", NSTemporaryDirectory()]
    )

    private init(candidateRoots: [String]) {
        var accepted: [String] = []
        for raw in candidateRoots {
            guard let canonical = Self.validated(raw), !accepted.contains(canonical) else { continue }
            accepted.append(canonical)
        }
        roots = accepted
    }

    /// `/`·홈·상대 경로·빈 경로·존재하지 않는 경로는 루트가 될 수 없다.
    /// 여기서 막지 못하면 루트를 추가하는 다음 사람이 홈 디렉터리 전체를
    /// 완전 삭제 대상으로 만들 수 있다. 지금 후보 목록으로는 도달하지 않는
    /// 방어이므로, 테스트가 직접 부를 수 있게 열어 둔다.
    static func validated(_ raw: String) -> String? {
        guard raw.hasPrefix("/"), let canonical = CanonicalPath.resolve(raw) else { return nil }
        guard canonical != "/" else { return nil }
        guard canonical != CanonicalPath.resolve(NSHomeDirectory()) else { return nil }

        var status = stat()
        guard lstat(canonical, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else { return nil }
        return canonical
    }

    var rootSet: Set<String> { Set(roots) }

    func isRoot(_ canonicalPath: String) -> Bool { roots.contains(canonicalPath) }

    /// `canonicalPath`를 품은 루트. 없으면 nil.
    /// 경계 판정 진입점은 이것 하나뿐이다. 다른 진입점을 두면 다음 사람이
    /// 안전 규칙을 고칠 때 실제로 쓰이지 않는 쪽을 강화하게 된다.
    func root(containing canonicalPath: String) -> String? {
        roots.first { CanonicalPath.contains($0, canonicalPath) }
    }
}
