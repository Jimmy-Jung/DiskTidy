import Foundation

/// 탭별 ViewModel을 창 수명 동안 붙잡아 두는 컨테이너.
///
/// 각 탭 뷰가 `@StateObject`로 직접 만들면 탭을 벗어날 때 뷰와 함께 파괴되어
/// 재진입마다 빈 화면에서 다시 스캔한다. 여기 모아 `ContentView`가 들고 있으면
/// 재진입 시 이전 결과를 즉시 보여 주고 새 스캔은 백그라운드로만 돈다.
@MainActor
final class TabViewModels: ObservableObject {
    // 정적 메서드 참조는 @Sendable로 추론되지 않는다. 캡처 없는 클로저 리터럴로 감싼다.
    let cache = CleanableListViewModel(scan: { CacheScanner.scan() })
    let simulator = SimulatorViewModel()
    let projectCacheRoots = RootFolderViewModel(storeKey: "ProjectCacheRoots")
    let projectCache = CleanableListViewModel(rootScan: { ProjectCacheScanner.scan(roots: $0) })
    let xcodeCache = CleanableListViewModel(scan: { XcodeCacheScanner.scan() })
    let bigFileRoots = RootFolderViewModel(
        storeKey: "BigFileRoots",
        defaultRoots: [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")]
    )
    let bigFiles = CleanableListViewModel(rootScan: { BigFileScanner.scan(roots: $0) })
    let androidCache = CleanableListViewModel(scan: { AndroidCacheScanner.scan() })
    // AVD 디렉터리를 지울 때 짝인 `<name>.ini` 포인터 파일도 함께 정리한다.
    let androidEmulator = CleanableListViewModel(
        scan: { AndroidEmulatorScanner.scan() },
        companionPaths: { [AndroidEmulatorScanner.iniURL(forAVDNamed: $0.name)] }
    )
    let temp = TempCleanupViewModel()
    let memory = MemoryViewModel()
}
