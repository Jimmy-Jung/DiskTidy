import SwiftUI

struct BigFilesTabView: View {
    // 창 수명 동안 유지되는 인스턴스를 주입받는다 — `TabViewModels` 참고.
    @ObservedObject var rootViewModel: RootFolderViewModel
    @ObservedObject var listViewModel: CleanableListViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RootFolderPicker(
                viewModel: rootViewModel,
                emptyHint: "폴더를 추가하면 그 안의 200MB 이상 파일을 찾습니다."
            )

            Divider()

            CleanableListView(title: "대용량 파일 (200MB 이상)", viewModel: listViewModel)
        }
        .padding()
        .onAppear { syncRoots() }
        .onChange(of: rootViewModel.roots) { syncRoots() }
        .screenContext("대용량 파일") { [listViewModel] in
            ScreenContextBuilder.cleanableList(
                title: "대용량 파일 (200MB 이상)",
                viewModel: listViewModel,
                note: "선택한 폴더 안에서 200MB 이상인 파일만 보여 줍니다."
            )
        }
    }

    private func syncRoots() {
        listViewModel.roots = rootViewModel.roots
        listViewModel.refresh()
    }
}
