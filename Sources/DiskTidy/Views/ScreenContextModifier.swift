import SwiftUI

extension View {
    /// 이 탭이 보일 때 자기 화면의 스냅샷 생산자를 챗봇에 등록한다.
    ///
    /// 값이 아니라 클로저를 넘긴다. 값으로 굳히면 스캔이 끝나 목록이 채워진 뒤에도
    /// 챗봇은 등록 시점의 빈 화면을 설명한다.
    func screenContext(
        _ title: String,
        snapshot: @escaping @MainActor () -> ScreenContext
    ) -> some View {
        modifier(ScreenContextModifier(title: title, snapshot: snapshot))
    }
}

struct ScreenContextModifier: ViewModifier {
    @EnvironmentObject private var store: ChatContextStore

    let title: String
    let snapshot: @MainActor () -> ScreenContext

    func body(content: Content) -> some View {
        content.onAppear { store.register(title: title, snapshot: snapshot) }
    }
}
