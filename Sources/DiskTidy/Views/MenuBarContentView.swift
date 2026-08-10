import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @EnvironmentObject private var storageMonitor: StorageMonitor
    @Environment(\.openWindow) private var openWindow

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

            Button("앱 열기") {
                openWindow(id: "main")
                WindowPresenter.present(alwaysOnTop: WindowPresenter.isAlwaysOnTopEnabled)
            }
            .buttonStyle(.plain)

            Button("종료") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 220)
        .onAppear { storageMonitor.refresh() }
    }
}
