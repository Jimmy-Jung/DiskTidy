import Foundation
import Testing

@testable import DiskTidy

@Suite("StorageSnapshot")
struct StorageSnapshotTests {
    @Test("사용량과 사용률을 계산한다")
    func computesUsage() {
        let snapshot = StorageSnapshot(totalBytes: 1000, availableBytes: 250)
        #expect(snapshot.usedBytes == 750)
        #expect(snapshot.usedFraction == 0.75)
    }

    @Test("전체 용량이 0이면 0으로 나누지 않는다")
    func guardsAgainstZeroTotal() {
        #expect(StorageSnapshot(totalBytes: 0, availableBytes: 0).usedFraction == 0)
    }
}

@Suite("RootFolderStore 루트 검증")
struct RootFolderRejectionTests {
    @Test("범위가 너무 넓은 경로를 거부한다", arguments: [
        "/", "/Users", "/System", "/Volumes", "/Applications",
    ])
    func rejectsBroadPaths(path: String) {
        let reason = RootFolderStore.rejectionReason(for: URL(fileURLWithPath: path), existing: [])
        #expect(reason == .tooBroad)
    }

    @Test("홈 디렉터리 자체를 거부한다")
    func rejectsHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(RootFolderStore.rejectionReason(for: home, existing: []) == .tooBroad)
    }

    @Test("중복 추가를 거부한다")
    func rejectsDuplicate() {
        let url = URL(fileURLWithPath: "/Users/dev/Projects")
        #expect(RootFolderStore.rejectionReason(for: url, existing: [url]) == .alreadyAdded)
    }

    @Test("정상 폴더는 통과시킨다")
    func acceptsNormalFolder() {
        let url = URL(fileURLWithPath: "/Users/dev/Projects")
        #expect(RootFolderStore.rejectionReason(for: url, existing: []) == nil)
    }
}

@Suite("실패 메시지")
struct FailureMessageTests {
    @Test("실패가 없으면 메시지를 만들지 않는다")
    func noMessageWhenNothingFailed() {
        #expect(CleanableListViewModel.failureMessage(failedCount: 0) == nil)
        #expect(SimulatorViewModel.failureMessage(failedCount: 0, verb: "삭제") == nil)
    }

    @Test("실패 건수를 메시지에 담는다")
    func includesFailedCount() {
        #expect(CleanableListViewModel.failureMessage(failedCount: 3)?.contains("3개") == true)
        #expect(SimulatorViewModel.failureMessage(failedCount: 2, verb: "초기화")?.contains("2개") == true)
        #expect(SimulatorViewModel.failureMessage(failedCount: 2, verb: "초기화")?.contains("초기화") == true)
    }
}

@Suite("CleanableItem 표시 형식")
struct CleanableItemFormattingTests {
    @Test("수정일이 없으면 nil을 준다")
    func nilDateGivesNilString() {
        let item = CleanableItem(name: "x", path: URL(fileURLWithPath: "/tmp/x"), sizeBytes: 0)
        #expect(item.modifiedDateString == nil)
    }

    @Test("수정일을 yyyy-MM-dd로 만든다")
    func formatsDate() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 7
        let date = Calendar.current.date(from: components)!
        let item = CleanableItem(
            name: "x", path: URL(fileURLWithPath: "/tmp/x"), sizeBytes: 0, modifiedDate: date)
        #expect(item.modifiedDateString == "2026-08-07")
    }
}
