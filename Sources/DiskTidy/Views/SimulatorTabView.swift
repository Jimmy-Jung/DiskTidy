import SwiftUI

struct SimulatorTabView: View {
    @StateObject private var viewModel = SimulatorViewModel()
    @State private var showDeleteConfirm = false
    @State private var showEraseConfirm = false

    private var selectedCount: Int { viewModel.selectedItems.count }
    private var isWorking: Bool { viewModel.isScanning || viewModel.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("시뮬레이터").font(.title2.bold())
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("새로고침") { viewModel.refresh() }
                    .disabled(isWorking)
            }

            Text("마지막 사용일 오름차순 정렬 (오래 방치된 기기가 위)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = viewModel.errorMessage {
                ErrorBanner(message: message) { viewModel.errorMessage = nil }
            }

            List {
                ForEach($viewModel.items) { $item in
                    HStack {
                        Toggle(isOn: $item.isSelected) { EmptyView() }
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text("\(item.runtime) · \(item.state)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(item.sizeString).monospacedDigit()
                            Text(item.lastUsedString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                Button("전체 선택") { viewModel.selectAll(true) }
                Button("전체 해제") { viewModel.selectAll(false) }
                Spacer()
                Text("선택: \(selectedCount)개, \(ByteCountFormatter.string(fromByteCount: viewModel.selectedBytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
                Button("데이터 초기화", role: .destructive) { showEraseConfirm = true }
                    .disabled(selectedCount == 0 || isWorking)
                Button("기기 삭제", role: .destructive) { showDeleteConfirm = true }
                    .disabled(selectedCount == 0 || isWorking)
            }
        }
        .padding()
        .onAppear {
            if viewModel.items.isEmpty { viewModel.refresh() }
        }
        // simctl delete/erase는 휴지통을 거치지 않는 되돌릴 수 없는 작업이라 확인을 받는다.
        .confirmationDialog(
            "선택한 \(selectedCount)개 기기를 완전히 삭제합니다. 되돌릴 수 없습니다.",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) { viewModel.deleteSelected() }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog(
            "선택한 \(selectedCount)개 기기의 앱/데이터를 초기화합니다. 되돌릴 수 없습니다.",
            isPresented: $showEraseConfirm,
            titleVisibility: .visible
        ) {
            Button("초기화", role: .destructive) { viewModel.eraseSelected() }
            Button("취소", role: .cancel) {}
        }
    }
}
