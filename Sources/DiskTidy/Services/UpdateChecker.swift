import Foundation

enum UpdateError: LocalizedError, Equatable {
    case network(String)
    case noUsableRelease
    case checksumMismatch
    case mountFailed
    case bundleMismatch
    case notReplaceable(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .network(let reason):
            return "업데이트 정보를 가져오지 못했습니다: \(reason)"
        case .noUsableRelease:
            return "설치할 수 있는 릴리스를 찾지 못했습니다 (DMG 또는 체크섬 파일 없음)."
        case .checksumMismatch:
            return "내려받은 파일의 체크섬이 릴리스 값과 다릅니다. 설치를 중단했습니다."
        case .mountFailed:
            return "내려받은 디스크 이미지를 열지 못했습니다."
        case .bundleMismatch:
            return "디스크 이미지 안에 DiskTidy 앱이 없거나 다른 앱입니다. 설치를 중단했습니다."
        case .notReplaceable(let path):
            return "\(path)에 쓸 권한이 없어 교체할 수 없습니다. 직접 내려받아 설치하세요."
        case .installFailed(let reason):
            return "설치에 실패해 이전 버전을 그대로 두었습니다: \(reason)"
        }
    }
}

/// 최신 릴리스를 조회한다. 토큰 없이 부르므로 IP당 시간당 60회 제한을 받는다 —
/// 실행할 때 한 번, 실패 후 사용자가 다시 누를 때만 부르니 넉넉하다.
enum UpdateChecker {
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/Jimmy-Jung/DiskTidy/releases/latest"
    )!

    /// 설치된 버전. 번들 없이 실행하면(`swift run`, Xcode의 SPM 실행) nil이다 —
    /// 그때는 교체할 `.app`이 없으므로 업데이트 자체를 시도하지 않는다.
    static var installedVersion: SemanticVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap(SemanticVersion.init)
    }

    static func fetchLatest(session: URLSession = .shared) async throws -> AppRelease {
        var request = URLRequest(url: latestReleaseURL)
        // API 버전을 명시하지 않으면 GitHub가 기본 표현을 바꿀 때 조용히 파싱이 깨진다.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw UpdateError.network("HTTP \(http.statusCode)")
        }
        guard let release = AppRelease.parse(latestReleaseJSON: data) else {
            throw UpdateError.noUsableRelease
        }
        return release
    }
}
