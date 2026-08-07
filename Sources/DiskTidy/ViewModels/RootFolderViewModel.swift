import AppKit
import Foundation

/// "스캔 대상 폴더" 목록 관리. 프로젝트 캐시 탭과 대용량 파일 탭이 공유한다.
@MainActor
final class RootFolderViewModel: ObservableObject {
    @Published private(set) var roots: [URL]
    @Published var errorMessage: String?

    private let storeKey: String

    init(storeKey: String, defaultRoots: [URL] = []) {
        self.storeKey = storeKey
        let loaded = RootFolderStore.load(key: storeKey)
        if loaded.isEmpty, !defaultRoots.isEmpty {
            roots = defaultRoots
            RootFolderStore.save(defaultRoots, key: storeKey)
        } else {
            roots = loaded
        }
    }

    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"

        // LSUIElement 앱은 활성화하지 않으면 패널이 다른 앱 뒤로 숨는다.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let reason = RootFolderStore.rejectionReason(for: url, existing: roots) {
            errorMessage = reason.message
            return
        }
        errorMessage = nil
        roots.append(url)
        RootFolderStore.save(roots, key: storeKey)
    }

    /// 저장에서 되살아난 URL은 끝 슬래시가 붙어 원본과 `==` 비교가 어긋난다.
    /// 표준화한 경로로 맞춰야 "제거"가 조용히 실패하지 않는다.
    func removeRoot(_ url: URL) {
        let target = url.standardizedFileURL.path
        roots.removeAll { $0.standardizedFileURL.path == target }
        RootFolderStore.save(roots, key: storeKey)
    }
}
