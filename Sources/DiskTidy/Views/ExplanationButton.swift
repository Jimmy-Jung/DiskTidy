import SwiftUI

/// 목록 한 줄에 붙는 `i` 버튼. 누르면 AI가 그 항목이 무엇인지 설명한다.
///
/// 탭마다 항목 형태가 달라서 뷰를 탭별로 두지 않고 `ExplanationSubject`만 받는다.
struct ExplanationButton: View {
    let subject: ExplanationSubject
    let screenTitle: String

    @EnvironmentObject private var settings: AISettingsViewModel
    @EnvironmentObject private var explanations: ItemExplanationStore

    @State private var isShowingExplanation = false

    var body: some View {
        Button {
            ask()
            isShowingExplanation = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        // 앱이 아는 항목은 AI가 필요 없으므로 설정과 무관하게 열린다.
        .disabled(!isAvailable)
        .help(helpText)
        // 팝오버로 돌아왔다. macOS의 SwiftUI 팝오버는 transient라서 창이 key 상태를 잃으면
        // 닫히는데, 그 상황을 만드는 것은 CLI 자식 프로세스가 올리는 파일 접근 권한 알럿이다.
        // 아는 항목은 프로세스를 띄우지 않으니 그럴 일이 없고, AI에게 묻는 경우에도 받은 답은
        // 캐시에 남아 다시 누르면 즉시 뜬다.
        .popover(isPresented: $isShowingExplanation, arrowEdge: .bottom) {
            explanationCard
        }
    }

    /// 앱이 아는 항목이면 AI 연결과 무관하게 쓸 수 있다.
    private var isAvailable: Bool {
        subject.knownDescription != nil || settings.isConfigured
    }

    private var helpText: String {
        if subject.knownDescription != nil { return "이 항목이 무엇인지 보기" }
        return settings.isConfigured
            ? "이 항목이 무엇인지 AI에게 묻기"
            : "설정 탭에서 AI를 연결하면 모르는 항목도 설명을 볼 수 있습니다."
    }

    /// 마우스를 올릴 때가 아니라 **누를 때** 묻는다. 호버로 물으면 목록을 지나가는 것만으로
    /// 항목 수만큼 요청이 나가고, CLI 제공자는 호출마다 프로세스를 띄운다.
    ///
    /// 앱이 아는 항목이면 `force`가 없는 한 저장소가 요청을 만들지 않는다.
    private func ask(force: Bool = false) {
        explanations.explain(
            subject,
            screenTitle: screenTitle,
            settings: settings.settings,
            apiKey: settings.apiKeyForRequest,
            force: force
        )
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subject.title).font(.headline)
            if let subtitle = subject.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            if let known = subject.knownDescription {
                paragraph(known)
                caption("이 앱이 직접 찾아 넣은 항목의 설명입니다.")
            }

            aiSection
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        // 제목·경로·면책 문구도 `List` 행의 `lineLimit(1)`을 물려받아 잘린다. 팝오버 전체에 건다.
        .lineLimit(nil)
        .multilineTextAlignment(.leading)
    }

    /// AI 설명 자리.
    ///
    /// 앱이 아는 항목이라도 AI에게 물을 길을 남겨 둔다 — 앱의 설명은 그 경로가 무엇인지까지고,
    /// 그 이상은 모델이 나을 수 있다. 다만 자동으로는 묻지 않는다.
    @ViewBuilder
    private var aiSection: some View {
        switch explanations.state(for: subject) {
        case .none where subject.knownDescription != nil:
            Button("AI에게도 물어보기") { ask(force: true) }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(!settings.isConfigured)
                .help(
                    settings.isConfigured
                        ? "같은 항목을 AI에게 다시 물어봅니다."
                        : "설정 탭에서 AI를 연결해야 합니다."
                )

        case .loading, .none:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("설명을 받는 중…").foregroundStyle(.secondary)
            }

        case .ready(let text):
            Divider()
            paragraph(text)
            // 출처를 구분한다. 앱이 아는 것과 모델의 추측은 신뢰도가 다르고, 이 앱은
            // 사용자 파일을 지우고 프로세스를 죽인다.
            caption("AI가 이름과 경로만 보고 쓴 설명입니다. 실행 전에 직접 확인하세요.")

        case .failed(let message):
            Divider()
            Text(message).foregroundStyle(.orange)
            Button("다시 시도") {
                explanations.forget(subject)
                ask(force: true)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    /// `List` 행에서 띄운 팝오버는 행의 `lineLimit(1)`을 물려받아 한 줄로 잘린다.
    /// 줄 수 제한을 풀고 세로로는 필요한 높이를 그대로 쓰게 한다.
    private func paragraph(_ text: String) -> some View {
        Text(text)
            .textSelection(.enabled)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}
