import AppKit
import Combine
import SwiftUI

/// 메뉴바 아이콘을 AppKit `NSStatusItem`으로 직접 만든다.
///
/// SwiftUI `MenuBarExtra`를 쓰면 **앱이 실행 직후 종료된다**(macOS 26.5 실측). lldb로 잡은
/// 종료 호출자:
///
///     frame #0  -[NSApplication terminate:]
///     frame #1  -[NSSceneStatusItem scene:handleActions:]
///     frame #2  -[FBSSceneObserver scene:handleActions:]
///
/// macOS 26의 `MenuBarExtra`는 상태 아이콘을 FrontBoard 씬(`NSSceneStatusItem`)으로 호스팅하고
/// 그 아이콘에는 `terminateOnRemoval`이 켜져 있다. 실행 직후 시스템이
/// `NSStatusItemChangeVisibilityAction visible=0`을 보내면 AppKit은 그것을 "사용자가 아이콘을
/// 제거했다"로 읽어 앱을 종료한다. 상태 아이콘의 표시 여부는 **앱 자신의 설정 도메인**에
/// autosave 이름으로 남는데(`com.jimmy.disktidy`의 `NSStatusItem Visible Item-N` ·
/// `NSStatusItem VisibleCC Item-N`), 이 기계에서는 전부 `0`(숨김)이었다.
///
/// 최소 재현으로 범위를 좁혔다: `MenuBarExtra`만 있는 앱은 죽고(`.menu` 스타일도 동일),
/// `Window` 씬만 있는 `LSUIElement` 앱은 산다. 즉 창 부재도 자동 종료도 원인이 아니다 —
/// 종료를 부르는 것은 SwiftUI가 만든 상태 아이콘이다.
///
/// 그래서 씬으로 호스팅되지 않는 **고전 `NSStatusItem`** 을 직접 만든다. 여기에는 그 종료 경로가
/// 없다(실측: 같은 번들·같은 창 구성으로 살아남고 아이콘도 보인다). `behavior = []`는 새로 만든
/// 아이콘의 기본값과 같지만, `.terminationOnRemoval`이 다시 붙으면 이 버그가 되살아나므로
/// 의도를 코드에 못 박아 둔다.
///
/// 확정하지 못한 것: 시스템이 실행 시점에 왜 "숨김"을 요청했는지. 메뉴바가 꽉 찬 환경에서
/// 재현됐고 위 기록이 전부 숨김이었다는 사실만 남긴다.
@MainActor
final class MenuBarController {
    /// 새 `NSStatusItem`의 기본값과 같은 값이다. 의도를 남기려고 명시한다 — 위 주석 참고.
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
