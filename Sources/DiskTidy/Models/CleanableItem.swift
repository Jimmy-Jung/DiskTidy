import Foundation

struct CleanableItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: URL
    var sizeBytes: Int64
    var modifiedDate: Date? = nil
    var isSelected: Bool = false

    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var modifiedDateString: String? {
        guard let modifiedDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: modifiedDate)
    }
}
