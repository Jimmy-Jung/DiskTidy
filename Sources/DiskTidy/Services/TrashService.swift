import Foundation
import os

enum TrashService {
    private static let logger = Logger(subsystem: "com.jimmy.disktidy", category: "trash")

    /// 성공 여부를 반드시 확인할 것. 실패를 무시하면 목록에서는 사라졌는데
    /// 디스크 용량은 그대로인 상태가 되고, 사용자는 정리됐다고 오해한다.
    static func trash(_ url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            logger.error("휴지통 이동 실패 \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
