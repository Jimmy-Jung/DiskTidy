import SwiftUI

struct XcodeCacheTabView: View {
    @StateObject private var viewModel = CleanableListViewModel(scan: { XcodeCacheScanner.scan() })

    var body: some View {
        CleanableListView(
            title: "Xcode 캐시 (DerivedData · DeviceSupport · Archives)",
            viewModel: viewModel
        )
        .onAppear {
            if viewModel.items.isEmpty { viewModel.refresh() }
        }
        .screenContext("Xcode 캐시") { [viewModel] in
            ScreenContextBuilder.cleanableList(
                title: "Xcode 캐시 (DerivedData · DeviceSupport · Archives)",
                viewModel: viewModel
            )
        }
    }
}
