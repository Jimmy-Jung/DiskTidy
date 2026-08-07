import SwiftUI

/// 스캔 대상 폴더 추가/제거 UI. 프로젝트 캐시 탭과 대용량 파일 탭이 공유한다.
struct RootFolderPicker: View {
    @ObservedObject var viewModel: RootFolderViewModel
    let emptyHint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("스캔 대상 폴더").font(.headline)
                Spacer()
                Button("폴더 추가") { viewModel.addRoot() }
            }

            if let message = viewModel.errorMessage {
                ErrorBanner(message: message) { viewModel.errorMessage = nil }
            }

            if viewModel.roots.isEmpty {
                Text(emptyHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(viewModel.roots, id: \.self) { root in
                    HStack {
                        Text(root.path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("제거") { viewModel.removeRoot(root) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }
}
