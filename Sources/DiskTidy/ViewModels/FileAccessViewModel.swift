import AppKit
import Foundation

/// 설정 탭 "파일 접근 권한" 섹션과 실행 직후 일괄 요청의 상태.
///
/// 권한을 켜는 API는 없다. 할 수 있는 것은 (1) 보호 위치를 읽어 봐서 macOS가 묻게 만드는 것,
/// (2) 시스템 설정의 해당 화면을 열어 주는 것뿐이다. 그래서 화면은 토글이 아니라 상태 + 버튼이다.
@MainActor
final class FileAccessViewModel: ObservableObject {
    /// nil이면 아직 확인 전.
    @Published private(set) var hasFullDiskAccess: Bool?
    @Published private(set) var states: [ProtectedLocation: AccessState]
    @Published private(set) var isRequesting = false

    private let probe: @Sendable (ProtectedLocation) -> AccessState
    private let checkFullDiskAccess: @Sendable () -> Bool
    private let openSettings: @MainActor (URL) -> Void
    private var activationObserver: NSObjectProtocol?

    /// 실제 동작은 TCC 프롬프트를 띄우고 시스템 설정을 연다. 테스트가 그걸 할 수는 없어 주입받는다.
    init(
        probe: @escaping @Sendable (ProtectedLocation) -> AccessState = { FileAccess.probe($0) },
        checkFullDiskAccess: @escaping @Sendable () -> Bool = { FileAccess.hasFullDiskAccess() },
        openSettings: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        observesActivation: Bool = true
    ) {
        self.probe = probe
        self.checkFullDiskAccess = checkFullDiskAccess
        self.openSettings = openSettings
        states = Dictionary(uniqueKeysWithValues: ProtectedLocation.allCases.map { ($0, .unknown) })

        // 시스템 설정에서 전체 디스크 접근을 켜고 돌아오면 표시를 새로 읽는다.
        // 앱이 다시 활성화되는 순간이 그 시점이다.
        guard observesActivation else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFullDiskAccess() }
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    /// 묻지 않고 확인만 한다. 설정 탭이 보일 때와 앱이 다시 활성화될 때 부른다.
    func refreshFullDiskAccess() {
        let check = checkFullDiskAccess
        Task {
            let granted = await Task.detached { check() }.value
            hasFullDiskAccess = granted
            // 전체 디스크 접근이 있으면 폴더별 권한은 따로 볼 필요가 없다.
            if granted { markAllGranted() }
        }
    }

    /// 실행 직후 한 번. 탭을 열 때마다 하나씩 묻는 대신 지금 다 묻는다.
    ///
    /// 매 실행마다 불러도 된다 — 이미 허용·거부된 위치는 macOS가 다시 묻지 않으므로 프롬프트는
    /// 미결정 위치에만 뜬다. 그 미결정 위치는 어차피 탭을 열면 물었을 것들이다.
    func requestAtLaunch(roots: [URL]) {
        request(FileAccess.locationsToRequest(roots: roots))
    }

    /// 설정 탭 버튼. 위치 전부.
    func requestAll() {
        request(ProtectedLocation.allCases)
    }

    func openFullDiskAccessSettings() {
        openSettings(FileAccess.fullDiskAccessSettingsURL)
    }

    func openFilesAndFoldersSettings() {
        openSettings(FileAccess.filesAndFoldersSettingsURL)
    }

    private func request(_ locations: [ProtectedLocation]) {
        guard !isRequesting else { return }
        isRequesting = true
        let probe = self.probe
        let check = checkFullDiskAccess
        Task {
            // 전체 디스크 접근이 있으면 프롬프트가 뜰 일이 없다. 읽어 보지 않고 끝낸다.
            let fullDisk = await Task.detached { check() }.value
            hasFullDiskAccess = fullDisk
            if fullDisk {
                markAllGranted()
                isRequesting = false
                return
            }
            // 순서대로 하나씩. 읽기가 프롬프트를 띄우고 사용자가 답할 때까지 멈추므로
            // 화면에는 한 번에 하나만 뜬다.
            for location in locations {
                states[location] = await Task.detached { probe(location) }.value
            }
            isRequesting = false
        }
    }

    private func markAllGranted() {
        for location in ProtectedLocation.allCases { states[location] = .granted }
    }
}
