import Foundation

/// 현재 탭이 등록한 화면 스냅샷 생산자를 들고 있다가, 챗봇이 메시지를 보낼 때 호출한다.
///
/// 탭을 옮기면 새 탭의 `onAppear`가 이전 등록을 덮어쓴다. 해제는 하지 않는다 —
/// SwiftUI는 새 탭의 `onAppear`를 이전 탭의 `onDisappear`보다 먼저 부를 수 있어서
/// 해제를 넣으면 방금 등록한 것이 지워진다.
@MainActor
final class ChatContextStore: ObservableObject {
    @Published private(set) var title: String = "DiskTidy"

    private var snapshot: (@MainActor () -> ScreenContext)?

    func register(title: String, snapshot: @escaping @MainActor () -> ScreenContext) {
        self.title = title
        self.snapshot = snapshot
    }

    /// 보내는 시점에 만든다. 등록 시점 값으로 굳히면 옛 화면을 설명하게 된다.
    func current() -> ScreenContext {
        snapshot?() ?? ScreenContext(title: title, lines: ["표시할 화면 정보가 없습니다."])
    }
}
