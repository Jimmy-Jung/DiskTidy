import SwiftUI

/// 메모리·스왑 지표와 개발 데몬 목록을 한 탭에 둔다.
///
/// `purge`는 실행하지 않는다 (권한 다이얼로그를 띄우고 회수량이 사실상 0). 스왑 섹션은
/// **읽기 전용 관측값**이라 삭제 버튼이 없다. RAM을 실제로 되찾는 건 프로세스 종료뿐이다.
struct MemoryTabView: View {
    // 창 수명 동안 유지되는 인스턴스를 주입받는다 — `TabViewModels` 참고.
    @ObservedObject var viewModel: MemoryViewModel
    @State private var isConfirmingTermination = false

    private var terminableCount: Int { viewModel.terminableSelection.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("개발 데몬 정리").font(.title2.bold())
                Spacer()
                if viewModel.isWorking { ProgressView().controlSize(.small) }
                Button("새로고침") { viewModel.refreshAll() }
                    .disabled(viewModel.isWorking)
            }

            MemoryMetricsSection(state: viewModel.memory)
            SwapSection(
                swap: viewModel.swap,
                swapFileBytes: viewModel.swapFileBytes,
                showsNotice: viewModel.showsSwapFileNotice
            )

            Divider()

            Text("장기 실행 개발 데몬만 종료할 수 있습니다. 진행 중인 빌드·인덱싱·시뮬레이터는 상태만 표시합니다. 메모리 사용량은 RSS 근사치로, 회수량이 아니라 크기 비교용입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = viewModel.errorMessage {
                ErrorBanner(message: message) { viewModel.errorMessage = nil }
            }

            if viewModel.processes.isEmpty && !viewModel.isWorking {
                Text("표시할 개발 프로세스가 없습니다.").foregroundStyle(.secondary)
            }

            ProcessList(viewModel: viewModel)

            if let summary = viewModel.terminationSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("전체 선택") { viewModel.selectAll(true) }
                Button("전체 해제") { viewModel.selectAll(false) }
                Spacer()
                Text("선택: \(viewModel.selectedCount)개 (종료 가능 \(terminableCount)개)")
                    .foregroundStyle(.secondary)
                // 이 버튼은 확인 상태만 연다. 실제 시그널은 다이얼로그의 확인 액션에서만 보낸다.
                Button("데몬 종료", role: .destructive) {
                    viewModel.isConfirming = true
                    isConfirmingTermination = true
                }
                .disabled(terminableCount == 0 || viewModel.isWorking)
            }
        }
        .padding()
        .confirmationDialog(
            "선택한 \(terminableCount)개 개발 데몬을 종료합니다. 저장하지 않은 작업이 사라지며 되돌릴 수 없습니다.",
            isPresented: $isConfirmingTermination,
            titleVisibility: .visible
        ) {
            Button("\(terminableCount)개 종료", role: .destructive) {
                viewModel.isConfirming = false
                viewModel.terminateSelected()
            }
            Button("취소", role: .cancel) { viewModel.isConfirming = false }
        } message: {
            Text(confirmationDetail)
        }
        // 재진입 시 이전 결과를 그대로 보여 주면서 뒤에서 다시 스캔한다.
        // 폴링 타이머는 탭이 보이는 동안만 돈다 — `startPolling()` 주석 참고.
        .onAppearDeferred {
            viewModel.refreshAll()
            viewModel.startPolling()
        }
        .onDisappear { viewModel.stopPolling() }
        .screenContext("개발 데몬 정리") { [viewModel] in
            ScreenContextBuilder.memory(viewModel: viewModel)
        }
    }

    /// 확인창에 대상 identity 스냅샷을 그대로 보여 준다. 이름만 보이면 PID가 재사용된
    /// 다른 프로세스를 승인할 수 있다.
    private var confirmationDetail: String {
        viewModel.terminableSelection
            .map { "PID \($0.identity.pid) · \($0.kind.label) · \($0.identity.executablePath)" }
            .joined(separator: "\n")
    }
}

// MARK: - 지표

private struct MemoryMetricsSection: View {
    let state: Result<MemorySnapshot, MemoryInfo.Error>?

    var body: some View {
        switch state {
        case .none:
            Text("메모리 지표를 읽는 중…").font(.caption).foregroundStyle(.secondary)
        case .failure(let error):
            // 실패를 0으로 표시하면 "압박 없음"으로 읽힌다.
            Text("메모리 지표 측정 불가 (\(String(describing: error)))")
                .font(.caption)
                .foregroundStyle(.orange)
        case .success(let snapshot):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("메모리 압박: \(snapshot.pressure.label)")
                        .foregroundStyle(pressureColor(snapshot.pressure))
                        .bold()
                    Spacer()
                    Text("여유 \(Int(snapshot.freeFraction * 100))% / 총 \(format(snapshot.totalBytes))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 16) {
                    metric("앱", snapshot.appBytes)
                    metric("통합(Wired)", snapshot.wiredBytes)
                    metric("압축됨", snapshot.compressedBytes)
                    metric("캐시된 파일", snapshot.cachedBytes)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ label: String, _ bytes: Int64) -> some View {
        Text("\(label) \(format(bytes))").monospacedDigit()
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }

    private func pressureColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }
}

/// 스왑은 표시만 한다. 삭제 버튼을 만들지 않는다 — `swapfile*`은 OS가 관리하고,
/// 사용 중 삭제는 시스템을 불안정하게 만든다.
private struct SwapSection: View {
    let swap: Result<SwapSnapshot, MemoryInfo.Error>?
    let swapFileBytes: Result<Int64, MemoryInfo.Error>?
    let showsNotice: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("스왑").bold()
                Spacer()
                Text(swapText).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(swapFileText).font(.caption).foregroundStyle(.secondary)

            if showsNotice {
                Text("프로세스 종료 후에도 여유 용량이 바로 늘지 않을 수 있습니다. 상태가 지속되면 재시동을 고려하세요.")
                    .font(.caption)
                    .padding(6)
                    .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var swapText: String {
        switch swap {
        case .none: return "읽는 중…"
        case .failure: return "측정 불가"
        case .success(let snapshot):
            return "\(format(snapshot.usedBytes)) 사용 / \(format(snapshot.totalBytes))"
        }
    }

    private var swapFileText: String {
        switch swapFileBytes {
        case .none: return "스왑 파일 크기를 읽는 중…"
        case .failure: return "스왑 파일 크기 측정 불가 (읽기 전용 관측값)"
        case .success(let bytes):
            // 현재 할당량이다. 회수 가능 용량으로 읽히지 않게 문구를 고정한다.
            return "스왑 파일 현재 할당 \(format(bytes)) — 회수 가능 용량이 아닙니다."
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - 프로세스 목록

private struct ProcessList: View {
    @ObservedObject var viewModel: MemoryViewModel

    /// 행마다 `Date()`를 부르지 않는다. 목록은 5초마다 다시 그려지므로 그 시점 하나로 충분하다.
    private var now: Date { Date() }

    /// "활동 중"은 초록, 유휴는 회색. 관찰 기반 값이라 탭을 처음 열면 "관찰 중"부터 시작한다.
    @ViewBuilder
    private func activityBadge(_ activity: ProcessActivity?) -> some View {
        let text = activity?.statusString(now: now) ?? "관찰 전"
        Text(text)
            .font(.caption)
            .foregroundStyle(activity?.isActiveNow == true ? Color.green : Color.secondary)
    }

    var body: some View {
        List {
            // 인덱스 바인딩(`ForEach($processes)`)은 목록이 줄면 죽는다 — `Binding.field` 주석 참고.
            ForEach(viewModel.processes) { process in
                HStack {
                    // 종료할 수 없는 항목에는 체크박스를 열지 않는다.
                    Toggle(isOn: $viewModel.processes.field(\.isSelected, id: process.id, default: false)) {
                        EmptyView()
                    }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(!process.isTerminable)

                    VStack(alignment: .leading) {
                        Text("\(process.displayName) · PID \(process.identity.pid)")
                        Text("\(process.kind.label) · \(process.isTerminable ? "종료 가능" : "표시만")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // 시작 시각·CPU·띄운 앱. "며칠째 떠 있는 데몬"과 "누가 띄웠나"가 종료 판단의 근거다.
                        Text(process.detailLine(now: now))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(process.residentString).monospacedDigit()
                        activityBadge(process.activity)
                    }
                    ExplanationButton(
                        subject: ExplanationSubject(
                            // PID는 재시작하면 바뀐다. 이름과 분류로 캐시해야 같은 데몬을
                            // 다시 물어보지 않는다.
                            key: "process:\(process.kind.label):\(process.displayName)",
                            title: process.displayName,
                            subtitle: "PID \(process.identity.pid) · \(process.kind.label)",
                            facts: [
                                "항목: 실행 중인 프로세스 \(process.displayName)",
                                "분류: \(process.kind.label)",
                                "메모리(RSS 근사치): \(process.residentString)",
                                process.detailLine(now: now),
                                "활동: \(process.activity?.statusString(now: now) ?? "관찰 전")",
                                process.isTerminable
                                    ? "이 화면의 정리 방식: SIGTERM·SIGKILL로 종료 (되돌릴 수 없음, 도구가 다시 띄울 수 있음)"
                                    : "이 화면에서는 종료할 수 없고 표시만 한다",
                            ],
                            // 이름이 곧 정체인 데몬은 앱이 안다. AI에게 물을 이유가 없다.
                            knownDescription: KnownItemCatalog.description(
                                forProcessNamed: process.displayName
                            )
                        ),
                        screenTitle: "개발 데몬"
                    )
                }
            }
        }
    }
}
