import AppKit

/// 메인 창을 실제로 사용자 눈앞에 띄우는 일을 한곳에서 처리한다.
///
/// 이 앱은 `LSUIElement`(Dock 아이콘 없는 에이전트)다. 창을 만들어도 앱이 활성화되지 않고,
/// 앞으로 가져올 Dock 아이콘조차 없다. 게다가 다른 앱이 전체 화면이면 그 앱이 Space를
/// 차지하고 우리 창은 다른 Space에 남는다.
///
/// 실측(전체 화면 편집기 + 여러 디스플레이 환경):
/// - `NSApp.activate`만 하면 `lsappinfo`는 DiskTidy가 최전면이라고 답하는데 화면에는
///   전체 화면 편집기만 찍혔다. `CGWindowList`로 보면 창은 존재하고 좌표도 화면 안이었다.
///   즉 "활성화"와 "보인다"는 다른 문제다.
/// - 그래서 기본값을 창 레벨 `.floating` + 모든 Space 참여로 둔다. 유틸리티 창이 전체 화면
///   앱 위에 뜨는 것과 같은 방식이다. 설정 탭에서 끌 수 있다.
@MainActor
enum WindowPresenter {
    static let alwaysOnTopKey = "WindowAlwaysOnTop"

    /// 기본값은 켜짐. Dock 아이콘이 없어 가려지면 다시 찾을 방법이 없다.
    /// `ContentView`의 `@AppStorage` 기본값과 반드시 같아야 한다.
    static var isAlwaysOnTopEnabled: Bool {
        UserDefaults.standard.object(forKey: alwaysOnTopKey) as? Bool ?? true
    }

    /// 활성화가 아예 막힌 정책인지. 순수 함수로 떼어 둔다 — 이 판정을 빼먹으면
    /// 개발 실행에서 키보드가 통째로 죽는다.
    nonisolated static func needsActivationPolicyFix(
        _ policy: NSApplication.ActivationPolicy
    ) -> Bool {
        policy == .prohibited
    }

    /// 창을 앞으로 가져온다. 실행·재열기·메뉴바에서 열기 세 경로 모두 여기를 거친다.
    static func present(alwaysOnTop: Bool, retriesRemaining: Int = 5) {
        // Info.plist 번들 없이 실행되면(Xcode의 SPM 실행, `swift run`) 활성화 정책이
        // `.prohibited`가 된다. 그 상태에서는 앱이 활성화되지 못해 어떤 창도 key window가
        // 되지 못하고, 마우스는 먹는데 키보드 입력만 통째로 안 된다 — 채팅 입력창뿐 아니라
        // 설정 탭 입력란까지 전부. 실측: prohibited면 `isKeyWindow`·`isActive` 둘 다 false,
        // `.accessory`로 올리면 둘 다 true.
        //
        // `.regular`가 아니라 `.accessory`로 올린다. 이 앱은 Dock 아이콘 없는 에이전트이고
        // `.accessory`도 활성화와 key window를 허용한다.
        if needsActivationPolicyFix(NSApp.activationPolicy()) {
            NSApp.setActivationPolicy(.accessory)
        }

        NSApp.activate(ignoringOtherApps: true)

        let windows = mainWindows
        for window in windows {
            apply(alwaysOnTop: alwaysOnTop, to: window)
            // `orderFrontRegardless`는 앱이 아직 비활성인 순간에도 창을 올린다.
            // `makeKeyAndOrderFront`만 쓰면 활성화 타이밍에 따라 조용히 무시된다.
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }

        // 실행 직후에는 SwiftUI가 아직 창을 만들지 않았을 수 있다. 그때는 올릴 대상이
        // 없어 조용히 아무 일도 하지 않게 되므로, 창이 생길 때까지 몇 번 더 시도한다.
        guard windows.isEmpty, retriesRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            present(alwaysOnTop: alwaysOnTop, retriesRemaining: retriesRemaining - 1)
        }
    }

    /// 설정 토글이 바뀔 때 부른다.
    static func setAlwaysOnTop(_ isEnabled: Bool) {
        for window in mainWindows { apply(alwaysOnTop: isEnabled, to: window) }
    }

    private static func apply(alwaysOnTop: Bool, to window: NSWindow) {
        window.level = alwaysOnTop ? .floating : .normal

        var behavior = window.collectionBehavior
        // `canJoinAllSpaces`와 `moveToActiveSpace`는 함께 켤 수 없다. 반대쪽을 먼저 뺀다.
        behavior.remove(alwaysOnTop ? .moveToActiveSpace : .canJoinAllSpaces)
        behavior.insert(alwaysOnTop ? .canJoinAllSpaces : .moveToActiveSpace)
        // 전체 화면 앱의 Space 위에도 얹힐 수 있게 한다. 이것이 없으면 전체 화면
        // 편집기를 쓰는 동안 창이 다른 Space에 갇힌다.
        behavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior = behavior
    }

    /// 메뉴바 팝오버(제목 없는 패널)는 건드리지 않는다. 레벨을 바꾸면 드롭다운이
    /// 화면에 박혀 남고, 앞으로 끌어올릴 대상도 아니다.
    private static var mainWindows: [NSWindow] {
        NSApp.windows.filter { $0.canBecomeMain && $0.styleMask.contains(.titled) }
    }
}
