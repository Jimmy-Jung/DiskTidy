import AppKit
import SwiftUI

private struct SidebarItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let systemImage: String
}

private let sidebarItems: [SidebarItem] = [
    SidebarItem(id: 0, title: "SSD 용량", systemImage: "internaldrive"),
    // 임시파일을 캐시데이터 위에 둔다. 에이전트 작업물이 tmp에 GB 단위로 쌓여 이 탭이 가장 자주 쓰인다.
    // id는 표시 순서와 무관한 고정값이라 그대로 둔다.
    SidebarItem(id: 8, title: "임시파일", systemImage: "clock.badge.xmark"),
    SidebarItem(id: 1, title: "캐시데이터", systemImage: "trash.circle"),
    SidebarItem(id: 2, title: "시뮬레이터", systemImage: "iphone"),
    SidebarItem(id: 3, title: "프로젝트 캐시", systemImage: "folder.badge.gearshape"),
    SidebarItem(id: 4, title: "Xcode 캐시", systemImage: "hammer"),
    SidebarItem(id: 5, title: "대용량 파일", systemImage: "doc.badge.arrow.up"),
    SidebarItem(id: 6, title: "Android 캐시", systemImage: "shippingbox"),
    SidebarItem(id: 7, title: "Android 에뮬레이터", systemImage: "display"),
    SidebarItem(id: 9, title: "개발 데몬", systemImage: "memorychip"),
    // 설정 탭 id(10)는 챗봇 패널이 참조하는 고정값이라 새 탭은 그 뒤 번호를 쓴다.
    SidebarItem(id: 11, title: "패키지 캐시", systemImage: "cube.box"),
    SidebarItem(id: AppNavigationState.settingsTab, title: "설정", systemImage: "gearshape"),
]

struct ContentView: View {
    /// 사이드바 폭. 창 최소 폭 계산과 열 폭 고정이 같은 값을 써야 한다.
    private static let sidebarWidth: CGFloat = 200
    /// 본문이 실제로 요구하는 폭(실측). 목록 상단 바(제목·검색·요약·새로고침·액션)와 열
    /// 머리글이 이만큼을 가져간다. 이보다 좁히면 `NavigationSplitView`는 본문을 줄이는 대신
    /// **사이드바를 눌러** 항목 이름이 왼쪽에서 잘린다.
    private static let detailMinimumWidth: CGFloat = 660

    @EnvironmentObject private var navState: AppNavigationState
    @EnvironmentObject private var update: UpdateViewModel
    @EnvironmentObject private var fileAccess: FileAccessViewModel
    // 사이드바 선택은 이 뷰의 `@State`로 받고 `navState`와는 `onChange`로 맞춘다.
    // `List(selection:)`을 `navState.selectedTab`(@Published)에 직접 묶으면 macOS는 클릭을 처리하는
    // 뷰 업데이트 안에서 그 값을 발행해 "Publishing changes from within view updates" 경고를 내고,
    // 그 뒤의 렌더가 깨져 detail이 검게 남는다 — `onAppearDeferred` 주석 참고.
    @State private var selectedTab: Int? = 0
    // 탭 ViewModel은 여기(창 수명)에 묶는다. 탭 뷰 안에 두면 탭 전환마다 파괴되어
    // 재진입할 때 이전 스캔 결과가 사라진다 — `TabViewModels` 참고.
    @StateObject private var tabs = TabViewModels()
    // 기본값을 켜 둔다. 툴바 아이콘만으로는 기능이 있는 줄 모른다.
    // `store:`를 명시해야 `swift run`과 설치된 앱이 같은 도메인을 쓴다 — `AppDefaults` 참고.
    @AppStorage("ChatPanelVisible", store: AppDefaults.shared) private var isChatVisible = true
    @AppStorage(WindowPresenter.alwaysOnTopKey, store: AppDefaults.shared) private var isAlwaysOnTop = true

    var body: some View {
        // 사이드바를 접지 못하게 고정한다. 접고 펴는 동안 macOS가 툴바를 다시
        // 배치하면서 오버플로 표시(»)를 한 프레임 깜빡 그렸다 지운다 — 툴바 아이템을
        // 전부 빼도 재현되므로 우리 쪽에서 막을 방법이 없다(실측). 탭이 12개뿐이라
        // 접는 이득도 없다. 시스템 설정 앱처럼 항상 보이는 사이드바로 둔다.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // 업데이트 버튼은 사이드바 맨 아래에 둔다. 툴바에 두면 제목과 한 유리 캡슐로
            // 묶여 제목이 버튼처럼 보이고 잘린다 — macOS 26 툴바는 `.navigation` 영역의
            // 아이템을 강제로 그룹화하고 `ToolbarSpacer(.fixed)`로도 끊기지 않는다(실측).
            // 새 버전이 없으면 `UpdateButton`이 아무것도 그리지 않아 목록만 남는다.
            VStack(spacing: 0) {
                List(sidebarItems, selection: $selectedTab) { item in
                    Label(item.title, systemImage: item.systemImage)
                }
                // `LSUIElement` 앱이라 Dock도 앱 메뉴도 없다 — 표준 "DiskTidy 정보"로 갈 길이
                // 없어서, 앱 안에서 버전을 확인할 수 있는 자리는 여기뿐이다.
                Divider()
                Text("버전 \(AppInfo.displayVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    // 문의할 때 손으로 옮겨 적지 않도록 복사할 수 있게 둔다.
                    .textSelection(.enabled)
                UpdateButton(viewModel: update)
            }
            // 폭까지 고정한다. 드래그로 좁히면 그것도 툴바 재배치를 부른다.
            //
            // min·ideal·max를 같은 값으로 준다. 값 하나만 주는 형태는 폭이 모자랄 때 사이드바를
            // 먼저 줄여서, AI 도우미를 열면 사이드바가 밀려 항목이 잘렸다(실측). 상·하한을 함께
            // 못 박으면 부족한 폭은 본문·인스펙터가 나눠 감당한다.
            .navigationSplitViewColumnWidth(
                min: Self.sidebarWidth, ideal: Self.sidebarWidth, max: Self.sidebarWidth
            )
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailView(for: selectedTab ?? 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 챗봇은 macOS 표준 인스펙터로 띄운다. 열고 닫는 애니메이션, 경계
                // 드래그, 폭 저장을 전부 시스템이 한다. 직접 `HStack` + 구분선 +
                // 트랜지션으로 만들면 닫을 때 패널만 안 따라오는 등 조각마다 어긋난다.
                .inspector(isPresented: $isChatVisible) {
                    ChatPanelView()
                        .inspectorColumnWidth(
                            min: ChatPanelView.minimumWidth,
                            ideal: ChatPanelView.defaultWidth,
                            max: ChatPanelView.maximumWidth
                        )
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
        // 사이드바 200 + 본문 620. AI 도우미를 열면 최소 폭을 함께 올린다.
        //
        // 올리지 않으면 사이드바 200 + 인스펙터 400이 창 폭을 넘어서고, 그때 줄어드는 것은
        // **사이드바**다 — 900pt 창에서 사이드바가 화면 밖으로 밀려 항목이 보이지 않았다(실측).
        // 창이 한 번 넓어지는 편이 사이드바를 잃는 것보다 낫다.
        .frame(
            minWidth: isChatVisible
                ? Self.sidebarWidth + Self.detailMinimumWidth + ChatPanelView.minimumWidth
                : Self.sidebarWidth + Self.detailMinimumWidth,
            minHeight: 480
        )
        // 창이 실제로 생긴 뒤 한 번 더 올린다. 앱 델리게이트의 실행 알림은 SwiftUI가
        // 창을 만들기 전에 올 수 있어서, 그 시점에는 올릴 대상이 없다.
        // 첫 렌더 트랜잭션이 끝난 뒤에 올린다. `onAppear` 안에서 창 레벨·컬렉션 동작을 바꾸고
        // `makeKeyAndOrderFront`까지 부르면 AppKit이 레이아웃을 재진입시켜 첫 창이 그려지지 않거나
        // 죽을 수 있다 — `onAppearDeferred` 주석 참고.
        .onAppearDeferred { WindowPresenter.present(alwaysOnTop: isAlwaysOnTop) }
        // 챗봇 패널의 "설정 열기"처럼 바깥에서 탭 이동을 요청하면 따라간다.
        .onChange(of: navState.selectedTab) { selectedTab = navState.selectedTab }
        // 반대 방향도 맞춘다. 안 맞추면 같은 탭을 두 번째로 요청할 때 값이 그대로라 요청이 먹히지
        // 않는다. `@Published` 쓰기이므로 뷰 업데이트 밖으로 미룬다.
        .onChange(of: selectedTab) { _, newValue in
            Task { @MainActor in navState.selectedTab = newValue }
        }
        // 실행할 때 한 번만 묻는다. 토큰 없는 GitHub API는 시간당 60회 제한이 있고,
        // 매번 창을 열 때마다 부를 이유도 없다.
        .task { await update.checkForUpdate() }
        // 보호 위치(문서·다운로드·외장 볼륨 등)의 권한을 실행 직후 한 번에 묻는다. 탭마다 처음 읽는
        // 순간 하나씩 묻게 두면 탭을 옮길 때마다 알럿이 뜬다 — `FileAccess` 주석 참고.
        .task {
            fileAccess.requestAtLaunch(roots: tabs.projectCacheRoots.roots + tabs.bigFileRoots.roots)
        }
        .onChange(of: isAlwaysOnTop) { WindowPresenter.setAlwaysOnTop(isAlwaysOnTop) }
    }

    @ViewBuilder
    private func detailView(for tab: Int) -> some View {
        switch tab {
        case 0: StorageTabView()
        case 1: CacheTabView(viewModel: tabs.cache)
        case 2: SimulatorTabView(viewModel: tabs.simulator)
        case 3: ProjectCacheTabView(rootViewModel: tabs.projectCacheRoots, listViewModel: tabs.projectCache)
        case 4: XcodeCacheTabView(viewModel: tabs.xcodeCache)
        case 5: BigFilesTabView(rootViewModel: tabs.bigFileRoots, listViewModel: tabs.bigFiles)
        case 6: AndroidCacheTabView(viewModel: tabs.androidCache)
        case 7: AndroidEmulatorTabView(viewModel: tabs.androidEmulator)
        case 8: TempTabView(viewModel: tabs.temp)
        case 9: MemoryTabView(viewModel: tabs.memory)
        case 11: PackageCacheTabView(viewModel: tabs.packageCache)
        case AppNavigationState.settingsTab: SettingsTabView()
        default: StorageTabView()
        }
    }
}
