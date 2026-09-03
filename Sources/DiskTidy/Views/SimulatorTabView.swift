import AppKit
import SwiftUI

struct SimulatorTabView: View {
    // 창 수명 동안 유지되는 인스턴스를 주입받는다 — `TabViewModels` 참고.
    @ObservedObject var viewModel: SimulatorViewModel
    @State private var showDeleteConfirm = false
    @State private var showEraseConfirm = false
    @State private var showShutdownConfirm = false
    @State private var showTestCloneConfirm = false
    /// 삭제 확인을 기다리는 런타임. 다이얼로그가 뜬 사이 목록이 갱신될 수 있어
    /// 인덱스가 아니라 항목 자체를 붙잡는다.
    @State private var runtimePendingDelete: RuntimeItem?
    @State private var searchText = ""
    /// 기본은 마지막 사용 오름차순 — 오래 방치된 기기가 위로 온다(스캐너와 같은 순서).
    @State private var sort = ColumnSort<SortKey>(key: .lastUsed, isAscending: true)

    private enum SortKey { case name, runtime, lastUsed, size }

    private var selectedCount: Int { viewModel.selectedItems.count }

    /// 검색으로 걸러 정렬한 목록. 선택 바인딩은 여전히 `viewModel.items`를 id로 찾는다.
    private var visibleItems: [SimulatorItem] {
        let filtered = viewModel.items.filter { item in
            searchText.isEmpty
                || item.name.localizedStandardContains(searchText)
                || item.runtime.localizedStandardContains(searchText)
        }
        return filtered.sorted(ascending: sort.isAscending) { lhs, rhs in
            switch sort.key {
            case .name: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .runtime: return lhs.runtime.localizedStandardCompare(rhs.runtime) == .orderedAscending
            case .lastUsed: return (lhs.lastUsed ?? .distantPast) < (rhs.lastUsed ?? .distantPast)
            case .size: return lhs.sizeBytes < rhs.sizeBytes
            }
        }
    }
    private var isWorking: Bool { viewModel.isScanning || viewModel.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TabHeader(
                title: "시뮬레이터",
                isWorking: isWorking,
                summary: SelectionSummary.text(
                    selectedCount: selectedCount,
                    selectedBytes: viewModel.selectedBytes,
                    totalCount: viewModel.items.count,
                    totalBytes: viewModel.items.reduce(0) { $0 + $1.sizeBytes }
                ),
                search: $searchText,
                refresh: { viewModel.refresh() }
            ) {
                // 선택과 무관하게 부팅된 기기 전체가 대상이라 선택 개수로 비활성하지 않는다.
                // 파괴적 액션이 아니므로 주황 강조도 하지 않는다.
                Button("모두 종료") { showShutdownConfirm = true }
                    .disabled(isWorking)
                ListActionButton(
                    title: "데이터 초기화",
                    systemImage: "arrow.counterclockwise",
                    isPrimary: false,
                    isEnabled: selectedCount > 0 && !isWorking
                ) {
                    showEraseConfirm = true
                }
                ListActionButton(
                    title: "기기 삭제",
                    systemImage: "trash",
                    isEnabled: selectedCount > 0 && !isWorking
                ) {
                    showDeleteConfirm = true
                }
            }

            Text("기본 정렬은 마지막 사용 오름차순 — 오래 방치된 기기가 위. 열 제목을 눌러 바꿉니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = viewModel.errorMessage {
                ErrorBanner(message: message) { viewModel.errorMessage = nil }
            }

            if let summary = viewModel.testSummary {
                testCloneCard(summary)
            }

            if !viewModel.runtimes.isEmpty {
                runtimeSection
            }

            // 빈 목록에도 `List`를 그리면 화면이 빈 사각형으로 덮인다 — `CleanableListView` 주석 참고.
            if viewModel.items.isEmpty && !isWorking {
                Text("시뮬레이터 기기가 없습니다.").foregroundStyle(.secondary)
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
                        title: "기기", isActive: sort.key == .name, isAscending: sort.isAscending
                    ) { sort.select(.name, ascendingFirst: true) }
                    Spacer(minLength: 8)
                    SortableColumnLabel(
                        title: "런타임 · 상태",
                        isActive: sort.key == .runtime,
                        isAscending: sort.isAscending
                    ) { sort.select(.runtime, ascendingFirst: true) }
                        .frame(width: ListColumn.detail, alignment: .leading)
                    SortableColumnLabel(
                        title: "마지막 사용",
                        isActive: sort.key == .lastUsed,
                        isAscending: sort.isAscending
                    ) { sort.select(.lastUsed, ascendingFirst: true) }
                        .frame(width: ListColumn.date, alignment: .trailing)
                    SortableColumnLabel(
                        title: "크기", isActive: sort.key == .size, isAscending: sort.isAscending
                    ) { sort.select(.size, ascendingFirst: false) }
                        .frame(width: ListColumn.size, alignment: .trailing)
                    Spacer().frame(width: ListColumn.info)
                } rows: {
                    // 인덱스 바인딩(`ForEach($items)`)은 스캔 결과로 배열이 줄면 죽는다 — `Binding.field` 주석 참고.
                    ForEach(visibleItems) { item in
                        HStack(spacing: 8) {
                            Toggle(isOn: $viewModel.items.field(\.isSelected, id: item.id, default: false)) {
                                EmptyView()
                            }
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .frame(width: ListColumn.checkbox, alignment: .leading)
                            Text(item.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text("\(item.runtime) · \(item.state)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: ListColumn.detail, alignment: .leading)
                            Text(item.lastUsedString)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: ListColumn.date, alignment: .trailing)
                            Text(item.sizeString)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: ListColumn.size, alignment: .trailing)
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
                                    ],
                                    // 시뮬레이터 기기가 무엇인지는 앱이 안다. 물어볼 이유가 없다.
                                    knownDescription: """
                                    Xcode가 만든 iOS 시뮬레이터 기기입니다. 그 기기에 설치한 앱과 앱 \
                                    데이터, 로그인 상태, 스크린샷·로그가 들어 있습니다. 삭제는 \
                                    `simctl delete`로 즉시 지우며 휴지통을 거치지 않습니다 — 기기는 \
                                    Xcode에서 다시 만들 수 있지만 안에 있던 데이터는 돌아오지 않습니다.
                                    """
                                ),
                                screenTitle: "시뮬레이터"
                            )
                            .frame(width: ListColumn.info, alignment: .trailing)
                        }
                        .listRowAlignedWithHeader()
                        .contextMenu {
                            // 기기에는 경로가 없다. 지원 요청·스크립트에 붙일 UDID를 준다.
                            Button("UDID 복사") { Clipboard.copy(item.id) }
                        }
                    }
                }
            }
        }
        .padding()
        // 재진입 시 이전 결과를 그대로 보여 주면서 뒤에서 다시 스캔한다.
        .onAppearDeferred { viewModel.refresh() }
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
        .confirmationDialog(
            "테스트 클론 \(viewModel.testSummary?.count ?? 0)개를 모두 삭제합니다. "
                + "되돌릴 수 없지만 다음 병렬 테스트에서 자동으로 다시 만들어집니다.",
            isPresented: $showTestCloneConfirm,
            titleVisibility: .visible
        ) {
            Button("전체 삭제", role: .destructive) { viewModel.deleteTestClones() }
            Button("취소", role: .cancel) {}
        }
        .confirmationDialog(
            "\(runtimePendingDelete?.displayName ?? "") 런타임을 삭제합니다. "
                + "이 런타임의 시뮬레이터 기기들은 사용할 수 없게 됩니다.",
            isPresented: Binding(
                get: { runtimePendingDelete != nil },
                set: { if !$0 { runtimePendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let runtime = runtimePendingDelete { viewModel.deleteRuntime(id: runtime.id) }
                runtimePendingDelete = nil
            }
            Button("취소", role: .cancel) {}
        }
    }

    /// 검색으로 걸러 본 상태에서는 **보이는 기기만** 선택·해제한다.
    private func select(_ isSelected: Bool) {
        viewModel.selectAll(isSelected, ids: Set(visibleItems.map(\.id)))
    }

    /// 병렬 테스트 클론 요약 카드. 기기 이름이 전부 UUID라 목록 대신 합계만 보여 준다.
    private func testCloneCard(_ summary: TestDeviceSummary) -> some View {
        GroupBox {
            HStack {
                VStack(alignment: .leading) {
                    Text("테스트 클론 (병렬 테스트가 만든 임시 기기)")
                    Text(
                        summary.count == 0
                            ? "없음 — 병렬 테스트를 돌리면 여기에 쌓입니다"
                            : "\(summary.count)개 · 마지막 사용 \(Self.dateString(summary.lastUsed))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(summary.sizeString).monospacedDigit()
                ExplanationButton(
                    subject: ExplanationSubject(
                        key: "simulator:test-clones",
                        title: "테스트 클론",
                        subtitle: "XCTestDevices",
                        facts: [
                            "항목: 병렬 테스트용 시뮬레이터 클론 \(summary.count)개",
                            "크기: \(summary.sizeString)",
                            "위치: ~/Library/Developer/XCTestDevices",
                            "이 화면의 정리 방식: simctl --set testing delete all (되돌릴 수 없음)",
                        ],
                        knownDescription: """
                        Xcode가 병렬 테스트를 돌릴 때 만드는 시뮬레이터 복제본입니다. 테스트가 \
                        끝나도 자동으로 지워지지 않아 수백 GB까지 쌓일 수 있습니다. 지워도 됩니다 — \
                        다음 병렬 테스트에서 필요한 만큼 다시 만들어집니다.
                        """
                    ),
                    screenTitle: "시뮬레이터"
                )
                Button("전체 삭제", role: .destructive) { showTestCloneConfirm = true }
                    .disabled(summary.count == 0 || isWorking)
            }
        }
    }

    /// 설치된 런타임 디스크 이미지. 몇 개 안 되므로 List 대신 고정 행으로 그린다.
    private var runtimeSection: some View {
        GroupBox {
            VStack(spacing: 6) {
                ForEach(viewModel.runtimes) { runtime in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(runtime.displayName)
                            Text(runtime.state)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if runtime.isSuperseded {
                            Text("구버전")
                                .font(.caption.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.2), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Text(runtime.sizeString).monospacedDigit()
                        ExplanationButton(
                            subject: ExplanationSubject(
                                key: "runtime:\(runtime.displayName)",
                                title: runtime.displayName,
                                subtitle: "시뮬레이터 런타임",
                                facts: [
                                    "항목: 시뮬레이터 런타임 \(runtime.displayName)",
                                    "크기: \(runtime.sizeString)",
                                    "상태: \(runtime.state)",
                                    runtime.isSuperseded
                                        ? "같은 플랫폼에 더 새 버전이 설치되어 있음"
                                        : "이 플랫폼의 최신 설치 버전",
                                    "이 화면의 정리 방식: simctl runtime delete (되돌릴 수 없음)",
                                ],
                                knownDescription: """
                                시뮬레이터가 부팅할 때 쓰는 OS 디스크 이미지입니다. 지우면 이 버전의 \
                                시뮬레이터 기기를 쓸 수 없게 되지만, Xcode 설정 > Components에서 \
                                다시 내려받을 수 있습니다. 같은 플랫폼의 더 새 버전이 있다면 구버전은 \
                                대개 지워도 됩니다.
                                """
                            ),
                            screenTitle: "시뮬레이터"
                        )
                        Button("삭제", role: .destructive) { runtimePendingDelete = runtime }
                            .disabled(!runtime.deletable || isWorking)
                    }
                }
            }
        } label: {
            Text("런타임 (OS 디스크 이미지)")
        }
    }

    private static func dateString(_ date: Date?) -> String {
        guard let date else { return "알 수 없음" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
