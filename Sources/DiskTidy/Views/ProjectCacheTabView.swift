import SwiftUI

struct ProjectCacheTabView: View {
    // 창 수명 동안 유지되는 인스턴스를 주입받는다 — `TabViewModels` 참고.
    @ObservedObject var rootViewModel: RootFolderViewModel
    @ObservedObject var listViewModel: CleanableListViewModel

    private static let emptyHint = """
    폴더를 추가하면 하위 빌드 캐시를 탐색합니다. \
    Pods · DerivedData · .gradle · Carthage · .dart_tool · .next · .expo는 이름만으로 판정하고, \
    node_modules · build · dist · target · .build는 부모에 마커 파일(package.json, Cargo.toml 등)이 \
    있을 때만 캐시로 인정합니다.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RootFolderPicker(viewModel: rootViewModel, emptyHint: Self.emptyHint)

            Divider()

            CleanableListView(title: "프로젝트 빌드 캐시", viewModel: listViewModel)
        }
        .padding()
        .onAppearDeferred { syncRoots() }
        // `syncRoots`는 @Published를 바꾼다. `onChange`도 업데이트 안에서 불릴 수 있어 같은 이유로 미룬다.
        .onChange(of: rootViewModel.roots) { Task { @MainActor in syncRoots() } }
        .screenContext("프로젝트 캐시") { [listViewModel] in
            ScreenContextBuilder.cleanableList(
                title: "프로젝트 빌드 캐시",
                viewModel: listViewModel,
                note: Self.emptyHint
            )
        }
    }

    private func syncRoots() {
        listViewModel.roots = rootViewModel.roots
        listViewModel.refresh()
    }
}
