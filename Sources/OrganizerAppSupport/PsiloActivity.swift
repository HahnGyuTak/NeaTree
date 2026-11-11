import Foundation

/// Semantic work for Psilo. A watcher poll, settings write or alert dismissal is
/// not an animation event. The renderer owns choreography and finite playback.
public struct PsiloActivity: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case fileAnalysis, structureAnalysis, organizing, undo
    }
    public enum Phase: String, Equatable, Sendable {
        case idle, working, succeeded, failed, cancelled
    }
    public enum Outcome: String, Equatable, Sendable {
        case proposalReady, rulesReady, filesApplied, restored, partialFailure
    }

    public let id: UUID
    public let kind: Kind?
    public let phase: Phase
    public let outcome: Outcome?
    public let completed: Int
    public let total: Int
    public let subjectIDs: Set<UUID>

    public init(id: UUID = UUID(), kind: Kind? = nil, phase: Phase = .idle,
                outcome: Outcome? = nil, completed: Int = 0, total: Int = 0,
                subjectIDs: Set<UUID> = []) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.outcome = outcome
        self.completed = completed
        self.total = total
        self.subjectIDs = subjectIDs
    }

    public var statusLabel: String {
        switch phase {
        case .idle, .cancelled: "새 파일을 기다리고 있어요"
        case .failed: "문제를 확인하고 있어요"
        case .working:
            switch kind {
            case .fileAnalysis: "이름과 위치를 살펴보고 있어요"
            case .structureAnalysis: "폴더 구조를 살펴보고 있어요"
            case .organizing: "파일을 정리하고 있어요"
            case .undo: "원래 위치로 돌려놓고 있어요"
            case nil: "살펴보고 있어요"
            }
        case .succeeded:
            switch outcome {
            case .proposalReady: "정리안을 준비했어요"
            case .rulesReady: "규칙 후보를 준비했어요"
            case .filesApplied: "파일을 정리했어요"
            case .restored: "원래 위치로 돌려놓았어요"
            case .partialFailure: "확인이 필요한 파일이 있어요"
            case nil: "준비됐어요"
            }
        }
    }
}

/// An unresolved work failure is independent of the transient error alert.
public struct PsiloIssue: Equatable, Sendable {
    public let id: UUID
    public let operationID: UUID
    public let kind: PsiloActivity.Kind
    public let message: String
    public let subjectIDs: Set<UUID>

    public init(id: UUID = UUID(), operationID: UUID, kind: PsiloActivity.Kind, message: String,
                subjectIDs: Set<UUID> = []) {
        self.id = id
        self.operationID = operationID
        self.kind = kind
        self.message = message
        self.subjectIDs = subjectIDs
    }
}

/// The operation token rejects late responses after a cancellation or newer job.
/// Successful retries remove their files from the pending issue. Other pending
/// files survive both unrelated work and a failed retry of just one file.
struct PsiloActivityTracker {
    private(set) var activity = PsiloActivity()
    private(set) var issue: PsiloIssue?

    mutating func begin(_ kind: PsiloActivity.Kind, total: Int = 1, subjectIDs: Set<UUID> = []) -> UUID {
        activity = PsiloActivity(kind: kind, phase: .working, total: total, subjectIDs: subjectIDs)
        return activity.id
    }

    mutating func progress(_ id: UUID, completed: Int) {
        guard activity.id == id, activity.phase == .working else { return }
        activity = PsiloActivity(id: id, kind: activity.kind, phase: .working,
                                 completed: completed, total: activity.total, subjectIDs: activity.subjectIDs)
    }

    mutating func succeed(_ id: UUID, outcome: PsiloActivity.Outcome) {
        guard activity.id == id, activity.phase == .working else { return }
        if let unresolved = issue, unresolved.kind == activity.kind {
            let remaining = unresolved.subjectIDs.subtracting(activity.subjectIDs)
            issue = remaining.isEmpty ? nil : PsiloIssue(
                id: unresolved.id, operationID: unresolved.operationID,
                kind: unresolved.kind, message: unresolved.message, subjectIDs: remaining
            )
        }
        activity = PsiloActivity(id: id, kind: activity.kind, phase: .succeeded,
                                 outcome: outcome, completed: activity.total, total: activity.total, subjectIDs: activity.subjectIDs)
    }

    mutating func fail(_ id: UUID, message: String, partial: Bool = false, completed: Int = 0,
                       failedSubjectIDs: Set<UUID>? = nil) {
        guard activity.id == id, activity.phase == .working, let kind = activity.kind else { return }
        let failures = failedSubjectIDs ?? activity.subjectIDs
        if let unresolved = issue, unresolved.kind == kind {
            // Empty subjects represent a whole-operation issue (for example
            // folder-structure analysis), rather than an empty set of failures.
            var remaining: Set<UUID> = []
            if !unresolved.subjectIDs.isEmpty, !failures.isEmpty {
                remaining = unresolved.subjectIDs
                if failedSubjectIDs != nil {
                    // A retry batch may fix some old failures and fail others.
                    remaining.subtract(activity.subjectIDs.subtracting(failures))
                }
                remaining.formUnion(failures)
            }
            issue = PsiloIssue(id: unresolved.id, operationID: unresolved.operationID,
                               kind: kind, message: unresolved.message, subjectIDs: remaining)
        } else {
            issue = PsiloIssue(operationID: id, kind: kind, message: message, subjectIDs: failures)
        }
        activity = PsiloActivity(id: id, kind: kind, phase: .failed,
                                 outcome: partial ? .partialFailure : nil,
                                 completed: completed, total: activity.total, subjectIDs: activity.subjectIDs)
    }

    mutating func cancel(_ id: UUID) {
        guard activity.id == id, activity.phase == .working else { return }
        activity = PsiloActivity(id: id, kind: activity.kind, phase: .cancelled,
                                 completed: activity.completed, total: activity.total, subjectIDs: activity.subjectIDs)
    }
}
