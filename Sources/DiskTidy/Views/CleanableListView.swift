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
                    }
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
