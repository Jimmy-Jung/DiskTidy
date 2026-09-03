import Foundation
import Testing

@testable import DiskTidy

// MARK: - 위치 판정 (순수 함수)

@Suite("파일 접근 권한 위치 판정")
struct FileAccessLocationTests {
    private let home = URL(fileURLWithPath: "/Users/test")

    @Test("홈의 보호 폴더와 그 하위를 알아본다")
    func locatesHomeFolders() {
        #expect(FileAccess.location(containing: URL(fileURLWithPath: "/Users/test/Documents/GitHub"), home: home) == .documents)
        #expect(FileAccess.location(containing: URL(fileURLWithPath: "/Users/test/Desktop"), home: home) == .desktop)
        #expect(FileAccess.location(containing: URL(fileURLWithPath: "/Users/test/Downloads/big.zip"), home: home) == .downloads)
        // 저장에서 되살아난 URL은 끝에 슬래시가 붙는다 — `RootFolderViewModel.removeRoot` 주석 참고.
        #expect(FileAccess.location(containing: URL(fileURLWithPath: "/Users/test/Documents/"), home: home) == .documents)
        // 이름만 비슷한 형제 폴더는 아니다.
        #expect(FileAccess.location(containing: URL(fileURLWithPath: "/Users/test/Documents2"), home: home) == nil)
        #expect(FileAccess.location(containing: URL(fileURLWithPath: "/Users/test/Projects"), home: home) == nil)
    }

    @Test("/Volumes 아래는 외장 볼륨이다")
    func locatesVolumes() {
        #expect(FileAccess.location(containing: URL(fileURLWithPath: "/Volumes/SSD/Dev"), home: home) == .externalVolumes)
    }

    @Test("문서·다운로드는 늘 묻고, 데스크탑·외장 볼륨은 실제 경로가 있을 때만 묻는다")
    func requestsOnlyWhatIsUsed() {
        let none = FileAccess.locationsToRequest(roots: [], scanPaths: [], home: home)
        #expect(none == [.documents, .downloads])

        let withDesktop = FileAccess.locationsToRequest(
            roots: [URL(fileURLWithPath: "/Users/test/Desktop/Work")], scanPaths: [], home: home
        )
        #expect(withDesktop == [.documents, .desktop, .downloads])

        let withVolume = FileAccess.locationsToRequest(
            roots: [], scanPaths: [URL(fileURLWithPath: "/Volumes/SSD/DerivedData")], home: home
        )
        #expect(withVolume == [.documents, .downloads, .externalVolumes])
    }
}

// MARK: - 뷰모델

@MainActor
@Suite("파일 접근 권한 뷰모델")
struct FileAccessViewModelTests {
    /// 백그라운드 Task에서 불리므로 락으로 보호한다.
    private final class ProbeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var probed: [ProtectedLocation] = []

        func record(_ location: ProtectedLocation) {
            lock.lock()
            probed.append(location)
            lock.unlock()
        }

        var locations: [ProtectedLocation] {
            lock.lock()
            defer { lock.unlock() }
            return probed
        }
    }

    @Test("한 번에 요청하면 위치마다 읽어 보고 상태를 채운다")
    func requestAllProbesEveryLocation() async {
        let recorder = ProbeRecorder()
        let viewModel = FileAccessViewModel(
            probe: { location in
                recorder.record(location)
                return location == .desktop ? .denied : .granted
            },
            checkFullDiskAccess: { false },
            openSettings: { _ in },
            observesActivation: false
        )

        viewModel.requestAll()
        #expect(viewModel.isRequesting)
        #expect(await waitUntil { !viewModel.isRequesting })

        #expect(recorder.locations == ProtectedLocation.allCases)
        #expect(viewModel.states[.desktop] == .denied)
        #expect(viewModel.states[.documents] == .granted)
        #expect(viewModel.hasFullDiskAccess == false)
    }

    @Test("전체 디스크 접근이 있으면 읽어 보지 않고 전부 허용으로 표시한다")
    func fullDiskAccessSkipsProbing() async {
        let recorder = ProbeRecorder()
        let viewModel = FileAccessViewModel(
            probe: { location in
                recorder.record(location)
                return .denied
            },
            checkFullDiskAccess: { true },
            openSettings: { _ in },
            observesActivation: false
        )

        viewModel.requestAtLaunch(roots: [])
        #expect(await waitUntil { !viewModel.isRequesting })

        #expect(recorder.locations.isEmpty)
        #expect(viewModel.hasFullDiskAccess == true)
        #expect(ProtectedLocation.allCases.allSatisfy { viewModel.states[$0] == .granted })
    }

    @Test("시스템 설정 버튼은 해당 화면 주소를 연다")
    func opensSettingsPanes() {
        final class Opened { var urls: [URL] = [] }
        let opened = Opened()
        let viewModel = FileAccessViewModel(
            probe: { _ in .unknown },
            checkFullDiskAccess: { false },
            openSettings: { opened.urls.append($0) },
            observesActivation: false
        )

        viewModel.openFullDiskAccessSettings()
        viewModel.openFilesAndFoldersSettings()
        #expect(opened.urls == [FileAccess.fullDiskAccessSettingsURL, FileAccess.filesAndFoldersSettingsURL])
    }
}
