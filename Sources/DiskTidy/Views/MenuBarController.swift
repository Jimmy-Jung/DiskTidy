import AppKit
import Combine
import SwiftUI

/// 메뉴바 아이콘을 AppKit `NSStatusItem`으로 직접 만든다.
///
/// SwiftUI `MenuBarExtra`를 쓰면 **앱이 실행 직후 종료된다**(macOS 26.5 실측, lldb로 확인):
///
/// 1. macOS 26의 `MenuBarExtra`는 상태 아이콘을 FrontBoard 씬(`NSSceneStatusItem`)으로 호스팅하고,
///    그 `NSStatusItem`을 `terminateOnRemoval = YES`로 만든다.
/// 2. ControlCenter는 자동 배정 슬롯의 표시 여부를 기억한다 — 이 기계에서는
///    `NSStatusItem Visible Item-0` … `Item-12`가 전부 `0`(숨김)이었다.
/// 3. 그래서 실행 즉시 `NSStatusItemChangeVisibilityAction visible=0`이 앱에 전달되고,
///    AppKit은 이것을 "사용자가 아이콘을 제거했다"로 읽어 앱을 종료한다.
///    백트레이스: `-[NSSceneStatusItem scene:handleActions:]` → `-[NSApplication terminate:]`.
///
/// 창은 정상적으로 만들어져 있었고 자동 종료(automatic termination)와도 무관하다 — 종료를 부르는
/// 것은 상태 아이콘이다. `NSStatusItem.behavior`를 비워 두면 제거 자체가 불가능해져
/// (`NSStatusItem.h`: "By default, an item is not removable") 이 경로가 사라진다.
/// `behavior`는 macOS 10.12부터 있어 배포 대상(macOS 14)에서 버전 분기가 필요 없다.
@MainActor
final class MenuBarController {
    /// 아이콘을 사용자가 제거할 수 없게 둔다. `.terminationOnRemoval`이 들어오는 순간
    /// 위에 적은 종료 경로가 되살아난다.
    static let behavior: NSStatusItem.Behavior = []

    private var item: NSStatusItem?
    private var titleObserver: AnyCancellable?
    private let popover = NSPopover()

    /// 실행 직후 한 번 부른다. 두 번 불러도 아이콘은 하나만 만든다.
    func install(storageMonitor: StorageMonitor, openApp: @escaping () -> Void) {
        guard item == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = Self.behavior
        item.button?.title = Self.title(for: storageMonitor)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        self.item = item

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(openApp: openApp, quit: { NSApp.terminate(nil) })
                .environmentObject(storageMonitor)
        )

        // 사용률 텍스트를 아이콘에 계속 반영한다. `objectWillChange`를 쓰면 `StorageMonitor`가
        // 무엇을 발행하는지에 기대지 않는다.
        titleObserver = storageMonitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self, weak storageMonitor] _ in
                guard let storageMonitor else { return }
                self?.item?.button?.title = Self.title(for: storageMonitor)
            }
    }

    private static func title(for storageMonitor: StorageMonitor) -> String {
        "💾 \(storageMonitor.percentUsedText)"
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // 팝오버 안의 입력을 받으려면 앱이 활성이어야 한다. 이 앱은 Dock 아이콘이 없어
        // 클릭만으로는 활성화되지 않는다 — `WindowPresenter` 주석 참고.
        popover.contentViewController?.view.window?.makeKey()
    }
}

/// 메인 창을 띄우는 액션(`openWindow`)은 SwiftUI 씬 안에서만 읽을 수 있다. 메뉴바 아이콘은
/// AppKit이 들고 있으므로, 창의 뷰가 처음 나타날 때 액션을 넘겨 아이콘을 설치한다.
struct MenuBarInstaller: ViewModifier {
    let controller: MenuBarController
    let storageMonitor: StorageMonitor

    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppearDeferred {
            controller.install(storageMonitor: storageMonitor) { openWindow(id: "main") }
        }
    }
}
