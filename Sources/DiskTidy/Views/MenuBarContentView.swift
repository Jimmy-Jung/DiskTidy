import SwiftUI
import AppKit

struct MenuBarContentView: View {
    /// 메인 창을 띄운다. `openWindow`는 SwiftUI 씬 안에서만 읽을 수 있고 이 뷰는 AppKit 팝오버
    /// 안에서 살기 때문에 액션을 주입받는다 — `MenuBarController` 참고.
    let openApp: () -> Void
    let quit: () -> Void

    @EnvironmentObject private var storageMonitor: StorageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = storageMonitor.snapshot {
                ProgressView(value: snapshot.usedFraction)
                Text("여유 \(ByteCountFormatter.string(fromByteCount: snapshot.availableBytes, countStyle: .file)) / 전체 \(ByteCountFormatter.string(fromByteCount: snapshot.totalBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("불러오는 중…")
            }

            Divider()

            MenuRow(title: "앱 열기") {
                openApp()
                WindowPresenter.present(alwaysOnTop: WindowPresenter.isAlwaysOnTopEnabled)
            }

            MenuRow(title: "종료") { quit() }
        }
        .padding(12)
        .frame(width: 220)
        .onAppearDeferred { storageMonitor.refresh() }
    }
}

/// 메뉴 행. `.plain` 버튼의 히트 영역은 라벨 크기 그대로라 텍스트만 눌렸다 —
/// 라벨을 행 폭으로 늘리고 `contentShape`로 투명한 나머지 영역까지 클릭을 받는다.
/// 시스템 메뉴처럼 호버 중인 행은 강조색으로 칠해 지금 어디를 누를지 보여 준다.
private struct MenuRow: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(isHovered ? Color(nsColor: .selectedMenuItemTextColor) : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered ? Color.accentColor : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 텍스트는 다른 내용과 같은 x=12에 맞추고, 하이라이트만 좌우로 6pt 넓게 그린다 —
        // 시스템 메뉴가 텍스트보다 넓은 캡슐을 칠하는 것과 같은 모양이다.
        .padding(.horizontal, -6)
        .onHover { isHovered = $0 }
    }
}
