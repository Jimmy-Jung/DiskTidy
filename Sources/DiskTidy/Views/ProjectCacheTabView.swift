import SwiftUI

struct ProjectCacheTabView: View {
    @StateObject private var rootViewModel = RootFolderViewModel(storeKey: "ProjectCacheRoots")
    @StateObject private var listViewModel = CleanableListViewModel(
        rootScan: { ProjectCacheScanner.scan(roots: $0) }
    )

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
        .onAppear { syncRoots() }
        .onChange(of: rootViewModel.roots) { _ in syncRoots() }
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
