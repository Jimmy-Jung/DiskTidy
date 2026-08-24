import SwiftUI

struct PackageCacheTabView: View {
    // 창 수명 동안 유지되는 인스턴스를 주입받는다 — `TabViewModels` 참고.
    @ObservedObject var viewModel: CleanableListViewModel

    var body: some View {
        CleanableListView(
            title: "패키지 캐시 (npm · CocoaPods · SwiftPM …)",
            viewModel: viewModel
        )
        // 재진입 시 이전 결과를 그대로 보여 주면서 뒤에서 다시 스캔한다.
        .onAppear { viewModel.refresh() }
        .screenContext("패키지 캐시") { [viewModel] in
            ScreenContextBuilder.cleanableList(
                title: "패키지 캐시 (npm · CocoaPods · SwiftPM …)",
                viewModel: viewModel,
                note: "패키지 매니저의 전역 캐시 — 지우면 다음 설치에서 다시 내려받습니다."
            )
        }
    }
}
