import SwiftUI

struct AndroidCacheTabView: View {
    @StateObject private var viewModel = CleanableListViewModel(scan: { AndroidCacheScanner.scan() })

    var body: some View {
        CleanableListView(title: "Android 캐시 (Gradle · Android Studio)", viewModel: viewModel)
            .onAppear {
                if viewModel.items.isEmpty { viewModel.refresh() }
            }
    }
}
