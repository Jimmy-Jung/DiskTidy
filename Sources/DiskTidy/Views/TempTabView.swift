import AppKit
import SwiftUI

/// 기존 캐시 탭의 배치만 작게 따르되 `TempCleanupViewModel` 전용으로 구성한다.
/// `CleanableListView`를 범용화하면 identity 없는 `CleanableItem`까지
/// 완전 삭제 계약에 섞이므로 재사용하지 않는다.
struct TempTabView: View {
    // 창 수명 동안 유지되는 인스턴스를 주입받는다 — `TabViewModels` 참고.
    @ObservedObject var viewModel: TempCleanupViewModel
    @State private var isConfirmingDelete = false

    private var selectedCount: Int { viewModel.selectedItems.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("임시파일").font(.title2.bold())
                Spacer()
                if viewModel.isWorking { ProgressView().controlSize(.small) }
                Button("새로고침") { viewModel.refresh() }
                    .disabled(viewModel.isWorking)
            }

            Text("/private/tmp과 $TMPDIR의 최상위 항목 중 내 소유이고, 3일 넘게 읽지도 쓰지도 않았고, 열려 있지 않은 것만 보여 줍니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = viewModel.errorMessage {
                ErrorBanner(message: message) { viewModel.errorMessage = nil }
            }

            if !viewModel.pendingRecoveries.isEmpty {
                QuarantineRecoveryList(viewModel: viewModel)
            }

            if viewModel.items.isEmpty && !viewModel.isWorking {
                Text("항목 없음").foregroundStyle(.secondary)
            }

            TempCandidateList(viewModel: viewModel)

            if let summary = viewModel.deletionSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("전체 선택") { viewModel.selectAll(true) }
                Button("전체 해제") { viewModel.selectAll(false) }
                Spacer()
                Text("선택: \(selectedCount)개, \(ByteCountFormatter.string(fromByteCount: viewModel.selectedBytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
                // 이 버튼은 확인 상태만 연다. 실제 삭제는 다이얼로그의 확인 액션에서만 부른다.
                Button("완전 삭제", role: .destructive) { isConfirmingDelete = true }
                    .disabled(selectedCount == 0 || viewModel.isWorking)
            }
        }
        .padding()
        .confirmationDialog(
            "선택한 항목을 완전히 삭제합니다. 휴지통을 거치지 않으며 되돌릴 수 없습니다.",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("\(selectedCount)개 완전 삭제", role: .destructive) {
                viewModel.deleteSelected()
            }
            Button("취소", role: .cancel) {}
        }
        // 재진입 시 이전 결과를 그대로 보여 주면서 뒤에서 다시 스캔한다.
        .onAppearDeferred { viewModel.refresh() }
        .screenContext("임시파일") { [viewModel] in
            ScreenContextBuilder.temp(viewModel: viewModel)
        }
    }
}

private struct TempCandidateList: View {
    @ObservedObject var viewModel: TempCleanupViewModel

    var body: some View {
        List {
            // 인덱스 바인딩(`ForEach($items)`)은 스캔 결과로 배열이 줄면 죽는다 — `Binding.field` 주석 참고.
            ForEach(viewModel.items) { item in
                HStack {
                    Toggle(isOn: $viewModel.items.field(\.isSelected, id: item.id, default: false)) {
                        EmptyView()
                    }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    VStack(alignment: .leading) {
                        Text(item.name)
                        Text("수정: \(item.modifiedDateString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(item.sizeString)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    ExplanationButton(
                        subject: ExplanationSubject(
                            key: "temp:\(item.path.path)",
                            title: item.name,
                            subtitle: item.path.path,
                            facts: [
                                "항목: \(item.name)",
                                "경로: \(item.path.path)",
                                "크기: \(item.sizeString)",
                                "마지막 수정: \(item.modifiedDateString)",
                                "이 화면의 정리 방식: 완전 삭제 (휴지통을 거치지 않음, 되돌릴 수 없음)",
                            ]
                        ),
                        screenTitle: "임시파일"
                    )
                }
            }
        }
    }
}

/// 격리에 남은 항목은 일반 후보와 분리한다. 자동 삭제하지 않고
/// 원본·격리 경로와 복원·Finder 열기만 제공한다.
private struct QuarantineRecoveryList: View {
    @ObservedObject var viewModel: TempCleanupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("복구 대기 \(viewModel.pendingRecoveries.count)개")
                .font(.headline)
            Text("이전 삭제가 중단돼 격리에 남은 항목입니다. 자동으로 지우지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(viewModel.pendingRecoveries) { recovery in
                HStack {
                    VStack(alignment: .leading) {
                        Text(recovery.originalPath.isEmpty ? "원본 경로 미상" : recovery.originalPath)
                            .font(.caption)
                        Text("격리: \(recovery.quarantinedPath.path)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Finder에서 열기") {
                        NSWorkspace.shared.activateFileViewerSelecting([recovery.quarantinedPath])
                    }
                    Button("복원") { viewModel.restore(recovery.id) }
                        .disabled(recovery.originalPath.isEmpty || viewModel.isWorking)
                }
            }
        }
        .padding(8)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}
