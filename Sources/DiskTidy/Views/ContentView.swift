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
    SidebarItem(id: 8, title: "임시파일", systemImage: "clock.badge.xmark"),
    SidebarItem(id: 9, title: "개발 데몬", systemImage: "memorychip"),
    SidebarItem(id: AppNavigationState.settingsTab, title: "설정", systemImage: "gearshape"),
]

struct ContentView: View {
    @EnvironmentObject private var navState: AppNavigationState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    // 기본값을 켜 둔다. 툴바 아이콘만으로는 기능이 있는 줄 모른다.
    @AppStorage("ChatPanelVisible") private var isChatVisible = true
    @AppStorage(WindowPresenter.alwaysOnTopKey) private var isAlwaysOnTop = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(sidebarItems, selection: $navState.selectedTab) { item in
                Label(item.title, systemImage: item.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            HStack(spacing: 0) {
                detailView(for: navState.selectedTab ?? 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isChatVisible {
                    Divider()
                    ChatPanelView()
                }
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        isChatVisible.toggle()
                    } label: {
                        Label("AI 도우미", systemImage: "bubble.left.and.bubble.right")
                    }
                    .help(isChatVisible ? "AI 도우미 숨기기" : "AI 도우미 보기")
                }
            }
        }
        // 패널을 펼치면 본문이 눌린다. 최소 너비를 패널 폭만큼 함께 넓힌다.
        .frame(minWidth: isChatVisible ? 820 + ChatPanelView.width : 820, minHeight: 480)
        // 창이 실제로 생긴 뒤 한 번 더 올린다. 앱 델리게이트의 실행 알림은 SwiftUI가
        // 창을 만들기 전에 올 수 있어서, 그 시점에는 올릴 대상이 없다.
        .onAppear { WindowPresenter.present(alwaysOnTop: isAlwaysOnTop) }
        .onChange(of: isAlwaysOnTop) { WindowPresenter.setAlwaysOnTop($0) }
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
        case 9: MemoryTabView()
        case AppNavigationState.settingsTab: SettingsTabView()
        default: StorageTabView()
        }
    }
}
