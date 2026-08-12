import Foundation

/// 앱 설정을 담는 `UserDefaults` 도메인을 한 곳으로 고정한다.
///
/// `UserDefaults.standard`의 도메인은 실행 방식에 따라 달라진다. 번들로 실행하면 번들
/// ID(`com.jimmy.disktidy`), 번들 없이 실행하면(`swift run`, Xcode의 SPM 실행) 프로세스
/// 이름(`DiskTidy`)이다. 실측: 개발 실행에서 추가한 스캔 폴더가 설치된 앱에서는 통째로
/// 보이지 않았다 — 같은 앱인데 설정 파일이 둘로 갈라져 각자 다른 값을 들고 있었다.
///
/// 이름으로 도메인을 고정하면 어느 쪽으로 실행해도 같은 저장소를 읽고 쓴다.
enum AppDefaults {
    static let suiteName = "com.jimmy.disktidy"

    static let shared: UserDefaults = {
        // 자기 번들 ID를 스위트 이름으로 주면 AppKit이 "말이 안 되고 동작하지 않는다"고
        // 콘솔에 경고한다(실측). 그 경우 `.standard`가 이미 그 도메인이므로 그대로 쓴다.
        guard Bundle.main.bundleIdentifier != suiteName else { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }()
}
