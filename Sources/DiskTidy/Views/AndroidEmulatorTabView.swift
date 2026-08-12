import SwiftUI

struct AndroidEmulatorTabView: View {
    // 창 수명 동안 유지되는 인스턴스를 주입받는다 — `TabViewModels` 참고.
    @ObservedObject var viewModel: CleanableListViewModel

    var body: some View {
        CleanableListView(title: "Android 에뮬레이터 (AVD)", viewModel: viewModel)
            // 재진입 시 이전 결과를 그대로 보여 주면서 뒤에서 다시 스캔한다.
            .onAppear { viewModel.refresh() }
            .screenContext("Android 에뮬레이터") { [viewModel] in
                ScreenContextBuilder.cleanableList(
                    title: "Android 에뮬레이터 (AVD)",
                    viewModel: viewModel,
                    note: "AVD 디렉터리를 지울 때 짝인 <이름>.ini 포인터 파일도 함께 휴지통으로 갑니다."
                )
            }
    }
}
