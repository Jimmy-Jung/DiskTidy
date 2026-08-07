import Foundation

struct SimulatorItem: Identifiable, Hashable {
    let id: String // UDID
    let name: String
    let runtime: String
    let state: String
    var sizeBytes: Int64
    var lastUsed: Date?
    var isSelected: Bool = false

    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var lastUsedString: String {
        guard let d = lastUsed else { return "알 수 없음" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
