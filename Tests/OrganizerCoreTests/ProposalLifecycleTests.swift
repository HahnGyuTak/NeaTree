import Foundation
import Testing
@testable import OrganizerCore

@Suite("Proposal lifecycle")
struct ProposalLifecycleTests {
    @Test func newerRequestCannotBeOverwrittenByLateOlderResponse() async throws {
        let workspace = try LifecycleWorkspace()
        defer { workspace.remove() }
        try await workspace.configure()
        let entry = try await workspace.service.importItem(workspace.source)
        let context = try await workspace.context()
        let first = ControlledSession()
        let second = ControlledSession()
        defer { first.close(); second.close() }

        let firstTask = Task { try await workspace.service.propose(id: entry.id, client: first.client) }
        defer { firstTask.cancel() }
        try await first.gate.waitForStart()
        let secondTask = Task { try await workspace.service.propose(id: entry.id, client: second.client) }
        defer { secondTask.cancel() }
        try await second.gate.waitForStart()

        try await second.gate.finish(responseData(proposal(fileID: context.fileID, folderID: context.folderID, name: "newest.txt", reason: "newest request")))
        let newest = try await secondTask.value
        #expect(newest.proposedName == "newest.txt")
        try await first.gate.finish(responseData(proposal(fileID: context.fileID, folderID: context.folderID, name: "older.txt", reason: "older request")))
        await expectSourceChanged { _ = try await firstTask.value }

        let stored = await workspace.service.entries().first { $0.id == entry.id }
        #expect(stored?.proposal?.proposedName == "newest.txt")
        #expect(stored?.proposal?.reason == "newest request")
        #expect(FileManager.default.fileExists(atPath: workspace.source.path))
    }

    @Test func confirmedRuleChangeRequiresFreshProposalBeforeApply() async throws {
        let workspace = try LifecycleWorkspace()
        defer { workspace.remove() }
        try await workspace.configure()
        let entry = try await workspace.service.importItem(workspace.source)
        let context = try await workspace.context()
        let proposals = ControlledSession()
        let rules = ControlledSession()
        defer { proposals.close(); rules.close() }

        let proposalTask = Task { try await workspace.service.propose(id: entry.id, client: proposals.client) }
        defer { proposalTask.cancel() }
        try await proposals.gate.waitForStart()
        try await proposals.gate.finish(responseData(proposal(fileID: context.fileID, folderID: context.folderID, name: "previous.txt", reason: "old rules")))
        _ = try await proposalTask.value

        let rulesTask = Task { try await workspace.service.analyzeStructure(client: rules.client) }
        defer { rulesTask.cancel() }
        try await rules.gate.waitForStart()
        try await rules.gate.finish(responseData(["candidates": [[
            "folderID": context.folderID,
            "instruction": "새 규칙: 문서명을 프로젝트 코드로 시작한다.",
            "evidence": ["PRJ_예시.txt"],
            "uncertainties": []
        ]]]))
        _ = try await rulesTask.value
        _ = try await workspace.service.confirmRule(index: 0)

        await expectSourceChanged { _ = try await workspace.service.apply(id: entry.id) }
        #expect(FileManager.default.fileExists(atPath: workspace.source.path))
        #expect(!FileManager.default.fileExists(atPath: workspace.destination.appendingPathComponent("previous.txt").path))
        #expect(try await workspace.service.history().isEmpty)
    }

    private func proposal(fileID: String, folderID: String, name: String, reason: String) -> [String: Any] {
        ["fileID": fileID, "status": "ready", "destinationFolderID": folderID, "proposedName": name,
         "reason": reason, "evidence": ["계약서"], "alternatives": [], "missingInformation": []]
    }

    private func responseData(_ payload: [String: Any]) throws -> Data {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: [
            "status": "completed", "output": [["type": "message", "status": "completed", "content": [["type": "output_text", "text": text]]]]
        ])
    }

    private func expectSourceChanged(operation: () async throws -> Void) async {
        do { try await operation(); Issue.record("Expected sourceChanged for an obsolete proposal") }
        catch {
            guard let serviceError = error as? OrganizerServiceError else {
                Issue.record("Unexpected error type: \(type(of: error))")
                return
            }
            if case .sourceChanged = serviceError {} else {
                Issue.record("Expected sourceChanged, received \(serviceError)")
            }
        }
    }
}

private struct LifecycleWorkspace: Sendable {
    let root: URL
    let downloads: URL
    let destination: URL
    let source: URL
    let service: OrganizerService

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("proposal-lifecycle-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        destination = root.appendingPathComponent("Documents", isDirectory: true)
        source = downloads.appendingPathComponent("original.txt")
        for folder in [downloads, destination] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("계약서 테스트 내용".utf8).write(to: source)
        try Data("규칙 확인용 사례".utf8).write(to: destination.appendingPathComponent("PRJ_예시.txt"))
        service = try OrganizerService(stateDirectory: root.appendingPathComponent("state"))
    }

    func configure() async throws { try await service.configure(downloads: downloads, roots: [destination]) }
    func context() async throws -> (fileID: String, folderID: String) {
        let settings = try await service.configuration()
        let folder = try #require(settings.folders.first { $0.path == destination.path })
        return (try FileInspector.inspect(source).id, folder.id)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private enum LifecycleFixtureError: Error {
    case requestDidNotStart, noPendingRequest, responseTimedOut, duplicateRequest
}

/// Pure async fake transport. Every suspended request is completed, cancelled, or timed out.
private actor ResponseGate {
    private var pending: CheckedContinuation<(Data, URLResponse), any Error>?
    private var request: URLRequest?
    private var started = false
    private var cancelled = false
    private var timeoutTask: Task<Void, Never>?

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard !started else { throw LifecycleFixtureError.duplicateRequest }
        self.request = request
        started = true
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !cancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending = continuation
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) }
                    catch { return }
                    await self?.timeOut()
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitForStart() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !started {
            guard ContinuousClock.now < deadline else { throw LifecycleFixtureError.requestDidNotStart }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func finish(_ data: Data) throws {
        guard let continuation = pending, let url = request?.url else { throw LifecycleFixtureError.noPendingRequest }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        continuation.resume(returning: (data, response))
    }

    func cancel() {
        cancelled = true
        let continuation = pending
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(throwing: CancellationError())
    }

    private func timeOut() {
        let continuation = pending
        pending = nil
        timeoutTask = nil
        continuation?.resume(throwing: LifecycleFixtureError.responseTimedOut)
    }
}

private struct ControlledSession: Sendable {
    let gate = ResponseGate()
    var client: OpenAIClient {
        OpenAIClient(apiKey: "dummy-test-key", transport: { request in try await gate.perform(request) })
    }
    func close() {
        Task { await gate.cancel() }
    }
}
