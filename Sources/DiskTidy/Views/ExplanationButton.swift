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
        .disabled(!settings.isConfigured)
        .help(
            settings.isConfigured
                ? "이 항목이 무엇인지 AI에게 묻기"
                : "설정 탭에서 AI를 연결하면 설명을 볼 수 있습니다."
        )
        // 팝오버가 아니라 시트다. macOS의 SwiftUI 팝오버는 transient라서 창이 key 상태를
        // 잃으면 닫힌다. CLI 제공자는 자식 프로세스를 띄우고, 그 프로세스가 파일 접근 권한
        // 알럿을 올리면 그 순간 포커스가 넘어가 팝오버가 사라진다 — 답을 기다리는 동안
        // 화면이 닫히는 것이 정확히 그 이유다. 시트는 창에 붙어 있어 영향받지 않는다.
        .sheet(isPresented: $isShowingExplanation) {
            explanationCard
        }
    }

    /// 마우스를 올릴 때가 아니라 **누를 때** 묻는다. 호버로 물으면 목록을 지나가는 것만으로
    /// 항목 수만큼 요청이 나가고, CLI 제공자는 호출마다 프로세스를 띄운다.
    private func ask() {
        explanations.explain(
            subject,
            screenTitle: screenTitle,
            settings: settings.settings,
            apiKey: settings.apiKeyForRequest
        )
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(subject.title).font(.headline)
                Spacer()
                Button("닫기") { isShowingExplanation = false }
                    .keyboardShortcut(.cancelAction)
            }
            if let subtitle = subject.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Divider()

            switch explanations.state(for: subject) {
            case .loading, .none:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("설명을 받는 중…").foregroundStyle(.secondary)
                }
            case .ready(let text):
                Text(text).textSelection(.enabled)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message).foregroundStyle(.orange)
                    Button("다시 시도") {
                        explanations.forget(subject)
                        ask()
                    }
                }
            }

            // 이 앱은 사용자 파일을 지우고 프로세스를 죽인다. 설명은 근거가 아니라 참고다.
            Text("AI가 이름과 경로만 보고 쓴 설명입니다. 실행 전에 직접 확인하세요.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }
}
