import SwiftUI

/// 사이드바 맨 아래에 붙는 업데이트 버튼. 새 버전이 있을 때만 나타난다.
struct UpdateButton: View {
    @ObservedObject var viewModel: UpdateViewModel

    var body: some View {
        if viewModel.isButtonVisible {
            VStack(spacing: 0) {
                Divider()
                content
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .checking, .upToDate:
            // 최신이면 자리를 차지하지 않는다. `isButtonVisible`이 이미 걸러 낸다.
            EmptyView()

        case .available(let release):
            Button {
                Task { await viewModel.installUpdate() }
            } label: {
                Label("\(release.version.description) 업데이트", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("새 버전 \(release.version.description)을 내려받아 설치하고 앱을 다시 시작합니다")

        case .installing(let version):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(version.description) 설치 중…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .help("내려받아 체크섬을 확인한 뒤 앱을 교체합니다")

        case .restarting:
            Text("다시 시작 중…")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .failed(let message):
            Button {
                Task { await viewModel.checkForUpdate() }
            } label: {
                Label("업데이트 실패 — 다시 확인", systemImage: "exclamationmark.triangle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            // 사유를 버튼 안에 다 적을 수는 없다. 눌러서 다시 시도하고, 이유는 툴팁으로 본다.
            .help(message)
        }
    }
}
