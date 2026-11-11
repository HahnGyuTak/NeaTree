#if DEBUG
import OrganizerAppSupport
import SwiftUI

/// Local-only model/motion validation. This does not operate on the app model,
/// read user files or invoke an API. Shipped release builds omit this view.
@MainActor
struct PsiloMotionLabView: View {
    @State private var activity = PsiloActivity()
    @State private var issue: PsiloIssue?

    var body: some View {
        VStack(spacing: 16) {
            Text("실로 · 3D 동작 미리보기")
                .font(.title3.weight(.semibold))
            Psilo3DView(activity: activity, issue: issue)
                .frame(width: 320, height: 240)
                .accessibilityLabel("실로 3D 캐릭터")
            Text(activity.statusLabel)
                .font(.callout)
                .accessibilityIdentifier("psilo-lab-status")
            HStack(spacing: 10) {
                Button("대기") { reset() }
                Button("파일 분석") { start(.fileAnalysis) }
                Button("폴더 분석") { start(.structureAnalysis) }
                Button("완료") { finish() }
                Button("오류") { fail() }
                Button("복구") { reset() }
            }
            .buttonStyle(.bordered)
            Text("창 안에서 커서를 움직여 보세요. 최소화·가리기 시 렌더링을 중단합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("샘플 동작만 재생합니다. 실제 파일과 API는 사용하지 않습니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 430)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func start(_ kind: PsiloActivity.Kind) {
        activity = PsiloActivity(kind: kind, phase: .working, total: 1)
    }

    private func finish() {
        let kind = activity.kind ?? .organizing
        let outcome: PsiloActivity.Outcome = switch kind {
        case .fileAnalysis: .proposalReady
        case .structureAnalysis: .rulesReady
        case .organizing: .filesApplied
        case .undo: .restored
        }
        if issue?.kind == kind { issue = nil }
        activity = PsiloActivity(id: activity.id, kind: kind, phase: .succeeded,
                                 outcome: outcome, completed: 1, total: 1)
    }

    private func fail() {
        let kind = activity.kind ?? .fileAnalysis
        issue = PsiloIssue(operationID: activity.id, kind: kind, message: "동작 확인용 샘플 오류")
        activity = PsiloActivity(id: activity.id, kind: kind, phase: .failed, total: 1)
    }

    private func reset() {
        issue = nil
        activity = PsiloActivity()
    }
}
#endif
