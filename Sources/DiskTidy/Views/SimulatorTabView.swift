import SwiftUI

struct SimulatorTabView: View {
    @StateObject private var viewModel = SimulatorViewModel()
    @State private var showDeleteConfirm = false
    @State private var showEraseConfirm = false
    @State private var showShutdownConfirm = false

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
                        ExplanationButton(
                            subject: ExplanationSubject(
                                // 이름만으로는 같은 기기가 런타임별로 여러 개일 수 있다.
                                key: "simulator:\(item.name):\(item.runtime)",
                                title: item.name,
                                subtitle: "\(item.runtime) · \(item.state)",
                                facts: [
                                    "항목: iOS 시뮬레이터 기기 \(item.name)",
                                    "런타임: \(item.runtime)",
                                    "상태: \(item.state)",
                                    "크기: \(item.sizeString)",
                                    "마지막 사용: \(item.lastUsedString)",
                                    "이 화면의 정리 방식: simctl delete로 완전 삭제 (되돌릴 수 없음)",
                                ]
                            ),
                            screenTitle: "시뮬레이터"
                        )
                    }
                }
            }

            HStack {
                Button("전체 선택") { viewModel.selectAll(true) }
                Button("전체 해제") { viewModel.selectAll(false) }
                // 선택과 무관하게 부팅된 기기 전체가 대상이라 선택 개수로 비활성하지 않는다.
                Button("모두 종료") { showShutdownConfirm = true }
                    .disabled(isWorking)
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
        .screenContext("시뮬레이터") { [viewModel] in
            ScreenContextBuilder.simulators(viewModel: viewModel)
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
        // 기기 데이터는 남지만 실행 중인 앱의 미저장 상태와 테스트는 끊긴다.
        .confirmationDialog(
            "모든 시뮬레이터를 종료합니다. 기기 데이터는 유지되지만 실행 중인 작업은 중단됩니다.",
            isPresented: $showShutdownConfirm,
            titleVisibility: .visible
        ) {
            Button("모두 종료", role: .destructive) { viewModel.shutdownAll() }
            Button("취소", role: .cancel) {}
        }
    }
}
