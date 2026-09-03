import SwiftUI

struct AndroidCacheTabView: View {
    // 창 수명 동안 유지되는 인스턴스를 주입받는다 — `TabViewModels` 참고.
    @ObservedObject var viewModel: CleanableListViewModel

    var body: some View {
        CleanableListView(title: "Android 캐시 (Gradle · Android Studio)", viewModel: viewModel)
            // 재진입 시 이전 결과를 그대로 보여 주면서 뒤에서 다시 스캔한다.
            .onAppearDeferred { viewModel.refresh() }
            .screenContext("Android 캐시") { [viewModel] in
                ScreenContextBuilder.cleanableList(
                    title: "Android 캐시 (Gradle · Android Studio)",
                    viewModel: viewModel
                )
            }
    }
}
