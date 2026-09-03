import AppKit
import SwiftUI

struct CleanableListView: View {
    let title: String
    @ObservedObject var viewModel: CleanableListViewModel

    /// 정렬 기준. 스캐너가 크기 내림차순으로 주므로 그 순서를 기본값으로 둔다.
    @State private var sort = ColumnSort<SortKey>(key: .size, isAscending: false)
    @State private var searchText = ""

    private enum SortKey { case name, date, size }

    private var selectedCount: Int { viewModel.selectedItems.count }
    private var isWorking: Bool { viewModel.isScanning || viewModel.isDeleting }

    /// 목록 최대 크기. 비중 막대의 기준이다.
    private var maxBytes: Int64 { viewModel.items.map(\.sizeBytes).max() ?? 0 }

    /// 정렬은 화면에서만 한다. 행 바인딩이 id 기반이라 순서가 바뀌어도 체크 상태가 따라간다 —
    /// `Binding.field` 주석 참고.
    private var visibleItems: [CleanableItem] {
        let filtered = viewModel.items.filter { item in
            searchText.isEmpty
                || item.name.localizedStandardContains(searchText)
                || item.path.path.localizedStandardContains(searchText)
        }
        return filtered.sorted(ascending: sort.isAscending) { lhs, rhs in
            switch sort.key {
            case .name: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .date: return (lhs.modifiedDate ?? .distantPast) < (rhs.modifiedDate ?? .distantPast)
            case .size: return lhs.sizeBytes < rhs.sizeBytes
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabHeader(
                title: title,
                isWorking: isWorking,
                summary: summaryText,
                search: $searchText,
                refresh: { viewModel.refresh() }
            ) {
                if viewModel.deletionProgress == nil {
                    ListActionButton(
                        title: "휴지통으로 이동",
                        systemImage: "trash",
                        isEnabled: selectedCount > 0 && !viewModel.isDeleting
                    ) {
                        viewModel.deleteSelected()
                    }
                } else {
                    // 삭제 중에는 같은 자리를 취소가 차지한다. 남은 항목만 건너뛴다.
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

            if let message = viewModel.errorMessage {
                ErrorBanner(message: message) { viewModel.errorMessage = nil }
            }

            // 빈 목록에도 `List`를 그리면 안내 문구 아래로 빈 사각형이 화면을 다 먹어
            // 탭 전체가 백지처럼 보인다. 비어 있을 때는 문구만 남긴다.
            if viewModel.items.isEmpty && !isWorking {
                Text(viewModel.emptyStateMessage)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                HeaderedList(
                    selection: SelectionState(
                        selected: visibleItems.filter(\.isSelected).count,
                        selectable: visibleItems.count
                    ),
                    isEnabled: !visibleItems.isEmpty,
                    onToggle: { select($0) }
                ) {
                    SortableColumnLabel(
                        title: "이름", isActive: sort.key == .name, isAscending: sort.isAscending
                    ) { sort.select(.name, ascendingFirst: true) }
                    Spacer(minLength: 8)
                    SortableColumnLabel(
                        title: "수정일", isActive: sort.key == .date, isAscending: sort.isAscending
                    ) { sort.select(.date, ascendingFirst: false) }
                        .frame(width: ListColumn.date, alignment: .trailing)
                    Spacer().frame(width: ListColumn.share)
                    SortableColumnLabel(
                        title: "크기", isActive: sort.key == .size, isAscending: sort.isAscending
                    ) { sort.select(.size, ascendingFirst: false) }
                        .frame(width: ListColumn.size, alignment: .trailing)
                    Spacer().frame(width: ListColumn.info)
                } rows: {
                    ForEach(visibleItems) { item in
                        CleanableItemRow(
                            item: item,
                            isSelected: $viewModel.items.field(\.isSelected, id: item.id, default: false),
                            screenTitle: title,
                            shareFraction: maxBytes > 0 ? Double(item.sizeBytes) / Double(maxBytes) : 0
                        )
                    }
                }
            }
        }
        .padding()
    }

    /// 검색으로 걸러 본 상태에서는 **보이는 항목만** 선택·해제한다.
    private func select(_ isSelected: Bool) {
        viewModel.selectAll(isSelected, ids: Set(visibleItems.map(\.id)))
    }

    /// 삭제 중에는 진행률이 요약 자리를 차지한다.
    private var summaryText: String? {
        if let progress = viewModel.deletionProgress {
            return "휴지통으로 이동 중 \(progress.done)/\(progress.total)"
        }
        return SelectionSummary.text(
            selectedCount: selectedCount,
            selectedBytes: viewModel.selectedBytes,
            totalCount: viewModel.items.count,
            totalBytes: viewModel.items.reduce(0) { $0 + $1.sizeBytes }
        )
    }
}

/// 목록 한 줄. 오른쪽 `i` 버튼을 누르면 AI가 이 항목이 무엇인지 설명한다.
private struct CleanableItemRow: View {
    let item: CleanableItem
    // 인덱스 바인딩(`ForEach($items)`) 대신 id로 찾는 바인딩을 받는다 — `Binding.field` 주석 참고.
    @Binding var isSelected: Bool
    let screenTitle: String
    let shareFraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: ListColumn.checkbox, alignment: .leading)
            // 이름만으로는 어느 폴더인지 모르는 항목이 많다. 전체 경로는 툴팁으로 준다.
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.path.path)
            Spacer(minLength: 8)
            Text(item.modifiedDateString ?? "—")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: ListColumn.date, alignment: .trailing)
            ShareBar(fraction: shareFraction)
            Text(item.sizeString)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: ListColumn.size, alignment: .trailing)
            ExplanationButton(
                // 이 화면들의 삭제 버튼은 "휴지통으로 이동"이다. 되돌릴 수 있다는 사실을
                // 모델에게 알려 줘야 설명이 실제 위험도와 맞는다.
                subject: ExplanationSubject(item: item, action: "휴지통으로 이동 (되돌릴 수 있음)"),
                screenTitle: screenTitle
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
