import AppKit
import SwiftUI

/// 챗봇 패널 폭을 끌어 바꾸는 구분선.
///
/// 패널이 오른쪽에 있으므로 왼쪽으로 끌면 넓어진다. 그래서 이동량을 빼서 더한다.
/// 끌기 시작한 폭을 따로 기억한다 — `translation`은 누적값이라 매 이벤트에 그대로
/// 더하면 손이 조금만 움직여도 폭이 폭주한다.
private struct ChatPanelDivider: View {
    @Binding var width: Double

    @State private var widthAtDragStart: Double?

    /// 잡는 영역. 선은 1pt지만 그것만 노리게 하면 못 잡는다.
    private static let grabWidth: CGFloat = 6

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: Self.grabWidth)
            // 투명한 여백까지 눌리게 만든다. 이게 없으면 그린 1pt만 반응한다.
            .contentShape(Rectangle())
            // `push`/`pop` 대신 `set`을 쓴다. 창이 포커스를 잃어 나가는 이벤트를 놓치면
            // push만 쌓여 커서가 리사이즈 모양으로 굳는다.
            .onHover { isInside in
                if isInside {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = widthAtDragStart ?? width
                        widthAtDragStart = start
                        width = min(
                            max(start - value.translation.width, ChatPanelView.minimumWidth),
                            ChatPanelView.maximumWidth
                        )
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
    }
}

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
    /// 메뉴바 팝오버가 열리고 닫히는 감각에 맞춘다 — 짧게 밀려 들어오고 튀지 않는다.
    private static let panelAnimation: Animation = .easeOut(duration: 0.22)

    @EnvironmentObject private var navState: AppNavigationState
    @EnvironmentObject private var update: UpdateViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    // 기본값을 켜 둔다. 툴바 아이콘만으로는 기능이 있는 줄 모른다.
    // `store:`를 명시해야 `swift run`과 설치된 앱이 같은 도메인을 쓴다 — `AppDefaults` 참고.
    @AppStorage("ChatPanelVisible", store: AppDefaults.shared) private var isChatVisible = true
    @AppStorage(WindowPresenter.alwaysOnTopKey, store: AppDefaults.shared) private var isAlwaysOnTop = true
    @AppStorage("ChatPanelWidth", store: AppDefaults.shared) private var chatWidth = ChatPanelView.defaultWidth

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 업데이트 버튼은 사이드바 맨 아래에 둔다. 툴바에 두면 제목과 한 유리 캡슐로
            // 묶여 제목이 버튼처럼 보이고 잘린다 — macOS 26 툴바는 `.navigation` 영역의
            // 아이템을 강제로 그룹화하고 `ToolbarSpacer(.fixed)`로도 끊기지 않는다(실측).
            // 새 버전이 없으면 `UpdateButton`이 아무것도 그리지 않아 목록만 남는다.
            VStack(spacing: 0) {
                List(sidebarItems, selection: $navState.selectedTab) { item in
                    Label(item.title, systemImage: item.systemImage)
                }
                UpdateButton(viewModel: update)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            HStack(spacing: 0) {
                detailView(for: navState.selectedTab ?? 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isChatVisible {
                    // 구분선과 패널을 한 덩어리로 묶어 함께 밀려 들어오게 한다.
                    // 따로 두면 구분선만 먼저 나타나 선이 공중에 떠 보인다.
                    HStack(spacing: 0) {
                        ChatPanelDivider(width: $chatWidth)
                        ChatPanelView(width: chatWidth)
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            // 패널이 나타나고 사라지는 동안 본문 폭도 함께 움직여야 한다. 트랜지션만
            // 걸면 패널은 밀려 나가는데 본문은 즉시 넓어져 한 프레임 어긋나 보인다.
            .clipped()
            .toolbar {
                ToolbarItem {
                    Button {
                        withAnimation(Self.panelAnimation) { isChatVisible.toggle() }
                    } label: {
                        Label("AI 도우미", systemImage: "bubble.left.and.bubble.right")
                    }
                    .help(isChatVisible ? "AI 도우미 숨기기" : "AI 도우미 보기")
                }
            }
        }
        // 패널을 펼치면 본문이 눌린다. 최소 너비를 패널 폭만큼 함께 넓힌다.
        // 사용자가 패널을 넓히면 창 최소 너비도 따라 넓어져 본문이 짜부라지지 않는다.
        .frame(minWidth: isChatVisible ? 820 + chatWidth : 820, minHeight: 480)
        // 창이 실제로 생긴 뒤 한 번 더 올린다. 앱 델리게이트의 실행 알림은 SwiftUI가
        // 창을 만들기 전에 올 수 있어서, 그 시점에는 올릴 대상이 없다.
        .onAppear { WindowPresenter.present(alwaysOnTop: isAlwaysOnTop) }
        // 실행할 때 한 번만 묻는다. 토큰 없는 GitHub API는 시간당 60회 제한이 있고,
        // 매번 창을 열 때마다 부를 이유도 없다.
        .task { await update.checkForUpdate() }
        .onChange(of: isAlwaysOnTop) { WindowPresenter.setAlwaysOnTop(isAlwaysOnTop) }
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
