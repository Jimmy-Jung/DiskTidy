import Foundation

final class AppNavigationState: ObservableObject {
    /// 챗봇 패널의 "설정 열기"가 보낼 대상. 사이드바 항목 id와 같은 값이어야 한다.
    static let settingsTab = 10

    @Published var selectedTab: Int? = 0
}
