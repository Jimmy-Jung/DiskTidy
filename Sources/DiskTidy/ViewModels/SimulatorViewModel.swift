import Foundation

@MainActor
final class SimulatorViewModel: ObservableObject {
    @Published var items: [SimulatorItem] = []
    @Published var isScanning = false
    @Published var isBusy = false
    @Published var errorMessage: String?

    /// simctl 호출은 되돌릴 수 없다. 테스트가 실기기를 지우지 않도록 주입 가능하게 둔다.
    /// 정적 메서드 참조는 @Sendable로 추론되지 않아 캡처 없는 클로저 리터럴로 감싼다.
    private let list: @Sendable () -> [SimulatorItem]
    private let delete: @Sendable (String) -> Bool
    private let erase: @Sendable (String) -> Bool
    private let shutdownAllDevices: @Sendable () -> Bool

    init(
        list: @escaping @Sendable () -> [SimulatorItem] = { SimulatorManager.listDevices() },
        delete: @escaping @Sendable (String) -> Bool = { SimulatorManager.deleteDevice($0) },
        erase: @escaping @Sendable (String) -> Bool = { SimulatorManager.eraseDevice($0) },
        shutdownAll: @escaping @Sendable () -> Bool = { SimulatorManager.shutdownAll() }
    ) {
        self.list = list
        self.delete = delete
        self.erase = erase
        shutdownAllDevices = shutdownAll
    }

    var selectedItems: [SimulatorItem] { items.filter(\.isSelected) }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.sizeBytes } }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        let list = self.list
        Task {
            let scanned = await Task.detached(priority: .userInitiated) { list() }.value
            items = scanned
            isScanning = false
        }
    }

    func deleteSelected() {
        run(action: delete, verb: "삭제")
    }

    func eraseSelected() {
        run(action: erase, verb: "초기화")
    }

    func selectAll(_ isSelected: Bool) {
        for index in items.indices { items[index].isSelected = isSelected }
    }

    /// 부팅된 시뮬레이터를 모두 종료한다. 확인 다이얼로그를 거친 뒤에만 호출한다.
    /// `xcrun`은 수 초가 걸릴 수 있어 메인 액터 밖에서 실행한다.
    func shutdownAll() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil

        let shutdownAllDevices = self.shutdownAllDevices
        Task {
            let succeeded = await Task.detached(priority: .userInitiated) {
                shutdownAllDevices()
            }.value

            isBusy = false
            errorMessage = Self.shutdownFailureMessage(succeeded: succeeded)
            refresh()
        }
    }

    nonisolated static func shutdownFailureMessage(succeeded: Bool) -> String? {
        succeeded ? nil : "시뮬레이터를 종료하지 못했습니다. Xcode 명령줄 도구 설정을 확인하세요."
    }

    /// simctl은 부팅 중인 기기 등에서 실패한다. 종료 코드를 확인하지 않으면
    /// UI만 성공한 것처럼 보이고 다음 새로고침에 기기가 되살아난다.
    private func run(action: @escaping @Sendable (String) -> Bool, verb: String) {
        guard !isBusy else { return }
        let udids = selectedItems.map(\.id)
        guard !udids.isEmpty else { return }

        isBusy = true
        errorMessage = nil
        Task {
            let failedCount = await Task.detached(priority: .userInitiated) {
                udids.filter { !action($0) }.count
            }.value

            isBusy = false
            errorMessage = Self.failureMessage(failedCount: failedCount, verb: verb)
            refresh()
        }
    }

    nonisolated static func failureMessage(failedCount: Int, verb: String) -> String? {
        guard failedCount > 0 else { return nil }
        return "\(failedCount)개 기기를 \(verb)하지 못했습니다. 부팅 중인 시뮬레이터는 먼저 종료해야 합니다."
    }
}
