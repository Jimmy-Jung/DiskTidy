import Foundation

enum RootFolderStore {
    /// 실제 저장소. 테스트가 프로덕션 도메인(`com.jimmy.disktidy`)에 쓰면 실행 중인 앱의
    /// 설정을 건드리고, 그 앱이 들고 있던 캐시를 되쓰면서 읽기가 어긋난다. 그래서 갈아
    /// 끼울 수 있게 둔다.
    static var defaults: UserDefaults = AppDefaults.shared

    /// 스캔 루트로 허용하지 않는 경로. 전체 디스크 재귀는 `du` 프로세스를 폭발시키고
    /// 앱이 사실상 멈춘다. 취소 기능이 없으니 애초에 막는다.
    private static let forbiddenPaths: Set<String> = [
        "/", "/System", "/Library", "/Users", "/Volumes", "/private", "/Applications",
        FileManager.default.homeDirectoryForCurrentUser.path,
    ]

    enum RejectionReason {
        case tooBroad
        case alreadyAdded

        var message: String {
            switch self {
            case .tooBroad:
                return "이 폴더는 범위가 너무 넓어 스캔할 수 없습니다. 프로젝트가 모여 있는 하위 폴더를 선택하세요."
            case .alreadyAdded:
                return "이미 추가된 폴더입니다."
            }
        }
    }

    static func rejectionReason(for url: URL, existing: [URL]) -> RejectionReason? {
        let standardized = url.standardizedFileURL
        if forbiddenPaths.contains(standardized.path) { return .tooBroad }
        if existing.map(\.standardizedFileURL).contains(standardized) { return .alreadyAdded }
        return nil
    }

    /// 사라진 폴더는 걸러서 돌려준다. 남겨두면 스캔이 조용히 0건을 내놓는다.
    static func load(key: String) -> [URL] {
        let paths = defaults.stringArray(forKey: key) ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.count != urls.count { save(existing, key: key) }
        return existing
    }

    static func save(_ urls: [URL], key: String) {
        defaults.set(urls.map(\.path), forKey: key)
    }
}
