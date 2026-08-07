import SwiftUI

struct AndroidEmulatorTabView: View {
    // AVD 디렉터리를 지울 때 짝인 `<name>.ini` 포인터 파일도 함께 정리한다.
    @StateObject private var viewModel = CleanableListViewModel(
        scan: { AndroidEmulatorScanner.scan() },
        companionPaths: { [AndroidEmulatorScanner.iniURL(forAVDNamed: $0.name)] }
    )

    var body: some View {
        CleanableListView(title: "Android 에뮬레이터 (AVD)", viewModel: viewModel)
            .onAppear {
                if viewModel.items.isEmpty { viewModel.refresh() }
            }
    }
}
