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

    @Test("목록을 채우고 진행 플래그를 되돌린다")
    func refreshFillsItems() async {
        let scanned = [item("A"), item("B")]
        let viewModel = SimulatorViewModel(list: { scanned })

        viewModel.refresh()

        #expect(await waitUntil { !viewModel.isScanning })
        #expect(viewModel.items.map(\.id) == ["A", "B"])
    }

    @Test("선택한 기기만 삭제하고 목록을 다시 읽는다")
    func deletesSelectedThenRefreshes() async {
        let simctl = SimctlRecorder()
        let viewModel = SimulatorViewModel(list: { [] }, delete: { simctl.perform($0) })
        viewModel.items = [item("A", selected: true), item("B"), item("C", selected: true)]

        viewModel.deleteSelected()

        #expect(await waitUntil { !viewModel.isBusy && viewModel.items.isEmpty })
        #expect(simctl.calledUDIDs == ["A", "C"])
        #expect(viewModel.errorMessage == nil)
    }

    @Test("초기화 실패 건수를 동사와 함께 알린다")
    func reportsEraseFailures() async {
        let simctl = SimctlRecorder(failingUDIDs: ["A"])
        let viewModel = SimulatorViewModel(list: { [] }, erase: { simctl.perform($0) })
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
        let viewModel = SimulatorViewModel(list: { [] }, delete: { simctl.perform($0) })
        viewModel.items = [item("A")]

        viewModel.deleteSelected()

        #expect(!viewModel.isBusy)
        #expect(simctl.calledUDIDs.isEmpty)
    }

    @Test("선택 합계와 전체 선택·해제가 맞물린다")
    func selectionAggregates() {
        let viewModel = SimulatorViewModel(list: { [] })
        viewModel.items = [item("A", bytes: 100), item("B", bytes: 250)]

        viewModel.selectAll(true)
        #expect(viewModel.selectedItems.count == 2)
        #expect(viewModel.selectedBytes == 350)

        viewModel.selectAll(false)
        #expect(viewModel.selectedBytes == 0)
    }
}
