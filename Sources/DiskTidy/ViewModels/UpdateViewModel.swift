import AppKit
import Foundation

enum UpdateState: Equatable {
    /// 아직 확인하지 않았거나, 확인할 대상이 없다(번들 없이 실행 중).
    case idle
    case checking
    case upToDate(SemanticVersion)
    case available(AppRelease)
    case installing(SemanticVersion)
    case restarting
    case failed(String)
}

/// 툴바 업데이트 버튼의 상태를 들고 있는다.
///
/// 확인·설치·재시작을 주입받는 이유는 테스트다. 실제 구현은 네트워크를 타고
/// `/Applications`를 건드리고 앱을 종료시킨다 — 테스트가 그걸 실행할 수는 없다.
@MainActor
final class UpdateViewModel: ObservableObject {
    @Published private(set) var state: UpdateState = .idle

    private let installedVersion: SemanticVersion?
    private let fetchLatest: @Sendable () async throws -> AppRelease
    private let install: @Sendable (AppRelease) async throws -> URL
    private let relaunch: @MainActor (URL) -> Void

    init(
        installedVersion: SemanticVersion? = UpdateChecker.installedVersion,
        fetchLatest: @escaping @Sendable () async throws -> AppRelease = {
            try await UpdateChecker.fetchLatest()
        },
        install: @escaping @Sendable (AppRelease) async throws -> URL = {
            try await UpdateInstaller.install($0)
        },
        relaunch: @escaping @MainActor (URL) -> Void = { bundleURL in
            UpdateInstaller.scheduleRelaunch(of: bundleURL)
            NSApp.terminate(nil)
        }
    ) {
        self.installedVersion = installedVersion
        self.fetchLatest = fetchLatest
        self.install = install
        self.relaunch = relaunch
    }

    /// 버튼을 아예 감출지. 최신이거나 확인 전이면 툴바에 아무것도 두지 않는다 —
    /// 평소에는 존재하지 않는 버튼이 요구사항이다.
    var isButtonVisible: Bool {
        switch state {
        case .idle, .checking, .upToDate: return false
        case .available, .installing, .restarting, .failed: return true
        }
    }

    func checkForUpdate() async {
        // 번들 없이 실행하면 교체할 `.app`이 없다. 확인 자체가 의미 없다.
        guard let installedVersion else { return }
        guard state == .idle || isFailed else { return }

        state = .checking
        do {
            let latest = try await fetchLatest()
            state = latest.version > installedVersion
                ? .available(latest)
                : .upToDate(installedVersion)
        } catch {
            state = .failed(message(for: error))
        }
    }

    func installUpdate() async {
        guard case .available(let release) = state else { return }

        state = .installing(release.version)
        do {
            let bundleURL = try await install(release)
            // 교체가 끝난 번들로는 지금 프로세스가 새 코드를 실행할 수 없다. 바로 재시작한다.
            state = .restarting
            relaunch(bundleURL)
        } catch {
            state = .failed(message(for: error))
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
