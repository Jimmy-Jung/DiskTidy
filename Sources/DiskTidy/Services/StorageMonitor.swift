import Foundation

@MainActor
final class StorageMonitor: ObservableObject {
    @Published var snapshot: StorageSnapshot?

    private var timer: Timer?

    init(refreshInterval: TimeInterval = 60) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    func refresh() {
        snapshot = StorageInfo.current()
    }

    var percentUsedText: String {
        guard let snapshot else { return "…" }
        return "\(Int(snapshot.usedFraction * 100))%"
    }
}
