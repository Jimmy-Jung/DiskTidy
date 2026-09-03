import Darwin
import Foundation

/// macOS가 사용자 동의 없이는 읽지 못하게 막는 위치(TCC) 중 이 앱이 스캔하는 것.
///
/// 한자리에 모은 이유: 탭마다 처음 읽는 순간 프롬프트가 떠서 사용자는 탭을 옮길 때마다 권한
/// 알럿을 만났다 — 실측으로 Xcode 캐시 탭은 외장 볼륨(DerivedData가 외장 SSD), 프로젝트 캐시
/// 탭은 문서 폴더, 대용량 파일 탭은 다운로드 폴더를 물었다. 실행 직후 한 번에 묻고
/// (`FileAccessViewModel.requestAtLaunch`), 설정 탭에서 상태를 보여 준다.
enum ProtectedLocation: CaseIterable, Identifiable, Hashable, Sendable {
    case documents
    case desktop
    case downloads
    /// `/Volumes` 아래의 내장 디스크가 아닌 볼륨 전부(외장·네트워크). DerivedData를 외장 SSD로
    /// 빼 둔 구성이 흔해 Xcode 캐시 탭이 여기에 걸린다.
    case externalVolumes

    var id: Self { self }

    var label: String {
        switch self {
        case .documents: return "문서 폴더 (~/Documents)"
        case .desktop: return "데스크탑 폴더 (~/Desktop)"
        case .downloads: return "다운로드 폴더 (~/Downloads)"
        case .externalVolumes: return "외장·네트워크 볼륨 (/Volumes)"
        }
    }

    /// 홈 기준 폴더 이름. 볼륨은 홈 아래가 아니라 nil.
    var homeFolderName: String? {
        switch self {
        case .documents: return "Documents"
        case .desktop: return "Desktop"
        case .downloads: return "Downloads"
        case .externalVolumes: return nil
        }
    }
}

/// 한 위치의 접근 상태.
enum AccessState: Equatable, Sendable {
    /// 아직 읽어 보지 않았다. macOS에는 묻지 않고 상태만 조회하는 API가 없다.
    case unknown
    case granted
    case denied
    /// 확인할 대상이 없다 (예: 외장 볼륨이 하나도 마운트되지 않음).
    case notApplicable
}

enum FileAccess {
    /// 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근.
    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
    /// 시스템 설정 > 개인정보 보호 및 보안 > 파일 및 폴더.
    static let filesAndFoldersSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    )!

    /// 스캔 루트 외에 앱이 스스로 읽는 경로. 외장 디스크로 옮겨 두는 일이 흔한 것들이다.
    static var defaultScanPaths: [URL] {
        [
            XcodeCacheScanner.defaultDevURL.appendingPathComponent("DerivedData"),
            SimulatorManager.defaultDevicesRoot,
        ]
    }

    /// 전체 디스크 접근이 허용됐는지.
    ///
    /// TCC 데이터베이스는 그 권한 없이는 열 수 없고, 열어 보는 것은 프롬프트를 띄우지 않는다 —
    /// 전체 디스크 접근은 시스템 설정에서만 켤 수 있어 macOS가 묻지 않는다.
    static func hasFullDiskAccess(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let path = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    /// 위치를 실제로 읽어 본다. **아직 묻지 않은 위치면 이 호출이 곧 시스템 프롬프트다.**
    /// 사용자가 답할 때까지 호출 스레드가 멈추므로 메인 스레드에서 부르지 않는다.
    static func probe(
        _ location: ProtectedLocation,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AccessState {
        let targets: [URL]
        if let name = location.homeFolderName {
            targets = [home.appendingPathComponent(name)]
        } else {
            targets = externalVolumes()
            if targets.isEmpty { return .notApplicable }
        }
        // 볼륨은 전부 읽어 본다. 외장과 네트워크는 서로 다른 권한이라 하나만 읽으면 다른 쪽은
        // 다음 스캔에서 또 묻는다. `allSatisfy`는 첫 실패에서 멈추므로 쓰지 않는다.
        return targets.map(canList).allSatisfy { $0 } ? .granted : .denied
    }

    private static func canList(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// `/Volumes`의 내장 디스크가 아닌 볼륨. 부팅 볼륨 링크(`Macintosh HD` → `/`)는 뺀다.
    /// 볼륨 속성 조회는 디렉터리 읽기가 아니라 프롬프트를 띄우지 않는다.
    static func externalVolumes() -> [URL] {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .volumeIsInternalKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: Array(keys)
        )) ?? []
        return entries.filter { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return false }
            if values.isSymbolicLink == true { return false }
            // 속성을 못 읽은 볼륨(nil)은 외장으로 친다. 놓치면 그 볼륨을 스캔하는 탭이 나중에 따로
            // 묻게 되므로, 지금 한 번에 묻는 쪽이 이 기능의 목적에 맞다.
            return values.volumeIsInternal != true
        }
    }

    /// 실행 직후 한 번에 물을 위치.
    ///
    /// 문서·다운로드는 앱의 기본 동선(프로젝트 캐시·대용량 파일)이라 늘 넣고, 데스크탑과 외장
    /// 볼륨은 실제로 스캔할 경로가 거기 있을 때만 넣는다 — 안 쓰는 곳까지 묻지 않는다.
    static func locationsToRequest(
        roots: [URL],
        scanPaths: [URL] = defaultScanPaths,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ProtectedLocation] {
        var wanted: Set<ProtectedLocation> = [.documents, .downloads]
        for url in roots + scanPaths {
            if let location = location(containing: url, home: home) { wanted.insert(location) }
        }
        return ProtectedLocation.allCases.filter(wanted.contains)
    }

    /// 경로가 속한 보호 위치. 심볼릭 링크를 풀고 본다 — `~/Library/Developer/Xcode/DerivedData`가
    /// 외장 디스크를 가리키면 그 링크가 아니라 외장 볼륨이 답이다.
    static func location(
        containing url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ProtectedLocation? {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix("/Volumes/") { return .externalVolumes }
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        for location in ProtectedLocation.allCases {
            guard let name = location.homeFolderName else { continue }
            let folder = homePath + "/" + name
            if path == folder || path.hasPrefix(folder + "/") { return location }
        }
        return nil
    }
}
