import SwiftUI

// SwiftUI 뷰 업데이트 사이클과 얽혀 화면이 안 그려지거나 죽는 두 함정의 우회.
//
// 둘 다 크래시 로그가 남지 않고 간헐적으로만 재현돼 원인 추적이 오래 걸렸다.
// 새 탭 뷰를 만들 때 이 두 헬퍼를 그대로 쓴다.

extension View {
    /// `onAppear`에서 `@Published`를 바꿔야 할 때 쓴다.
    ///
    /// macOS `NavigationSplitView`는 사이드바 클릭으로 detail을 바꿀 때 새 뷰의 `onAppear`를
    /// **같은 뷰 업데이트 안에서** 부른다. 거기서 ViewModel의 `@Published`를 바꾸면(스캔 시작,
    /// 화면 컨텍스트 등록) SwiftUI가 "Publishing changes from within view updates is not allowed,
    /// this will cause undefined behavior"를 낸다 — 실측으로 탭 전환마다 3건. 그 "undefined
    /// behavior"의 실제 모습이 detail이 검게 남는 화면과 간헐적 AttributeGraph 크래시다.
    /// 메인 액터의 다음 턴으로 미루면 업데이트 밖에서 실행된다. 한 턴 늦는 것은 눈에 띄지 않는다.
    func onAppearDeferred(perform action: @escaping @MainActor () -> Void) -> some View {
        onAppear { Task { @MainActor in action() } }
    }
}

extension Binding {
    /// 배열 원소의 필드를 **id로 찾아** 묶는다. `ForEach($items)`가 만드는 인덱스 바인딩의 대체.
    ///
    /// 인덱스 바인딩은 배열이 줄어든 뒤에도 아직 화면에 남은 옛 행이 사라진 인덱스를 읽어
    /// `Fatal error: Index out of range`로 죽는다 — macOS `List`는 행을 비동기로 회수해서
    /// 배열 교체와 행 제거 사이에 틈이 있다. 이 앱은 탭에 다시 들어갈 때마다 백그라운드 스캔이
    /// 목록을 통째로 갈아 끼우고 삭제는 `removeAll`이라 그 틈이 늘 생긴다.
    /// id로 찾으면 없는 원소는 읽을 때 `fallback`을 주고 쓸 때는 무시한다.
    ///
    /// ponytail: 매 접근이 선형 탐색이다. 목록은 수백 개 수준이라 문제없고,
    /// 수만 개가 되면 id→index 사전을 두는 쪽으로 바꾼다.
    func field<Element: Identifiable, Field>(
        _ keyPath: WritableKeyPath<Element, Field>,
        id: Element.ID,
        default fallback: Field
    ) -> Binding<Field> where Value == [Element] {
        Binding<Field>(
            get: { wrappedValue.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                guard let index = wrappedValue.firstIndex(where: { $0.id == id }) else { return }
                wrappedValue[index][keyPath: keyPath] = newValue
            }
        )
    }
}
