import Foundation

final class AppNavigationState: ObservableObject {
    /// 챗봇 패널의 "설정 열기"가 보낼 대상. 사이드바 항목 id와 같은 값이어야 한다.
    static let settingsTab = 10

    /// 사이드바가 직접 바인딩하는 값이 아니다. `ContentView`가 자기 `@State`와 양방향으로
    /// 맞추고, 바깥(챗봇 패널)은 이 값을 바꿔 탭 이동을 요청한다 — 이유는 그쪽 주석.
    @Published var selectedTab: Int? = 0
}
