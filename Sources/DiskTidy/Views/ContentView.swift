import SwiftUI

private struct SidebarItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let systemImage: String
}

private let sidebarItems: [SidebarItem] = [
    SidebarItem(id: 0, title: "SSD 용량", systemImage: "internaldrive"),
    SidebarItem(id: 1, title: "캐시데이터", systemImage: "trash.circle"),
    SidebarItem(id: 2, title: "시뮬레이터", systemImage: "iphone"),
    SidebarItem(id: 3, title: "프로젝트 캐시", systemImage: "folder.badge.gearshape"),
    SidebarItem(id: 4, title: "Xcode 캐시", systemImage: "hammer"),
    SidebarItem(id: 5, title: "대용량 파일", systemImage: "doc.badge.arrow.up"),
    SidebarItem(id: 6, title: "Android 캐시", systemImage: "shippingbox"),
    SidebarItem(id: 7, title: "Android 에뮬레이터", systemImage: "display"),
    // 개발 데몬 정리 탭은 다음 ID인 9를 쓴다. 두 기능을 병렬 구현해도 충돌하지 않는다.
    SidebarItem(id: 8, title: "임시파일", systemImage: "clock.badge.xmark"),
]

struct ContentView: View {
    @EnvironmentObject private var navState: AppNavigationState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(sidebarItems, selection: $navState.selectedTab) { item in
                Label(item.title, systemImage: item.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detailView(for: navState.selectedTab ?? 0)
        }
        .frame(minWidth: 820, minHeight: 480)
    }

    @ViewBuilder
    private func detailView(for tab: Int) -> some View {
        switch tab {
        case 0: StorageTabView()
        case 1: CacheTabView()
        case 2: SimulatorTabView()
        case 3: ProjectCacheTabView()
        case 4: XcodeCacheTabView()
        case 5: BigFilesTabView()
        case 6: AndroidCacheTabView()
        case 7: AndroidEmulatorTabView()
        case 8: TempTabView()
        default: StorageTabView()
        }
    }
}
