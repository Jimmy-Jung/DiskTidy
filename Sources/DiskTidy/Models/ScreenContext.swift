import Foundation

/// 챗봇에게 넘기는 "지금 보고 있는 화면"의 스냅샷.
///
/// 값이 아니라 스냅샷을 만드는 클로저를 등록받는 이유는 시점 때문이다. 탭이 나타날 때
/// 값을 굳히면 스캔이 끝난 뒤 질문해도 빈 목록을 설명한다. `ChatContextStore` 참고.
struct ScreenContext: Equatable, Sendable {
    /// 프롬프트에 넣을 목록 항목 수 상한. 캐시 탭은 수백 개가 나오고 전부 넣으면
    /// 토큰 한도를 넘겨 요청 자체가 실패한다.
    static let maximumListedItems = 40

    let title: String
    let lines: [String]

    init(title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }

    var promptText: String {
        (["## 현재 화면: \(title)"] + lines).joined(separator: "\n")
    }
}
