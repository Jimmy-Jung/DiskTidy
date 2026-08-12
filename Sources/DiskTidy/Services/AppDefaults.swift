import Foundation

/// 앱 설정을 담는 `UserDefaults` 도메인을 한 곳으로 고정한다.
///
/// `UserDefaults.standard`의 도메인은 실행 방식에 따라 달라진다. 번들로 실행하면 번들
/// ID(`com.jimmy.disktidy`), 번들 없이 실행하면(`swift run`, Xcode의 SPM 실행) 프로세스
/// 이름(`DiskTidy`)이다. 실측: 개발 실행에서 추가한 스캔 폴더가 설치된 앱에서는 통째로
/// 보이지 않았다 — 같은 앱인데 설정 파일이 둘로 갈라져 각자 다른 값을 들고 있었다.
///
/// 이름으로 도메인을 고정하면 어느 쪽으로 실행해도 같은 저장소를 읽고 쓴다.
/// `suiteName`이 자기 번들 ID와 같을 때 `UserDefaults(suiteName:)`은 nil을 줄 수 있는데,
/// 그 경우 `.standard`가 이미 그 도메인이므로 폴백이 정확히 같은 저장소를 가리킨다.
enum AppDefaults {
    static let suiteName = "com.jimmy.disktidy"

    static let shared = UserDefaults(suiteName: suiteName) ?? .standard
}
