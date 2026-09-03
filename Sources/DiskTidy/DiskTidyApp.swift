import AppKit
import SwiftUI

/// `LSUIElement` 앱은 실행해도 활성화되지 않아 창이 다른 앱 뒤에 뜬다. Dock 아이콘이 없어
/// 사용자가 앞으로 끌어올릴 방법도 없으므로 실행·재열기 시점에 직접 올린다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowPresenter.present(alwaysOnTop: WindowPresenter.isAlwaysOnTopEnabled)
    }

    /// 창을 닫아도 앱은 메뉴바에 남는다.
    ///
    /// 실측(macOS 26.5): 이 메서드를 구현하지 않으면 SwiftUI가 마지막 창이 닫힐 때 앱을 종료한다 —
    /// `LSUIElement` 앱이라 Dock 아이콘도 없어서, 종료되면 메뉴바 아이콘까지 사라지고 다시 열
    /// 방법이 없다. 종료는 메뉴바의 "종료"로만 한다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 이미 실행 중일 때 앱을 다시 열면(Finder 재실행 등) 여기로 온다.
    /// 기본 동작은 아무 일도 하지 않는 것이라, 사용자에게는 앱이 안 열린 것처럼 보인다.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        WindowPresenter.present(alwaysOnTop: WindowPresenter.isAlwaysOnTopEnabled)
        return true
    }
}

@main
struct DiskTidyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var navState = AppNavigationState()
    @StateObject private var storageMonitor = StorageMonitor()
    // 챗봇 상태는 앱 수준에 둔다. 패널 안에 두면 패널을 접었다 펼 때마다 대화가 사라진다.
    @StateObject private var chatContext = ChatContextStore()
    @StateObject private var aiSettings = AISettingsViewModel()
    @StateObject private var chat = ChatViewModel()
    // 항목 설명 캐시도 앱 수준에 둔다. 탭을 옮기거나 새로고침할 때마다 다시 물으면
    // 같은 폴더에 대해 요청이 계속 나간다.
    @StateObject private var explanations = ItemExplanationStore()
    @StateObject private var update = UpdateViewModel()
    // 파일 접근 권한 상태. 실행 직후 한 번에 묻고 설정 탭이 보여 준다 — `FileAccess` 참고.
    @StateObject private var fileAccess = FileAccessViewModel()
    // 메뉴바 아이콘은 SwiftUI `MenuBarExtra`가 아니라 AppKit이 만든다 — `MenuBarController` 참고.
    @State private var menuBar = MenuBarController()

    var body: some Scene {
        // `WindowGroup`은 메뉴바의 "앱 열기"를 누를 때마다 새 창을 만든다. 탭 ViewModel은
        // 창마다 따로 생기는데 챗봇 컨텍스트 저장소는 앱 전역이라, 창이 둘이면 챗봇이
        // 다른 창의 상태를 근거로 답한다. 창을 하나로 고정한다.
        Window("DiskTidy", id: "main") {
            ContentView()
                .environmentObject(navState)
                .environmentObject(storageMonitor)
                .environmentObject(chatContext)
                .environmentObject(aiSettings)
                .environmentObject(chat)
                .environmentObject(explanations)
                .environmentObject(update)
                .environmentObject(fileAccess)
                .modifier(MenuBarInstaller(controller: menuBar, storageMonitor: storageMonitor))
        }
        // 보기 메뉴에 챗봇 인스펙터 토글과 ⌃⌘I를 넣는다. 툴바 버튼만 두면
        // 키보드만 쓰는 사용자는 패널을 열 방법이 없다.
        // 사이드바는 고정이라 `SidebarCommands()`는 넣지 않는다 — `ContentView` 참고.
        .commands { InspectorCommands() }
    }
}
