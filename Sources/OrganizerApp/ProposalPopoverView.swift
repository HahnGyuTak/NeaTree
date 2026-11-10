import Foundation
import OrganizerAppSupport
import OrganizerCore
import OrganizerDesignSystem
import SwiftUI

@MainActor
struct ProposalPopoverView: View {
    @ObservedObject var model: OrganizerAppModel
    let onOpenMain: () -> Void
    @State private var snapshot: ProposalSnapshot?

    init(model: OrganizerAppModel, onOpenMain: @escaping () -> Void) {
        self.model = model
        self.onOpenMain = onOpenMain
    }

    private var proposals: [InboxEntry] {
        model.entries.filter {
            [.ready, .proposed].contains($0.status) && model.proposal(for: $0) != nil
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private var latestEntry: InboxEntry? {
        guard let snapshot else { return nil }
        return model.entries.first { $0.id == snapshot.entry.id }
    }

    private var requiresReview: Bool {
        guard let snapshot else { return false }
        guard let latestEntry else { return true }
        return model.settings?.revision != snapshot.configurationRevision
            || latestEntry.fingerprint != snapshot.entry.fingerprint
            || latestEntry.path != snapshot.entry.path
            || model.proposal(for: latestEntry) != snapshot.proposal
            || destinationPath(snapshot.proposal.destinationFolderID) != snapshot.destinationPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "tray").foregroundStyle(.secondary)
                Text("정리 제안").font(.headline)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                if let snapshot, let index = proposals.firstIndex(where: { $0.id == snapshot.entry.id }) {
                    Text("\(index + 1) / \(proposals.count)")
                        .font(.caption).foregroundStyle(.secondary)
                } else if snapshot != nil {
                    Text("확인 필요").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let snapshot {
                proposalContents(snapshot)
            } else {
                emptyContents
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("확인") { model.errorMessage = nil }
            }
            HStack {
                Text(model.watching ? "감시 중" : "감시 일시중지")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("앱에서 자세히 보기") { openMain() }
                    .font(.caption)
            }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear { reconcileSnapshot() }
        .onChange(of: model.entries) { _, _ in reconcileSnapshot() }
    }

    @ViewBuilder private func proposalContents(_ snapshot: ProposalSnapshot) -> some View {
        let entry = snapshot.entry
        let proposal = snapshot.proposal
        VStack(alignment: .leading, spacing: 12) {
            Text(URL(fileURLWithPath: entry.path).lastPathComponent)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .textSelection(.enabled)
            field("제안 이름", value: proposal.proposedName ?? "이름 확인 필요")
            field("제안 위치", value: snapshot.destinationPath ?? "위치 확인 필요")
            Text(proposal.reason)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(3)
            if proposal.status != "ready" {
                Text("분류가 애매한 항목입니다. 검토함에서 확인하거나 미분류로 보낼 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if proposal.proposedName?.contains("{serial}") == true {
                Text("검토함에서 번호 자리 수를 확인한 뒤 적용하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if requiresReview {
                Text("파일 또는 제안이 변경되었습니다. 앱에서 현재 파일을 다시 검토하세요.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack(spacing: 12) {
            Button("취소") { Task { await model.hold(entry.id) } }
                .disabled(model.isBusy || latestEntry == nil)
            Spacer()
            if requiresReview {
                Button("다시 검토") { openMain(entry: entry) }
            } else if canApply(proposal) {
                Button("적용") {
                    guard let name = proposal.proposedName, let folder = proposal.destinationFolderID else { return }
                    Task {
                        guard !requiresReview else { return }
                        await model.apply(id: entry.id, name: name, folderID: folder, reviewedFingerprint: entry.fingerprint)
                    }
                }
                .disabled(model.isBusy)
            } else {
                Button("자세히 검토") { openMain(entry: entry) }
            }
        }
        .buttonStyle(LiquidGlassButtonStyle())
        .controlSize(.small)
    }

    private var emptyContents: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.settings == nil {
                Text("관리할 폴더를 선택하면 시작할 수 있습니다.")
                Button("설정 열기") {
                    onOpenMain()
                    NotificationCenter.default.post(name: Notification.Name("OrganizerOpenSettings"), object: nil)
                }
            } else if model.entries.contains(where: { $0.status == .ready }) {
                Text("분석할 파일이 검토함에 있습니다.")
                Text(model.hasAPIKey ? "검토함에서 분석을 시작할 수 있습니다." : "설정에서 API 키를 추가하거나 직접 이름과 위치를 지정하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("새로운 정리 제안이 없습니다.")
                Text("다운로드가 완료된 파일은 검토함에 모입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private func field(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).lineLimit(3).textSelection(.enabled)
        }
    }

    private func canApply(_ proposal: FileProposal) -> Bool {
        proposal.status == "ready" && proposal.proposedName?.isEmpty == false
            && proposal.proposedName?.contains("{serial}") != true
            && destinationPath(proposal.destinationFolderID) != nil
    }

    private func destinationPath(_ id: String?) -> String? {
        guard let id else { return nil }
        return model.settings?.folders.first(where: { $0.id == id })?.path
    }

    private func reconcileSnapshot() {
        if let snapshot {
            // Keep exactly what the user saw if a watcher refresh changes this
            // file. Only completed decisions advance to another proposal.
            guard let latest = model.entries.first(where: { $0.id == snapshot.entry.id }),
                  [.held, .applied, .unclassified].contains(latest.status) else { return }
        }
        let entry = proposals.first(where: { $0.id == model.selectedItemID }) ?? proposals.first
        guard let entry, let proposal = model.proposal(for: entry) else {
            snapshot = nil
            return
        }
        snapshot = ProposalSnapshot(entry: entry, proposal: proposal, destinationPath: destinationPath(proposal.destinationFolderID), configurationRevision: model.settings?.revision)
    }

    private func openMain(entry: InboxEntry? = nil) {
        if let entry = entry ?? snapshot?.entry { model.selectedItemID = entry.id }
        onOpenMain()
        NotificationCenter.default.post(name: Notification.Name("OrganizerShowReview"), object: nil)
    }

    private struct ProposalSnapshot {
        let entry: InboxEntry
        let proposal: FileProposal
        let destinationPath: String?
        let configurationRevision: UUID?
    }
}
