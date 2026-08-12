import Foundation

/// 각 탭의 ViewModel에서 챗봇에게 넘길 화면 스냅샷을 만든다.
///
/// 탭마다 상태 타입이 달라 하나의 프로토콜로 묶지 않는다. 대신 목록 표현(잘라내기·선택
/// 표시·합계)은 한 곳에 모아 탭 사이 문구가 어긋나지 않게 한다.
@MainActor
enum ScreenContextBuilder {
    // MARK: - SSD 용량

    static func storage(monitor: StorageMonitor) -> ScreenContext {
        guard let snapshot = monitor.snapshot else {
            return ScreenContext(title: "SSD 용량", lines: ["용량 정보를 읽지 못했습니다."])
        }
        return ScreenContext(
            title: "SSD 용량",
            lines: [
                "사용률: \(Int(snapshot.usedFraction * 100))%",
                "사용 \(format(snapshot.usedBytes)) / 여유 \(format(snapshot.availableBytes)) "
                    + "/ 전체 \(format(snapshot.totalBytes))",
            ]
        )
    }

    // MARK: - 휴지통 이동형 목록 탭 (캐시·Xcode·프로젝트·대용량·Android)

    static func cleanableList(
        title: String,
        viewModel: CleanableListViewModel,
        note: String? = nil
    ) -> ScreenContext {
        var lines: [String] = []
        if let note { lines.append(note) }
        lines.append("삭제 방식: 휴지통으로 이동 (되돌릴 수 있음)")

        if !viewModel.roots.isEmpty {
            lines.append("스캔 대상 폴더: " + viewModel.roots.map(\.path).joined(separator: ", "))
        } else if viewModel.requiresRoots {
            // 이걸 빼면 챗봇이 "캐시가 없습니다"라고 답한다. 사용자가 할 일은 폴더 추가다.
            lines.append("스캔 대상 폴더가 없어 목록이 비어 있습니다 — 사용자가 ‘폴더 추가’를 눌러야 합니다.")
        }
        if viewModel.isScanning { lines.append("상태: 스캔 중") }
        if viewModel.isDeleting { lines.append("상태: 삭제 중") }
        if let error = viewModel.errorMessage { lines.append("오류 배너: \(error)") }

        let totalBytes = viewModel.items.reduce(0) { $0 + $1.sizeBytes }
        lines.append("항목 \(viewModel.items.count)개, 합계 \(format(totalBytes))")
        lines.append("선택 \(viewModel.selectedItems.count)개, \(format(viewModel.selectedBytes))")
        lines += itemLines(
            viewModel.items.map {
                Row(
                    name: $0.name,
                    sizeBytes: $0.sizeBytes,
                    detail: $0.modifiedDateString.map { "수정 \($0)" },
                    isSelected: $0.isSelected
                )
            }
        )
        return ScreenContext(title: title, lines: lines)
    }

    // MARK: - 시뮬레이터

    static func simulators(viewModel: SimulatorViewModel) -> ScreenContext {
        var lines = [
            "삭제 방식: simctl 직접 삭제/초기화 (되돌릴 수 없음)",
            "정렬: 마지막 사용일 오름차순 (오래 방치된 기기가 위)",
        ]
        if viewModel.isScanning { lines.append("상태: 스캔 중") }
        if viewModel.isBusy { lines.append("상태: simctl 작업 중") }
        if let error = viewModel.errorMessage { lines.append("오류 배너: \(error)") }

        let totalBytes = viewModel.items.reduce(0) { $0 + $1.sizeBytes }
        lines.append("기기 \(viewModel.items.count)개, 합계 \(format(totalBytes))")
        lines.append("선택 \(viewModel.selectedItems.count)개, \(format(viewModel.selectedBytes))")
        lines += itemLines(
            viewModel.items.map {
                Row(
                    name: $0.name,
                    sizeBytes: $0.sizeBytes,
                    detail: "\($0.runtime) · \($0.state) · 마지막 사용 \($0.lastUsedString)",
                    isSelected: $0.isSelected
                )
            }
        )
        return ScreenContext(title: "시뮬레이터", lines: lines)
    }

    // MARK: - 임시파일

    static func temp(viewModel: TempCleanupViewModel) -> ScreenContext {
        var lines = [
            "삭제 방식: 완전 삭제 (휴지통을 거치지 않으며 되돌릴 수 없음)",
            "후보 조건: /private/tmp과 $TMPDIR의 최상위 항목 중 내 소유, 3일 이상 미접근, 열려 있지 않음",
        ]
        if viewModel.isScanning { lines.append("상태: 스캔 중") }
        if viewModel.isDeleting { lines.append("상태: 삭제 중") }
        if let error = viewModel.errorMessage { lines.append("오류 배너: \(error)") }
        if let summary = viewModel.deletionSummary { lines.append("직전 삭제 요약: \(summary)") }
        if !viewModel.pendingRecoveries.isEmpty {
            lines.append("복구 대기 \(viewModel.pendingRecoveries.count)개 (격리에 남은 항목)")
        }

        let totalBytes = viewModel.items.reduce(0) { $0 + $1.sizeBytes }
        lines.append("항목 \(viewModel.items.count)개, 합계 \(format(totalBytes))")
        lines.append("선택 \(viewModel.selectedItems.count)개, \(format(viewModel.selectedBytes))")
        lines += itemLines(
            viewModel.items.map {
                Row(
                    name: $0.name,
                    sizeBytes: $0.sizeBytes,
                    detail: "수정 \($0.modifiedDateString)",
                    isSelected: $0.isSelected
                )
            }
        )
        return ScreenContext(title: "임시파일", lines: lines)
    }

    // MARK: - 개발 데몬

    static func memory(viewModel: MemoryViewModel) -> ScreenContext {
        var lines = [
            "동작: 선택한 개발 데몬에 종료 시그널 전송 (되돌릴 수 없음)",
            "메모리 수치는 RSS 근사치이며 회수량이 아닙니다.",
        ]

        switch viewModel.memory {
        case .none:
            lines.append("메모리 지표: 읽는 중")
        case .failure(let error):
            lines.append("메모리 지표: 측정 불가 (\(String(describing: error)))")
        case .success(let snapshot):
            lines.append(
                "메모리 압박 \(snapshot.pressure.label) · 여유 "
                    + "\(Int(snapshot.freeFraction * 100))% / 전체 \(format(snapshot.totalBytes))"
            )
            lines.append(
                "앱 \(format(snapshot.appBytes)) · 통합 \(format(snapshot.wiredBytes)) · "
                    + "압축됨 \(format(snapshot.compressedBytes)) · "
                    + "캐시된 파일 \(format(snapshot.cachedBytes))"
            )
        }

        switch viewModel.swap {
        case .none:
            lines.append("스왑: 읽는 중")
        case .failure:
            lines.append("스왑: 측정 불가")
        case .success(let snapshot):
            lines.append("스왑 \(format(snapshot.usedBytes)) 사용 / \(format(snapshot.totalBytes))")
        }

        if case .success(let bytes) = viewModel.swapFileBytes {
            lines.append("스왑 파일 현재 할당 \(format(bytes)) — 회수 가능 용량이 아님")
        }

        if let error = viewModel.errorMessage { lines.append("오류 배너: \(error)") }
        if let summary = viewModel.terminationSummary { lines.append("직전 종료 요약: \(summary)") }

        lines.append(
            "프로세스 \(viewModel.processes.count)개 (선택 \(viewModel.selectedCount)개, "
                + "종료 가능 \(viewModel.terminableSelection.count)개)"
        )
        lines += itemLines(
            viewModel.processes.map {
                Row(
                    name: "\($0.displayName) · PID \($0.identity.pid)",
                    sizeBytes: $0.residentBytes,
                    detail: "\($0.kind.label) · \($0.isTerminable ? "종료 가능" : "표시만")",
                    isSelected: $0.isSelected
                )
            }
        )
        return ScreenContext(title: "개발 데몬 정리", lines: lines)
    }

    // MARK: - 설정

    /// API 키 값은 절대 넣지 않는다. 화면 컨텍스트는 그대로 외부 API로 전송된다.
    static func settings(viewModel: AISettingsViewModel) -> ScreenContext {
        let hasKey = !(viewModel.apiKeyForRequest ?? "").isEmpty
        return ScreenContext(
            title: "설정",
            lines: [
                "제공자: \(viewModel.provider.label)",
                "API 루트 URL: \(viewModel.baseURL)",
                "모델: \(viewModel.model)",
                "API 키: \(hasKey ? "입력됨" : "없음") (값은 이 대화에 포함되지 않습니다)",
                "연결 준비 상태: \(viewModel.isConfigured ? "완료" : "미완료")",
                viewModel.hasUnsavedChanges ? "저장되지 않은 변경 있음" : "저장됨",
            ]
        )
    }

    // MARK: - 공통 표현

    private struct Row {
        let name: String
        let sizeBytes: Int64
        let detail: String?
        let isSelected: Bool
    }

    private static func itemLines(_ rows: [Row]) -> [String] {
        guard !rows.isEmpty else { return ["목록: 비어 있음"] }

        let shown = rows.prefix(ScreenContext.maximumListedItems)
        var lines = ["목록 (화면 표시 순서):"]
        lines += shown.map { row in
            var line = "- \(row.name) · \(format(row.sizeBytes))"
            if let detail = row.detail { line += " · \(detail)" }
            if row.isSelected { line += " · 선택됨" }
            return line
        }
        if rows.count > shown.count {
            lines.append("- … 외 \(rows.count - shown.count)개는 길이 제한으로 생략됨")
        }
        return lines
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
