import SwiftUI

struct StorageTabView: View {
    // 앱 전역 StorageMonitor를 공유한다. 탭 전용 ViewModel을 따로 두면
    // 같은 값을 두 곳에서 각자 폴링하게 된다.
    @EnvironmentObject private var monitor: StorageMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SSD 용량").font(.title2.bold())

            if let snapshot = monitor.snapshot {
                Text("\(Int(snapshot.usedFraction * 100))% 사용 중")
                    .font(.title.bold())
                ProgressView(value: snapshot.usedFraction)
                    .padding(.vertical, 4)
                HStack {
                    Text("사용: \(ByteCountFormatter.string(fromByteCount: snapshot.usedBytes, countStyle: .file))")
                    Spacer()
                    Text("여유: \(ByteCountFormatter.string(fromByteCount: snapshot.availableBytes, countStyle: .file))")
                    Spacer()
                    Text("전체: \(ByteCountFormatter.string(fromByteCount: snapshot.totalBytes, countStyle: .file))")
                }
                .font(.callout.monospacedDigit())
            } else {
                Text("용량 정보를 읽을 수 없습니다.")
                    .foregroundStyle(.secondary)
            }

            Button("새로고침") { monitor.refresh() }

            Spacer()
        }
        .padding()
        .onAppear { monitor.refresh() }
        .screenContext("SSD 용량") { [monitor] in ScreenContextBuilder.storage(monitor: monitor) }
    }
}
