import SwiftUI

// 목록 네 화면(캐시 계열·임시파일·시뮬레이터·개발 데몬)이 공유하는 크롬.
//
// 하단 바에 있던 "전체 선택 / 전체 해제"와 삭제 버튼은 눈에 들어오지 않는다는 피드백을 받았다.
// 선택은 목록 머리글의 3상태 체크박스가 맡고, 파괴적 액션은 화면 우측 상단의 주황 버튼으로 올린다.

/// 열 폭. 머리글과 행이 **같은 상수**를 써야 열이 어긋나지 않는다.
enum ListColumn {
    /// 체크박스 열. macOS `Toggle(.checkbox)` 실측 폭(약 16)에 여백을 둔다.
    static let checkbox: CGFloat = 18
    /// `yyyy-MM-dd`.
    static let date: CGFloat = 92
    /// `yyyy-MM-dd HH:mm`.
    static let time: CGFloat = 124
    static let size: CGFloat = 80
    /// 런타임·상태처럼 행마다 길이가 비슷한 보조 열.
    static let detail: CGFloat = 152
    /// 두 값을 위아래로 쌓는 열 (메모리 + 활동).
    static let metric: CGFloat = 150
    /// 크기 비중 막대 열.
    static let share: CGFloat = 44
    /// `i` 버튼 열.
    static let info: CGFloat = 22
    /// 행의 좌우 인셋.
    static let inset: CGFloat = 8
    /// 행 프레임을 아직 못 잰 첫 프레임에서 쓸 머리글 인셋 (행 인셋 8 + `List` 컨테이너 인셋 8).
    static let headerInset: CGFloat = 16
}

/// 행이 자기 폭을 머리글에 알리는 통로.
///
/// `List`는 **스크롤러가 보일 때만** 행 폭을 스크롤러 폭(15pt)만큼 줄인다(실측). 그래서 머리글
/// 인셋을 상수로 두면 목록이 짧은 화면과 긴 화면 중 한쪽은 반드시 어긋난다. 행이 자기 폭을 올리고
/// 머리글이 그 폭을 그대로 쓰면 두 경우와 창 크기 변경까지 저절로 맞는다.
///
/// 좌표공간(`frame(in: .named(...))`)은 쓰지 않는다 — macOS `List`의 행은 별도 호스팅 컨텍스트라
/// 바깥에서 붙인 이름이 풀리지 않고, 그러면 창 기준 x가 그대로 들어와 머리글이 화면 밖으로 밀린다(실측).
struct ListRowFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        // 행은 모두 같은 폭·같은 x이므로 첫 값만 쓴다.
        value = value ?? nextValue()
    }
}

extension View {
    /// 목록 행에 붙인다. 인셋을 고정하고 콘텐츠 영역의 화면 좌표를 머리글에 올린다.
    func listRowAlignedWithHeader() -> some View {
        listRowInsets(
            EdgeInsets(top: 4, leading: ListColumn.inset, bottom: 4, trailing: ListColumn.inset)
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ListRowFrameKey.self, value: proxy.frame(in: .global))
            }
        )
    }
}

/// 전체 선택 체크박스의 3상태. 일부만 고른 상태는 `[-]`로 보여 준다.
enum SelectionState: Equatable {
    case empty
    case partial
    case all

    /// `selectable`은 실제로 고를 수 있는 항목 수다. 사용 중인 임시파일이나 종료 불가 데몬처럼
    /// 체크할 수 없는 행까지 분모에 넣으면 전체 선택을 해도 상태가 `partial`에서 멈춘다.
    init(selected: Int, selectable: Int) {
        if selectable == 0 || selected == 0 {
            self = .empty
        } else if selected >= selectable {
            self = .all
        } else {
            self = .partial
        }
    }

    /// AppKit 체크박스의 3상태. `allowsMixedState`를 켠 `NSButton`이 그대로 쓴다.
    var buttonState: NSControl.StateValue {
        switch self {
        case .empty: return .off
        case .partial: return .mixed
        case .all: return .on
        }
    }

    /// 누르면 무엇이 되는지. 하나라도 골라 있으면(부분 선택 포함) 전체 해제다.
    var selectsAllOnTap: Bool { self == .empty }
}

/// 목록 머리글의 전체 선택 체크박스.
///
/// 행과 **같은 AppKit 체크박스**를 쓴다. SwiftUI `Toggle(.checkbox)`는 mixed 상태를 그릴 수 없어
/// 예전에는 SF Symbol 버튼으로 흉내냈는데, 모양(테두리 사각형 vs 실제 체크박스)과 위치가 행과
/// 어긋났다. `NSButton`을 직접 감싸면 mixed도 그려지고 행과 같은 컨트롤이 된다.
struct SelectAllCheckbox: NSViewRepresentable {
    let state: SelectionState
    let isEnabled: Bool
    let action: (Bool) -> Void

    func makeNSView(context: Context) -> NSButton {
        let checkbox = NSButton()
        checkbox.setButtonType(.switch)
        checkbox.allowsMixedState = true
        checkbox.title = ""
        checkbox.target = context.coordinator
        checkbox.action = #selector(Coordinator.toggle(_:))
        return checkbox
    }

    func updateNSView(_ checkbox: NSButton, context: Context) {
        context.coordinator.update(state: state, action: action)
        checkbox.state = state.buttonState
        checkbox.isEnabled = isEnabled
        let label = state.selectsAllOnTap ? "전체 선택" : "전체 해제"
        checkbox.toolTip = label
        checkbox.setAccessibilityLabel(label)
    }

    /// 체크박스 고유 크기로 고정한다. 이걸 빼면 `NSViewRepresentable`이 제안된 공간을 전부
    /// 차지해서 머리글 한 줄이 화면 높이만큼 늘어난다(실측).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state, action: action) }

    /// 클릭을 뷰모델로 넘기고, `NSButton`이 스스로 돌린 상태는 되돌린다.
    ///
    /// `allowsMixedState`는 클릭마다 off → on → mixed로 돌지만 여기서 진실은 목록의 선택 수다.
    /// 액션이 선택 수를 바꾸지 않으면(고를 수 있는 항목이 없는 경우) SwiftUI가 다시 그리지 않으므로,
    /// 클릭 직후 원래 상태로 돌려 놓아야 표시가 어긋나지 않는다.
    final class Coordinator: NSObject {
        private var state: SelectionState
        private var action: (Bool) -> Void

        init(state: SelectionState, action: @escaping (Bool) -> Void) {
            self.state = state
            self.action = action
        }

        func update(state: SelectionState, action: @escaping (Bool) -> Void) {
            self.state = state
            self.action = action
        }

        @objc func toggle(_ sender: NSButton) {
            sender.state = state.buttonState
            action(state.selectsAllOnTap)
        }
    }
}

/// 머리글 + 목록을 한 덩어리로 묶는다. 행 프레임 관측이 여기서 일어나므로 탭 뷰는
/// `ListHeader`와 `List`를 따로 두지 않고 이걸 쓴다.
struct HeaderedList<Columns: View, Rows: View>: View {
    private let selection: SelectionState
    private let isEnabled: Bool
    private let onToggle: (Bool) -> Void
    private let columns: Columns
    private let rows: Rows

    /// 행 콘텐츠와 머리글 컨테이너의 화면 좌표. 둘의 좌우 끝 차이가 그대로 머리글 인셋이 된다.
    @State private var rowFrame: CGRect?
    @State private var headerFrame: CGRect?

    init(
        selection: SelectionState,
        isEnabled: Bool,
        onToggle: @escaping (Bool) -> Void,
        @ViewBuilder columns: () -> Columns,
        @ViewBuilder rows: () -> Rows
    ) {
        self.selection = selection
        self.isEnabled = isEnabled
        self.onToggle = onToggle
        self.columns = columns()
        self.rows = rows()
    }

    var body: some View {
        VStack(spacing: 0) {
            ListHeader(
                selection: selection,
                isEnabled: isEnabled,
                onToggle: onToggle,
                leadingInset: leadingInset,
                trailingInset: trailingInset
            ) {
                columns
            }
            // 배경으로 재면 레이아웃에 영향을 주지 않는다. `frame(width:)`로 머리글 폭을 맞추면
            // 머리글의 이상 폭이 커져 NavigationSplitView가 계속 넓어진다(실측).
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: HeaderFrameKey.self, value: proxy.frame(in: .global)
                    )
                }
            )

            List { rows }
                .listStyle(.plain)
        }
        // 뷰 업데이트 안에서 상태를 바꾸지 않도록 다음 턴으로 미룬다 — `onAppearDeferred` 주석 참고.
        .onPreferenceChange(ListRowFrameKey.self) { frame in
            Task { @MainActor in rowFrame = frame }
        }
        .onPreferenceChange(HeaderFrameKey.self) { frame in
            Task { @MainActor in headerFrame = frame }
        }
    }

    /// 행의 왼쪽 끝에 맞춘다. 못 재면 상수 인셋으로 그린다.
    private var leadingInset: CGFloat {
        guard let rowFrame, let headerFrame else { return ListColumn.headerInset }
        return max(0, rowFrame.minX - headerFrame.minX)
    }

    /// 행의 오른쪽 끝에 맞춘다. `List`가 스크롤러에 폭을 얼마나 내줬는지 몰라도 저절로 맞는다.
    private var trailingInset: CGFloat {
        guard let rowFrame, let headerFrame else { return ListColumn.headerInset }
        return max(0, headerFrame.maxX - rowFrame.maxX)
    }
}

/// 머리글 컨테이너의 화면 좌표.
struct HeaderFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
    }
}

/// 목록 위 머리글 줄. 전체 선택 체크박스 + 열 제목.
struct ListHeader<Columns: View>: View {
    private let selection: SelectionState
    private let isEnabled: Bool
    private let onToggle: (Bool) -> Void
    private let leadingInset: CGFloat
    private let trailingInset: CGFloat
    private let columns: Columns

    init(
        selection: SelectionState,
        isEnabled: Bool,
        onToggle: @escaping (Bool) -> Void,
        leadingInset: CGFloat = ListColumn.headerInset,
        trailingInset: CGFloat = ListColumn.headerInset,
        @ViewBuilder columns: () -> Columns
    ) {
        self.selection = selection
        self.isEnabled = isEnabled
        self.onToggle = onToggle
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        self.columns = columns()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SelectAllCheckbox(state: selection, isEnabled: isEnabled, action: onToggle)
                    .frame(width: ListColumn.checkbox, alignment: .leading)
                    .overlay(selectAllShortcut)
                columns
            }
            // 열 제목이 caption(10pt)에서는 읽히지 않는다는 피드백을 받아 한 단 키웠다.
            .font(.callout.bold())
            .foregroundStyle(.secondary)
            // 행의 좌우 끝에 맞춘다 — `ListRowFrameKey` 주석 참고.
            .padding(.leading, leadingInset)
            .padding(.trailing, trailingInset)
            .padding(.vertical, 6)

            Divider()
        }
    }

    /// 키보드로 전체 선택·해제. ⌘A는 챗 입력창의 텍스트 전체 선택을 빼앗으므로 ⌘⇧A를 쓴다.
    private var selectAllShortcut: some View {
        Button("전체 선택 전환") { onToggle(selection.selectsAllOnTap) }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .disabled(!isEnabled)
    }
}

/// 열 클릭 정렬 상태. 같은 열을 다시 누르면 방향만 뒤집는다.
struct ColumnSort<Key: Equatable>: Equatable {
    var key: Key
    var isAscending: Bool

    init(key: Key, isAscending: Bool) {
        self.key = key
        self.isAscending = isAscending
    }

    /// 열을 바꿀 때는 그 열에서 쓸모 있는 방향으로 시작한다 (이름은 가나다순, 크기·날짜는 큰 값·최근 순).
    mutating func select(_ newKey: Key, ascendingFirst: Bool) {
        if key == newKey {
            isAscending.toggle()
        } else {
            key = newKey
            isAscending = ascendingFirst
        }
    }
}

extension Array {
    /// 오름차순 비교로 정렬한 뒤 필요하면 뒤집는다.
    ///
    /// 비교 함수 자체를 뒤집으면(`!(a < b)`) 같은 값에서 양방향 true가 되어 유효한
    /// strict weak ordering이 아니다.
    func sorted(ascending: Bool, by isBefore: (Element, Element) -> Bool) -> [Element] {
        let result = sorted(by: isBefore)
        return ascending ? result : result.reversed()
    }
}

/// 목록 안에서 이 항목이 차지하는 비중. 상위 몇 개가 대부분인 것을 숫자만으로는 못 본다.
struct ShareBar: View {
    /// 0…1. 목록 최대 크기 대비 비율.
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Color.orange.opacity(0.55))
                    .frame(width: max(2, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(width: ListColumn.share, height: 4)
        .accessibilityHidden(true)
    }
}

/// 행 컨텍스트 메뉴에서 쓰는 복사.
enum Clipboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// 누르면 정렬 기준이 바뀌는 열 제목. 활성 열에만 방향 화살표가 보인다.
struct SortableColumnLabel: View {
    let title: String
    let isActive: Bool
    let isAscending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: isAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    // 자리를 늘 차지하게 둔다. 정렬을 바꿀 때 열 제목이 흔들리지 않는다.
                    .opacity(isActive ? 1 : 0)
            }
            .foregroundStyle(isActive ? Color.primary : Color.secondary)
            // 글자만 히트 영역이면 클릭 지점을 찾기 어렵다.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title) 기준으로 정렬")
    }
}

/// 화면 우측 상단의 액션 버튼. 활성일 때만 주황 배경으로 눈에 띈다.
///
/// `isPrimary`가 false면 같은 주황 계열의 테두리 버튼이 되어, 한 화면에 액션이 여러 개일 때
/// 무엇이 주 액션인지 읽힌다 (시뮬레이터 탭의 데이터 초기화 vs 기기 삭제).
struct ListActionButton: View {
    let title: String
    let systemImage: String
    var isPrimary = true
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if !isEnabled {
                // 비활성일 때는 주황을 빼고 평범한 테두리 버튼으로 둔다. 흐린 주황도 "누를 수 있는
                // 버튼"으로 읽혀서, 색으로 활성 여부를 알리는 목적이 무너진다.
                button.buttonStyle(.bordered)
            } else if isPrimary {
                button.buttonStyle(.borderedProminent).tint(.orange)
            } else {
                button.buttonStyle(.bordered).tint(.orange)
            }
        }
        .disabled(!isEnabled)
    }

    private var button: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
    }
}

/// 목록 화면의 상단 바: 제목 · 진행 표시 · 선택 요약 · 새로고침 · 액션 버튼.
struct TabHeader<Actions: View>: View {
    private let title: String
    private let isWorking: Bool
    private let summary: String?
    private let search: Binding<String>?
    private let refresh: () -> Void
    private let actions: Actions

    init(
        title: String,
        isWorking: Bool,
        summary: String? = nil,
        search: Binding<String>? = nil,
        refresh: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.isWorking = isWorking
        self.summary = summary
        self.search = search
        self.refresh = refresh
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 8) {
            // 창이 좁아지면(AI 도우미를 열면 본문이 그만큼 줄어든다) 제목부터 줄인다.
            // 어느 화면인지는 사이드바에도 표시돼 있어 여기서 잘려도 길을 잃지 않는다.
            // 제목은 요약·검색보다 늦게 줄어든다. 좁은 창에서도 어느 화면인지가 먼저 읽혀야 한다.
            // 잘린 전체 제목은 툴팁으로 남긴다.
            Text(title)
                .font(.title2.bold())
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
            if isWorking { ProgressView().controlSize(.small) }
            Spacer(minLength: 8)
            if let search {
                // 목록이 수백 개라 눈으로 찾을 수 없다. 걸러 보기는 선택을 건드리지 않는다 —
                // 이미 고른 항목은 걸러져 보이지 않아도 선택 요약에 그대로 남는다.
                //
                // 폭을 고정하지 않는다. 고정하면 좁은 창에서 상단 바가 줄어들지 못해 남는 폭을
                // 사이드바가 내주고, AI 도우미를 열 때 사이드바가 밀렸다(실측).
                TextField("검색", text: search)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 60, idealWidth: 110, maxWidth: 180)
                    .help("이름으로 걸러 봅니다. 선택은 그대로 유지됩니다.")
            }
            if let summary {
                // 우선순위를 낮추지 않는다. 낮추면 좁은 창에서 이 값(몇 개·총 용량)이 먼저
                // 사라지는데, 그건 이 화면이 답해야 하는 첫 질문이다. 줄어드는 것은 검색창이다.
                Text(summary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Button("새로고침") { refresh() }
                .disabled(isWorking)
            actions
        }
    }
}

/// 상단 바 오른쪽의 요약 문구.
///
/// 아무것도 고르지 않았을 때는 목록 전체 규모를 보여 준다 — 이 화면들이 답해야 하는 첫 질문이
/// "얼마나 지울 수 있나"이고, 그 값은 지금까지 어디에도 없었다.
enum SelectionSummary {
    static func text(
        selectedCount: Int,
        selectedBytes: Int64,
        totalCount: Int,
        totalBytes: Int64,
        countStyle: ByteCountFormatter.CountStyle = .file
    ) -> String? {
        if selectedCount > 0 {
            return "선택 \(selectedCount)개 · \(format(selectedBytes, countStyle))"
        }
        guard totalCount > 0 else { return nil }
        return "\(totalCount)개 · \(format(totalBytes, countStyle))"
    }

    private static func format(
        _ bytes: Int64,
        _ countStyle: ByteCountFormatter.CountStyle
    ) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: countStyle)
    }
}
