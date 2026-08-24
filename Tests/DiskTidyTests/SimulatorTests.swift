import Foundation
import Testing

@testable import DiskTidy

// MARK: - SimulatorManager.parseDevices

@Suite("SimulatorManager.parseDevices")
struct SimulatorParseTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    @Test("런타임별 기기를 평탄화하고 런타임 이름을 다듬는다")
    func flattensDevicesWithReadableRuntime() {
        let entries = SimulatorManager.parseDevices(data("""
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            {"udid": "UDID-A", "name": "iPhone 17", "state": "Shutdown", "isAvailable": true}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
            {"udid": "UDID-B", "name": "Watch Ultra", "state": "Booted", "isAvailable": true}
          ]
        }}
        """))

        let byUDID = Dictionary(uniqueKeysWithValues: entries.map { ($0.udid, $0) })
        #expect(entries.count == 2)
        #expect(byUDID["UDID-A"]?.runtime == "iOS 26.5")
        #expect(byUDID["UDID-A"]?.name == "iPhone 17")
        #expect(byUDID["UDID-B"]?.runtime == "watchOS 11.0")
        #expect(byUDID["UDID-B"]?.state == "Booted")
    }

    @Test("isAvailable=false인 고아 기기는 뺀다")
    func dropsUnavailableDevices() {
        let entries = SimulatorManager.parseDevices(data("""
        {"devices": {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            {"udid": "UDID-A", "name": "살아있음", "state": "Shutdown", "isAvailable": true},
            {"udid": "UDID-B", "name": "고아", "state": "Shutdown", "isAvailable": false}
          ]
        }}
        """))

        // 실체가 없어 삭제도 안 되는 기기를 목록에 두면 사용자가 계속 실패를 본다.
        #expect(entries.map(\.udid) == ["UDID-A"])
    }

    @Test("isAvailable 키가 없으면 사용 가능으로 본다")
    func treatsMissingAvailabilityAsAvailable() {
        let entries = SimulatorManager.parseDevices(data("""
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-5":
          [{"udid": "UDID-A", "name": "iPhone 17", "state": "Shutdown"}]}}
        """))

        #expect(entries.map(\.udid) == ["UDID-A"])
    }

    @Test("깨진 JSON은 빈 배열을 준다", arguments: ["", "not json", "{}", #"{"devices": 3}"#])
    func malformedJSONGivesEmpty(json: String) {
        #expect(SimulatorManager.parseDevices(data(json)).isEmpty)
    }

    @Test("기본 기기 경로는 CoreSimulator/Devices다")
    func defaultDevicesRootPath() {
        #expect(
            SimulatorManager.defaultDevicesRoot.path
                .hasSuffix("/Library/Developer/CoreSimulator/Devices")
        )
    }
}

// MARK: - simctl 연동

/// 실제 `xcrun simctl`을 부르지만 부작용이 없는 입력만 쓴다.
/// 전부 0인 UDID는 어떤 기기와도 겹치지 않고, Xcode가 없는 환경에서는 실패로 떨어진다.
@Suite("simctl 연동")
struct SimctlIntegrationTests {
    private let nonexistentUDID = "00000000-0000-0000-0000-000000000000"

    @Test("xcrun 래퍼가 명령을 전달한다")
    func runXcrunPassesArguments() {
        let result = ShellRunner.runXcrun(["--help"])
        #expect(result.exitCode != -1) // /usr/bin/xcrun 실행 자체는 성공
    }

    @Test("없는 UDID 삭제는 실패로 돌아온다")
    func deletingUnknownDeviceFails() {
        #expect(!SimulatorManager.deleteDevice(nonexistentUDID))
    }

    @Test("없는 UDID 초기화는 실패로 돌아온다")
    func erasingUnknownDeviceFails() {
        #expect(!SimulatorManager.eraseDevice(nonexistentUDID))
    }

    @Test("기기 목록 조회는 항상 온전한 항목만 준다")
    func listDevicesReturnsWellFormedItems() {
        // simctl이 없거나 기기가 없으면 빈 배열이어야지 깨진 항목이 나오면 안 된다.
        for item in SimulatorManager.listDevices() {
            #expect(!item.id.isEmpty)
            #expect(!item.runtime.isEmpty)
            #expect(item.sizeBytes >= 0)
        }
    }
}

// MARK: - SimulatorManager.makeItems

@Suite("SimulatorManager.makeItems")
struct SimulatorMakeItemsTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    private func entry(_ udid: String) -> SimulatorEntry {
        SimulatorEntry(udid: udid, name: "기기 \(udid)", runtime: "iOS 26.5", state: "Shutdown")
    }

    @Test("Preferences 수정일을 마지막 사용 시각으로 삼고 오름차순 정렬한다")
    func usesPreferencesDateAndSortsOldestFirst() throws {
        let root = try temp.makeDirectory("Devices")
        let old = try temp.makeDirectory("Devices/OLD/data/Library/Preferences")
        let recent = try temp.makeDirectory("Devices/RECENT/data/Library/Preferences")
        try temp.setModificationDate(Date(timeIntervalSince1970: 1_600_000_000), of: old)
        try temp.setModificationDate(Date(timeIntervalSince1970: 1_700_000_000), of: recent)

        let items = SimulatorManager.makeItems(
            from: [entry("RECENT"), entry("OLD")], devicesRoot: root
        )

        // 오래 방치된 기기가 위로 와야 정리 대상을 바로 고를 수 있다.
        #expect(items.map(\.id) == ["OLD", "RECENT"])
    }

    @Test("Preferences가 없으면 기기 폴더 수정일로 물러난다")
    func fallsBackToDeviceDirectoryDate() throws {
        let root = try temp.makeDirectory("Devices")
        let device = try temp.makeDirectory("Devices/NEVER-BOOTED")
        let stamp = Date(timeIntervalSince1970: 1_650_000_000)
        try temp.setModificationDate(stamp, of: device)

        let items = SimulatorManager.makeItems(from: [entry("NEVER-BOOTED")], devicesRoot: root)

        let lastUsed = try #require(items.first?.lastUsed)
        #expect(abs(lastUsed.timeIntervalSince(stamp)) < 1)
    }

    @Test("기기 폴더가 없으면 크기 0에 마지막 사용 시각은 알 수 없음이다")
    func missingDeviceDirectoryGivesZeroSize() throws {
        let root = try temp.makeDirectory("Devices")

        let item = try #require(
            SimulatorManager.makeItems(from: [entry("GHOST")], devicesRoot: root).first
        )

        #expect(item.sizeBytes == 0)
        #expect(item.lastUsed == nil)
        #expect(item.lastUsedString == "알 수 없음")
    }

    @Test("기기 폴더 크기를 바이트로 채운다")
    func fillsDeviceSize() throws {
        let root = try temp.makeDirectory("Devices")
        try temp.makeFile("Devices/BIG/data.img", bytes: 128 * 1024)

        let item = try #require(
            SimulatorManager.makeItems(from: [entry("BIG")], devicesRoot: root).first
        )

        #expect(item.sizeBytes >= 128 * 1024)
        #expect(!item.sizeString.isEmpty)
    }
}

// MARK: - SimulatorManager.testDeviceSummary

@Suite("SimulatorManager.testDeviceSummary")
struct TestDeviceSummaryTests {
    private let temp: TempDirectory

    init() throws { temp = try TempDirectory() }

    @Test("클론 개수·합계 크기·가장 최근 수정일을 요약한다")
    func summarizesClones() throws {
        let root = try temp.makeDirectory("XCTestDevices")
        let old = try temp.makeDirectory("XCTestDevices/UUID-OLD")
        try temp.makeFile("XCTestDevices/UUID-NEW/data.img", bytes: 64 * 1024)
        let newDir = root.appendingPathComponent("UUID-NEW")
        try temp.setModificationDate(Date(timeIntervalSince1970: 1_600_000_000), of: old)
        let recent = Date(timeIntervalSince1970: 1_700_000_000)
        try temp.setModificationDate(recent, of: newDir)

        let summary = SimulatorManager.testDeviceSummary(root: root)

        #expect(summary.count == 2)
        #expect(summary.sizeBytes >= 64 * 1024)
        let lastUsed = try #require(summary.lastUsed)
        #expect(abs(lastUsed.timeIntervalSince(recent)) < 1)
    }

    @Test("클론 디렉터리가 없으면 0개·0바이트다")
    func emptyRootGivesZero() throws {
        let root = try temp.makeDirectory("XCTestDevices")

        let summary = SimulatorManager.testDeviceSummary(root: root)

        #expect(summary == TestDeviceSummary(count: 0, sizeBytes: 0, lastUsed: nil))
    }

    @Test("루트 자체가 없어도 0개다 (병렬 테스트를 한 번도 안 돌린 환경)")
    func missingRootGivesZero() {
        let summary = SimulatorManager.testDeviceSummary(
            root: temp.url.appendingPathComponent("nope")
        )

        #expect(summary.count == 0)
        #expect(summary.sizeBytes == 0)
    }

    @Test("파일은 세지 않는다 — 클론은 항상 디렉터리다")
    func ignoresLooseFiles() throws {
        let root = try temp.makeDirectory("XCTestDevices")
        try temp.makeFile("XCTestDevices/stray.plist", bytes: 1024)

        #expect(SimulatorManager.testDeviceSummary(root: root).count == 0)
    }
}

// MARK: - RuntimeManager

@Suite("RuntimeManager")
struct RuntimeManagerTests {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    /// `simctl runtime list -j` 실측 스키마 (Xcode 26).
    private let realShapeJSON = """
    {
      "AAAA": {
        "build": "23F77", "deletable": true, "identifier": "AAAA",
        "kind": "Patchable Cryptex Disk Image", "lastUsedAt": "2026-08-24T02:35:34Z",
        "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        "sizeBytes": 8494282293, "state": "Ready", "version": "26.5"
      },
      "BBBB": {
        "build": "23D8133", "deletable": true, "identifier": "BBBB",
        "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-3",
        "sizeBytes": 8000000000, "state": "Ready", "version": "26.3.1"
      },
      "CCCC": {
        "build": "22S99", "deletable": false, "identifier": "CCCC",
        "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.watchOS-11-0",
        "sizeBytes": 4000000000, "state": "Ready", "version": "11.0"
      }
    }
    """

    @Test("실측 스키마를 파싱하고 플랫폼별 새 버전을 위로 정렬한다")
    func parsesRealShape() {
        let items = RuntimeManager.parseRuntimes(data(realShapeJSON))

        #expect(items.map(\.id) == ["AAAA", "BBBB", "CCCC"])
        #expect(items[0].displayName == "iOS 26.5 (23F77)")
        #expect(items[0].sizeBytes == 8_494_282_293)
        #expect(items[0].lastUsed != nil)
        #expect(items[1].lastUsed == nil) // lastUsedAt 없는 레코드
        #expect(items[2].platform == "watchOS")
        #expect(!items[2].deletable)
    }

    @Test("같은 플랫폼의 구버전만 superseded로 표시한다")
    func marksOlderVersionsOnly() {
        let items = RuntimeManager.markSuperseded(
            RuntimeManager.parseRuntimes(data(realShapeJSON))
        )
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        // "26.3.1" vs "26.5"는 자릿수가 달라 문자열 비교로는 26.3.1이 크다.
        // 숫자 비교가 아니면 여기서 뒤집힌다.
        #expect(byID["AAAA"]?.isSuperseded == false)
        #expect(byID["BBBB"]?.isSuperseded == true)
        #expect(byID["CCCC"]?.isSuperseded == false) // watchOS 유일 버전
    }

    @Test("깨진 JSON은 빈 배열을 준다", arguments: ["", "not json", #"{"AAAA": 3}"#])
    func malformedJSONGivesEmpty(json: String) {
        #expect(RuntimeManager.parseRuntimes(data(json)).isEmpty)
    }

    @Test("없는 런타임 삭제는 실패로 돌아온다")
    func deletingUnknownRuntimeFails() {
        #expect(!RuntimeManager.deleteRuntime("00000000-0000-0000-0000-000000000000"))
    }
}

// MARK: - SimulatorViewModel

@Suite("SimulatorViewModel")
@MainActor
struct SimulatorViewModelTests {
    private func item(_ udid: String, bytes: Int64 = 1024, selected: Bool = false) -> SimulatorItem {
        SimulatorItem(
            id: udid,
            name: "기기 \(udid)",
            runtime: "iOS 26.5",
            state: "Shutdown",
            sizeBytes: bytes,
            lastUsed: nil,
            isSelected: selected
        )
    }

    /// 기본 클로저는 실제 xcrun을 부른다. 단위 테스트는 전부 스텁으로 막는다.
    private func makeViewModel(
        list: @escaping @Sendable () -> [SimulatorItem] = { [] },
        delete: @escaping @Sendable (String) -> Bool = { _ in true },
        erase: @escaping @Sendable (String) -> Bool = { _ in true },
        summarizeTestDevices: @escaping @Sendable () -> TestDeviceSummary = {
            TestDeviceSummary(count: 0, sizeBytes: 0, lastUsed: nil)
        },
        deleteAllTestDevices: @escaping @Sendable () -> Bool = { true },
        listRuntimes: @escaping @Sendable () -> [RuntimeItem] = { [] },
        deleteRuntime: @escaping @Sendable (String) -> Bool = { _ in true }
    ) -> SimulatorViewModel {
        SimulatorViewModel(
            list: list,
            delete: delete,
            erase: erase,
            shutdownAll: { true },
            summarizeTestDevices: summarizeTestDevices,
            deleteAllTestDevices: deleteAllTestDevices,
            listRuntimes: listRuntimes,
            deleteRuntime: deleteRuntime
        )
    }

    @Test("목록·테스트 클론 요약·런타임을 채우고 진행 플래그를 되돌린다")
    func refreshFillsItems() async {
        let scanned = [item("A"), item("B")]
        let summary = TestDeviceSummary(count: 3, sizeBytes: 1024, lastUsed: nil)
        let runtime = RuntimeItem(
            id: "R1", platform: "iOS", version: "26.5", build: "23F77",
            state: "Ready", deletable: true, sizeBytes: 8_000, lastUsed: nil
        )
        let viewModel = makeViewModel(
            list: { scanned },
            summarizeTestDevices: { summary },
            listRuntimes: { [runtime] }
        )

        viewModel.refresh()

        #expect(await waitUntil { !viewModel.isScanning })
        #expect(viewModel.items.map(\.id) == ["A", "B"])
        #expect(viewModel.testSummary == summary)
        #expect(viewModel.runtimes.map(\.id) == ["R1"])
    }

    @Test("선택한 기기만 삭제하고 목록을 다시 읽는다")
    func deletesSelectedThenRefreshes() async {
        let simctl = SimctlRecorder()
        let viewModel = makeViewModel(delete: { simctl.perform($0) })
        viewModel.items = [item("A", selected: true), item("B"), item("C", selected: true)]

        viewModel.deleteSelected()

        #expect(await waitUntil { !viewModel.isBusy && viewModel.items.isEmpty })
        #expect(simctl.calledUDIDs == ["A", "C"])
        #expect(viewModel.errorMessage == nil)
    }

    @Test("초기화 실패 건수를 동사와 함께 알린다")
    func reportsEraseFailures() async {
        let simctl = SimctlRecorder(failingUDIDs: ["A"])
        let viewModel = makeViewModel(erase: { simctl.perform($0) })
        viewModel.items = [item("A", selected: true), item("B", selected: true)]

        viewModel.eraseSelected()

        #expect(await waitUntil { !viewModel.isBusy })
        #expect(simctl.calledUDIDs.sorted() == ["A", "B"])
        #expect(viewModel.errorMessage?.contains("1개") == true)
        #expect(viewModel.errorMessage?.contains("초기화") == true)
    }

    @Test("선택이 없으면 simctl을 부르지 않는다")
    func noSelectionIsNoOp() {
        let simctl = SimctlRecorder()
        let viewModel = makeViewModel(delete: { simctl.perform($0) })
        viewModel.items = [item("A")]

        viewModel.deleteSelected()

        #expect(!viewModel.isBusy)
        #expect(simctl.calledUDIDs.isEmpty)
    }

    @Test("선택 합계와 전체 선택·해제가 맞물린다")
    func selectionAggregates() {
        let viewModel = makeViewModel()
        viewModel.items = [item("A", bytes: 100), item("B", bytes: 250)]

        viewModel.selectAll(true)
        #expect(viewModel.selectedItems.count == 2)
        #expect(viewModel.selectedBytes == 350)

        viewModel.selectAll(false)
        #expect(viewModel.selectedBytes == 0)
    }

    @Test("테스트 클론 전체 삭제 후 목록을 다시 읽는다")
    func deletesTestClonesThenRefreshes() async {
        let called = SimctlRecorder()
        let viewModel = makeViewModel(deleteAllTestDevices: { called.perform("all") })
        viewModel.testSummary = TestDeviceSummary(count: 5, sizeBytes: 1024, lastUsed: nil)

        viewModel.deleteTestClones()

        #expect(await waitUntil { !viewModel.isBusy && !viewModel.isScanning })
        #expect(called.calledUDIDs == ["all"])
        #expect(viewModel.errorMessage == nil)
    }

    @Test("테스트 클론이 0개면 삭제를 부르지 않는다")
    func emptyTestClonesIsNoOp() {
        let called = SimctlRecorder()
        let viewModel = makeViewModel(deleteAllTestDevices: { called.perform("all") })
        viewModel.testSummary = TestDeviceSummary(count: 0, sizeBytes: 0, lastUsed: nil)

        viewModel.deleteTestClones()

        #expect(!viewModel.isBusy)
        #expect(called.calledUDIDs.isEmpty)
    }

    @Test("테스트 클론 삭제 실패를 배너로 알린다")
    func reportsTestCloneFailure() async {
        let viewModel = makeViewModel(deleteAllTestDevices: { false })
        viewModel.testSummary = TestDeviceSummary(count: 5, sizeBytes: 1024, lastUsed: nil)

        viewModel.deleteTestClones()

        #expect(await waitUntil { !viewModel.isBusy })
        #expect(viewModel.errorMessage?.contains("테스트 클론") == true)
    }

    @Test("런타임 삭제는 해당 ID로 부르고 목록을 다시 읽는다")
    func deletesRuntimeByID() async {
        let called = SimctlRecorder()
        let viewModel = makeViewModel(deleteRuntime: { called.perform($0) })

        viewModel.deleteRuntime(id: "RUNTIME-1")

        #expect(await waitUntil { !viewModel.isBusy && !viewModel.isScanning })
        #expect(called.calledUDIDs == ["RUNTIME-1"])
        #expect(viewModel.errorMessage == nil)
    }

    @Test("런타임 삭제 실패를 배너로 알린다")
    func reportsRuntimeFailure() async {
        let viewModel = makeViewModel(deleteRuntime: { _ in false })

        viewModel.deleteRuntime(id: "RUNTIME-1")

        #expect(await waitUntil { !viewModel.isBusy })
        #expect(viewModel.errorMessage?.contains("런타임") == true)
    }
}
