import AppKit
import SwiftUI

/// `LSUIElement` 앱은 실행해도 활성화되지 않아 창이 다른 앱 뒤에 뜬다. Dock 아이콘이 없어
/// 사용자가 앞으로 끌어올릴 방법도 없으므로 실행·재열기 시점에 직접 올린다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowPresenter.present(alwaysOnTop: WindowPresenter.isAlwaysOnTopEnabled)
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
        }

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(storageMonitor)
        } label: {
            Text("💾 \(storageMonitor.percentUsedText)")
        }
        .menuBarExtraStyle(.window)
    }
}
