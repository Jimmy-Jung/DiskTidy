import SwiftUI

struct CacheTabView: View {
    // 정적 메서드 참조는 @Sendable로 추론되지 않는다. 캡처 없는 클로저 리터럴로 감싼다.
    @StateObject private var viewModel = CleanableListViewModel(scan: { CacheScanner.scan() })

    var body: some View {
        CleanableListView(title: "캐시데이터 (~/Library/Caches)", viewModel: viewModel)
            .onAppear {
                if viewModel.items.isEmpty { viewModel.refresh() }
            }
    }
}
