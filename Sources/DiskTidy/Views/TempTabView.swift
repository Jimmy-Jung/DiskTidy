import AppKit
import SwiftUI

/// 기존 캐시 탭의 배치만 작게 따르되 `TempCleanupViewModel` 전용으로 구성한다.
/// `CleanableListView`를 범용화하면 identity 없는 `CleanableItem`까지
/// 완전 삭제 계약에 섞이므로 재사용하지 않는다.
struct TempTabView: View {
    // 창 수명 동안 유지되는 인스턴스를 주입받는다 — `TabViewModels` 참고.
    @ObservedObject var viewModel: TempCleanupViewModel
    @State private var isConfirmingDelete = false
    @State private var searchText = ""
    /// 스캐너가 크기 내림차순으로 주므로 그 순서를 기본값으로 둔다. 정렬은 그룹 안에서만 일어난다.
    @State private var sort = ColumnSort<SortKey>(key: .size, isAscending: false)

    enum SortKey { case name, modified, size }

    private var selectedCount: Int { viewModel.selectedItems.count }
    private var selectedInUseCount: Int { viewModel.selectedItems.filter(\.isInUse).count }

    /// 검색으로 걸러 남은 항목. 선택·전체 선택·머리글 상태는 모두 이 목록을 기준으로 센다.
    private var visibleItems: [TempCandidate] {
        viewModel.items.filter { item in
            searchText.isEmpty
                || item.name.localizedStandardContains(searchText)
                || item.path.path.localizedStandardContains(searchText)
                || item.evidence.localizedStandardContains(searchText)
        }
    }

    private var selectableCount: Int { visibleItems.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabHeader(
                title: "임시파일",
                isWorking: viewModel.isWorking,
                summary: summaryText,
                search: $searchText,
                refresh: { viewModel.refresh() }
            ) {
                if viewModel.deletionProgress == nil {
                    // 이 버튼은 확인 상태만 연다. 실제 삭제는 다이얼로그의 확인 액션에서만 부른다.
                    ListActionButton(
                        title: "완전 삭제",
                        systemImage: "trash.slash",
                        isEnabled: selectedCount > 0 && !viewModel.isWorking
                    ) {
                        isConfirmingDelete = true
                    }
                } else {
                    // 이미 지운 항목은 돌아오지 않는다. 취소는 남은 항목만 건너뛴다.
                    ListActionButton(
                        title: "취소",
                        systemImage: "xmark.circle",
                        isPrimary: false,
                        isEnabled: true
                    ) {
                        viewModel.cancelDeletion()
                    }
                }
            }

            Text(
                "/private/tmp과 $TMPDIR의 내 소유 임시 항목을 검사합니다. "
                    + "Claude·Codex 작업물은 세션이 끝났거나 빌드가 멈춘 뒤 30분 넘게 변경이 없으면, "
                    + "그 밖의 항목은 24시간 넘게 읽지도 쓰지도 않았을 때 후보가 됩니다. "
                    + "사용 중인 작업물도 경고와 함께 표시하며 선택해 강제 삭제할 수 있습니다."
            )
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = viewModel.errorMessage {
                ErrorBanner(message: message) { viewModel.errorMessage = nil }
            }

            if !viewModel.pendingRecoveries.isEmpty {
                QuarantineRecoveryList(viewModel: viewModel)
            }

            // 빈 목록에도 `List`를 그리면 안내 문구 아래로 빈 사각형이 화면을 다 먹는다 —
            // `CleanableListView` 주석 참고.
            if viewModel.items.isEmpty && !viewModel.isWorking {
                Text("항목 없음").foregroundStyle(.secondary)
                Spacer()
            } else {
                HeaderedList(
                    selection: SelectionState(
                        selected: visibleItems.filter(\.isSelected).count,
                        selectable: selectableCount
                    ),
                    isEnabled: selectableCount > 0,
                    onToggle: { select($0) }
                ) {
                    SortableColumnLabel(
                        title: "이름 · 판정",
                        isActive: sort.key == .name,
                        isAscending: sort.isAscending
                    ) { sort.select(.name, ascendingFirst: true) }
                    Spacer(minLength: 8)
                    SortableColumnLabel(
                        title: "수정", isActive: sort.key == .modified, isAscending: sort.isAscending
                    ) { sort.select(.modified, ascendingFirst: false) }
                        .frame(width: ListColumn.time, alignment: .trailing)
                    Spacer().frame(width: ListColumn.share)
                    SortableColumnLabel(
                        title: "크기", isActive: sort.key == .size, isAscending: sort.isAscending
                    ) { sort.select(.size, ascendingFirst: false) }
                        .frame(width: ListColumn.size, alignment: .trailing)
                    Spacer().frame(width: ListColumn.info)
                } rows: {
                    TempCandidateRows(viewModel: viewModel, items: visibleItems, sort: sort)
                }
            }

            if let summary = viewModel.deletionSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .confirmationDialog(
            selectedInUseCount > 0
                ? "사용 중인 임시파일을 강제로 삭제하시겠습니까?"
                : "선택한 항목을 완전히 삭제하시겠습니까?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(
                selectedInUseCount > 0 ? "\(selectedCount)개 강제 삭제" : "\(selectedCount)개 완전 삭제",
                role: .destructive
            ) {
                viewModel.deleteSelected(allowInUse: selectedInUseCount > 0)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(
                selectedInUseCount > 0
                    ? "선택 항목 중 \(selectedInUseCount)개가 사용 중입니다. 삭제하면 실행 중인 세션이나 빌드가 실패할 수 있으며 되돌릴 수 없습니다."
                    : "휴지통을 거치지 않으며 되돌릴 수 없습니다."
            )
        }
        // 재진입 시 이전 결과를 그대로 보여 주면서 뒤에서 다시 스캔한다.
        .onAppearDeferred { viewModel.refresh() }
        .screenContext("임시파일") { [viewModel] in
            ScreenContextBuilder.temp(viewModel: viewModel)
        }
    }

    /// 검색으로 걸러 본 상태에서는 **보이는 항목만** 선택·해제한다.
    private func select(_ isSelected: Bool) {
        viewModel.selectAll(isSelected, ids: Set(visibleItems.map(\.id)))
    }

    /// 삭제 중에는 진행률이 요약 자리를 차지한다.
    private var summaryText: String? {
        if let progress = viewModel.deletionProgress {
            return "삭제 중 \(progress.done)/\(progress.total)"
        }
        return SelectionSummary.text(
            selectedCount: selectedCount,
            selectedBytes: viewModel.selectedBytes,
            totalCount: viewModel.items.count,
            totalBytes: viewModel.items.reduce(0) { $0 + $1.sizeBytes }
        )
    }
}

/// 출처별 섹션과 행. `HeaderedList`의 `List` 안에 그대로 들어간다.
private struct TempCandidateRows: View {
    @ObservedObject var viewModel: TempCleanupViewModel
    /// 검색으로 걸러 남은 항목. 선택 바인딩은 여전히 `viewModel.items`를 id로 찾는다.
    let items: [TempCandidate]
    let sort: ColumnSort<TempTabView.SortKey>

    /// 비중 막대의 기준. 그룹이 아니라 화면 전체의 최대 크기로 잡아야 그룹끼리 비교된다.
    private var maxBytes: Int64 { items.map(\.sizeBytes).max() ?? 0 }

    /// 출처별로 묶는다. 에이전트 작업물이 tmp의 대부분이라 그 그룹이 위에 온다.
    /// `claudeSession`은 세션마다 값이 달라 kind가 아니라 group으로 묶는다.
    /// 정렬은 그룹 안에서만 한다 — 그룹 순서는 위험도 순이라 사용자가 바꿀 값이 아니다.
    private var groups: [(group: TempCandidateGroup, items: [TempCandidate])] {
        let byGroup = Dictionary(grouping: items) { $0.kind.group }
        return TempCandidateGroup.allCases.compactMap { group in
            byGroup[group].map { (group, sorted($0)) }
        }
    }

    private func sorted(_ candidates: [TempCandidate]) -> [TempCandidate] {
        candidates.sorted(ascending: sort.isAscending) { lhs, rhs in
            switch sort.key {
            case .name: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .modified: return lhs.modifiedDate < rhs.modifiedDate
            case .size: return lhs.sizeBytes < rhs.sizeBytes
            }
        }
    }

    var body: some View {
        // 인덱스 바인딩(`ForEach($items)`)은 스캔 결과로 배열이 줄면 죽는다 — `Binding.field` 주석 참고.
        ForEach(groups, id: \.group) { section in
            Section(section.group.label) {
                ForEach(section.items) { item in
                    row(item, group: section.group)
                }
            }
        }
    }

    private func row(_ item: TempCandidate, group: TempCandidateGroup) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: $viewModel.items.field(\.isSelected, id: item.id, default: false)) {
                EmptyView()
            }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("\(item.name) 선택\(item.isInUse ? ", 사용 중 경고" : "")")
                .frame(width: ListColumn.checkbox, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path.path)
                // 판정 근거는 한 줄로 길어서 열로 세우면 잘린다. 이름 아래에 둔다.
                Text(item.evidence)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(item.isInUse ? Color.orange : Color.secondary)
            }
            Spacer(minLength: 8)
            Text(item.modifiedTimeString)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: ListColumn.time, alignment: .trailing)
            ShareBar(fraction: maxBytes > 0 ? Double(item.sizeBytes) / Double(maxBytes) : 0)
            Text(item.sizeString)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: ListColumn.size, alignment: .trailing)
            ExplanationButton(
                subject: ExplanationSubject(
                    key: "temp:\(item.path.path)",
                    title: item.name,
                    subtitle: item.path.path,
                    facts: [
                        "항목: \(item.name)",
                        "경로: \(item.path.path)",
                        "출처: \(group.label)",
                        "판정: \(item.evidence)",
                        "크기: \(item.sizeString)",
                        "마지막 수정: \(item.modifiedTimeString)",
                        "이 화면의 정리 방식: 완전 삭제 (휴지통을 거치지 않음, 되돌릴 수 없음)",
                    ],
                    knownDescription: KnownItemCatalog.description(for: item.path)
                ),
                screenTitle: "임시파일"
            )
            .frame(width: ListColumn.info, alignment: .trailing)
        }
        .listRowAlignedWithHeader()
        .contextMenu {
            Button("Finder에서 보기") {
                NSWorkspace.shared.activateFileViewerSelecting([item.path])
            }
            Button("경로 복사") { Clipboard.copy(item.path.path) }
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
