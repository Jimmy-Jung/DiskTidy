import SwiftUI

struct CleanableListView: View {
    let title: String
    @ObservedObject var viewModel: CleanableListViewModel

    private var selectedCount: Int { viewModel.selectedItems.count }
    private var isWorking: Bool { viewModel.isScanning || viewModel.isDeleting }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("새로고침") { viewModel.refresh() }
                    .disabled(isWorking)
            }

            if let message = viewModel.errorMessage {
                ErrorBanner(message: message) { viewModel.errorMessage = nil }
            }

            if viewModel.items.isEmpty && !isWorking {
                Text("항목 없음").foregroundStyle(.secondary)
            }

            List {
                ForEach($viewModel.items) { $item in
                    CleanableItemRow(item: $item, screenTitle: title)
                }
            }

            HStack {
                Button("전체 선택") { viewModel.selectAll(true) }
                Button("전체 해제") { viewModel.selectAll(false) }
                Spacer()
                Text("선택: \(selectedCount)개, \(ByteCountFormatter.string(fromByteCount: viewModel.selectedBytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
                Button("휴지통으로 이동", role: .destructive) { viewModel.deleteSelected() }
                    .disabled(selectedCount == 0 || viewModel.isDeleting)
            }
        }
        .padding()
    }
}

/// 목록 한 줄. 오른쪽 `i` 버튼을 누르면 AI가 이 항목이 무엇인지 설명한다.
private struct CleanableItemRow: View {
    @Binding var item: CleanableItem
    let screenTitle: String

    var body: some View {
        HStack {
            Toggle(isOn: $item.isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading) {
                Text(item.name)
                if let dateString = item.modifiedDateString {
                    Text("수정: \(dateString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(item.sizeString)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            ExplanationButton(
                // 이 화면들의 삭제 버튼은 "휴지통으로 이동"이다. 되돌릴 수 있다는 사실을
                // 모델에게 알려 줘야 설명이 실제 위험도와 맞는다.
                subject: ExplanationSubject(item: item, action: "휴지통으로 이동 (되돌릴 수 있음)"),
                screenTitle: screenTitle
            )
        }
    }

}
