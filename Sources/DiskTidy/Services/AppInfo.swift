import Foundation

/// 앱 자신에 대한 메타데이터.
enum AppInfo {
    /// 배포 버전. Info.plist의 `CFBundleShortVersionString`과 항상 같아야 한다 —
    /// 어긋나면 `AppInfoTests`가 실패한다. 코드에도 들고 있는 이유는 `swift run`이
    /// 번들 없이 맨 바이너리로 실행돼 Info.plist를 읽을 수 없기 때문이다.
    static let version = "1.5.6"

    /// 실행 중인 빌드의 버전. 번들이 있으면 Info.plist가 진실이고(설치본),
    /// 맨 바이너리(`swift run`)면 컴파일된 상수로 대신한다.
    static var displayVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? version
    }
}
