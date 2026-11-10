import Foundation

public enum OpenAIClientError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey
    case invalidInput
    case inputTooLarge
    case transportFailure
    case httpFailure(statusCode: Int)
    case refused
    case incompleteResponse
    case invalidResponse
    case invalidProposal

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "OpenAI API 키가 설정되어 있지 않습니다."
        case .invalidInput: "분석 요청의 파일 또는 폴더 정보를 확인해 주세요."
        case .inputTooLarge: "한 번에 분석할 자료가 너무 큽니다. 폴더 범위를 나누어 주세요."
        case .transportFailure: "OpenAI 서버와 연결하지 못했습니다. 파일은 변경하지 않았습니다."
        case .httpFailure(let code): "OpenAI 요청에 실패했습니다. HTTP 상태: \(code)."
        case .refused: "모델이 이 분석 요청에 응답하지 않았습니다. 직접 검토할 수 있습니다."
        case .incompleteResponse: "분석 응답이 완료되지 않았습니다. 다시 분석해 주세요."
        case .invalidResponse: "분석 응답의 형식을 확인할 수 없습니다."
        case .invalidProposal: "분석 결과에 허용되지 않는 폴더나 파일명이 포함되어 있습니다."
        }
    }
}

/// Read-only analysis adapter. It never reads credentials from disk or mutates files.
public struct OpenAIClient: Sendable {
    public static let model = "gpt-6.1-sol"
    private let apiKey: String
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private static let maximumInputBytes = 1_000_000

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.transport = { request in try await session.data(for: request) }
    }

    /// Allows deterministic tests without entering CFNetwork or creating real requests.
    init(apiKey: String, transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.apiKey = apiKey
        self.transport = transport
    }

    public func analyzeStructure(folders: [FolderRecord]) async throws -> RuleAnalysis {
        guard !folders.isEmpty else { return RuleAnalysis(candidates: []) }
        try validateFolders(folders)
        let result: RuleAnalysis = try await request(
            task: PromptLibrary.analyzeStructure,
            input: StructureInput(folders: folders),
            schemaName: "folder_rules",
            schema: Self.ruleSchema
        )
        try validateRules(result, folders: folders)
        return result
    }

    public func propose(file: FileEvidence, folders: [FolderRecord], rules: [FolderRule]) async throws -> FileProposal {
        try validateInput(file: file, folders: folders)
        let result: FileProposal = try await request(
            task: PromptLibrary.proposeFile,
            input: ProposalInput(file: file, folders: folders, confirmedRules: relevantRules(rules, folders: folders)),
            schemaName: "file_proposal",
            schema: Self.proposalSchema
        )
        try validateProposal(result, file: file, folders: folders)
        return result
    }

    public func reanalyze(file: FileEvidence, folders: [FolderRecord], rules: [FolderRule], previous: FileProposal, reason: String) async throws -> FileProposal {
        try validateInput(file: file, folders: folders)
        guard previous.fileID == file.id else { throw OpenAIClientError.invalidInput }
        let result: FileProposal = try await request(
            task: PromptLibrary.proposeFile + "\n\n" + PromptLibrary.reanalyzeFile,
            input: ReanalysisInput(file: file, folders: folders, confirmedRules: relevantRules(rules, folders: folders), previous: previous, reviewReason: reason),
            schemaName: "file_proposal",
            schema: Self.proposalSchema
        )
        try validateProposal(result, file: file, folders: folders)
        return result
    }

    /// A local false value returns no candidates and does not contact OpenAI.
    public func suggestRule(from proposal: FileProposal, correctedFolderID: String, correctedName: String, folders: [FolderRecord], applyToFuture: Bool) async throws -> RuleAnalysis {
        guard applyToFuture else { return RuleAnalysis(candidates: []) }
        try validateFolders(folders)
        guard folders.contains(where: { $0.id == correctedFolderID }), Self.isSafeName(correctedName) else {
            throw OpenAIClientError.invalidInput
        }
        let result: RuleAnalysis = try await request(
            task: PromptLibrary.learnCorrection,
            input: CorrectionInput(original: proposal, correctedFolderID: correctedFolderID, correctedName: correctedName, folders: folders),
            schemaName: "folder_rules",
            schema: Self.ruleSchema
        )
        try validateRules(result, folders: folders)
        guard result.candidates.allSatisfy({ $0.folderID == correctedFolderID }) else {
            throw OpenAIClientError.invalidProposal
        }
        return result
    }

    private func request<Input: Encodable, Output: Decodable>(task: String, input: Input, schemaName: String, schema: [String: Any]) async throws -> Output {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OpenAIClientError.missingAPIKey }
        guard apiKey.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { throw OpenAIClientError.invalidInput }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(input)
        guard data.count <= Self.maximumInputBytes else { throw OpenAIClientError.inputTooLarge }
        guard let userData = String(data: data, encoding: .utf8) else { throw OpenAIClientError.invalidInput }
        let body: [String: Any] = [
            "model": Self.model,
            "store": false,
            "reasoning": ["effort": "low"],
            "max_output_tokens": 6_000,
            "input": [
                ["role": "developer", "content": PromptLibrary.common + "\n\n" + task],
                ["role": "user", "content": userData]
            ],
            "text": ["format": ["type": "json_schema", "name": schemaName, "strict": true, "schema": schema]]
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        try Task.checkCancellation()
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Do not propagate transport descriptions that can contain request data.
            throw OpenAIClientError.transportFailure
        }
        guard let http = response as? HTTPURLResponse else { throw OpenAIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // Do not surface the server body, which might echo user content or credentials.
            throw OpenAIClientError.httpFailure(statusCode: http.statusCode)
        }
        guard responseData.count <= 8_000_000,
              let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw OpenAIClientError.invalidResponse
        }
        guard object["status"] as? String == "completed" else { throw OpenAIClientError.incompleteResponse }
        guard let output = object["output"] as? [[String: Any]] else { throw OpenAIClientError.invalidResponse }
        var textParts: [String] = []
        for item in output {
            guard item["type"] as? String == "message" else { continue }
            if let status = item["status"] as? String, status != "completed" {
                throw OpenAIClientError.incompleteResponse
            }
            guard let content = item["content"] as? [[String: Any]] else { throw OpenAIClientError.invalidResponse }
            if content.contains(where: { $0["type"] as? String == "refusal" }) { throw OpenAIClientError.refused }
            if let phase = item["phase"] as? String, phase != "final_answer" { continue }
            for part in content where part["type"] as? String == "output_text" {
                guard let text = part["text"] as? String else { throw OpenAIClientError.invalidResponse }
                textParts.append(text)
            }
        }
        guard !textParts.isEmpty, let resultData = textParts.joined().data(using: .utf8) else {
            throw OpenAIClientError.invalidResponse
        }
        do { return try JSONDecoder().decode(Output.self, from: resultData) }
        catch { throw OpenAIClientError.invalidResponse }
    }

    private func validateFolders(_ folders: [FolderRecord]) throws {
        guard !folders.isEmpty,
              folders.allSatisfy({ !$0.id.isEmpty && !$0.path.isEmpty }),
              Set(folders.map(\.id)).count == folders.count else { throw OpenAIClientError.invalidInput }
    }

    private func validateInput(file: FileEvidence, folders: [FolderRecord]) throws {
        try validateFolders(folders)
        guard !file.id.isEmpty, !file.path.isEmpty else { throw OpenAIClientError.invalidInput }
    }

    private func relevantRules(_ rules: [FolderRule], folders: [FolderRecord]) -> [FolderRule] {
        let ids = Set(folders.map(\.id))
        return rules.filter { $0.confirmed && ids.contains($0.folderID) }
    }

    private func validateRules(_ result: RuleAnalysis, folders: [FolderRecord]) throws {
        let ids = Set(folders.map(\.id))
        guard result.candidates.allSatisfy({ ids.contains($0.folderID) && !$0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw OpenAIClientError.invalidProposal
        }
    }

    private func validateProposal(_ proposal: FileProposal, file: FileEvidence, folders: [FolderRecord]) throws {
        let ids = Set(folders.map(\.id))
        guard proposal.fileID == file.id,
              ["ready", "needsReview", "unclassified"].contains(proposal.status),
              !proposal.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              proposal.alternatives.count <= 3,
              Set(proposal.alternatives.map(\.folderID)).count == proposal.alternatives.count,
              proposal.alternatives.allSatisfy({ ids.contains($0.folderID) && $0.folderID != proposal.destinationFolderID }) else {
            throw OpenAIClientError.invalidProposal
        }
        if let destination = proposal.destinationFolderID, !ids.contains(destination) { throw OpenAIClientError.invalidProposal }
        if proposal.status == "ready", proposal.destinationFolderID == nil || proposal.proposedName == nil { throw OpenAIClientError.invalidProposal }
        if proposal.status == "unclassified", proposal.destinationFolderID != nil { throw OpenAIClientError.invalidProposal }
        if let name = proposal.proposedName {
            guard Self.isSafeName(name) else { throw OpenAIClientError.invalidProposal }
            if !["directory", "folder"].contains(file.kind.lowercased()) {
                let originalExtension = (file.path as NSString).pathExtension
                guard (name as NSString).pathExtension == originalExtension else { throw OpenAIClientError.invalidProposal }
            }
        }
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil
            && name.components(separatedBy: "{serial}").count <= 2
    }

    private static var stringSchema: [String: Any] { ["type": "string"] }
    private static var nullableStringSchema: [String: Any] { ["type": ["string", "null"]] }
    private static var stringsSchema: [String: Any] { ["type": "array", "items": stringSchema] }

    private static func objectSchema(_ properties: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }

    private static var proposalSchema: [String: Any] {
        objectSchema([
            "fileID": stringSchema,
            "status": ["type": "string", "enum": ["ready", "needsReview", "unclassified"]],
            "destinationFolderID": nullableStringSchema,
            "proposedName": nullableStringSchema,
            "reason": stringSchema,
            "evidence": stringsSchema,
            "alternatives": ["type": "array", "items": objectSchema(["folderID": stringSchema, "reason": stringSchema])],
            "missingInformation": stringsSchema
        ])
    }

    private static var ruleSchema: [String: Any] {
        objectSchema(["candidates": ["type": "array", "items": objectSchema([
            "folderID": stringSchema, "instruction": stringSchema, "evidence": stringsSchema, "uncertainties": stringsSchema
        ])]])
    }
}

private struct StructureInput: Encodable { let folders: [FolderRecord] }
private struct ProposalInput: Encodable { let file: FileEvidence; let folders: [FolderRecord]; let confirmedRules: [FolderRule] }
private struct ReanalysisInput: Encodable { let file: FileEvidence; let folders: [FolderRecord]; let confirmedRules: [FolderRule]; let previous: FileProposal; let reviewReason: String }
private struct CorrectionInput: Encodable { let original: FileProposal; let correctedFolderID: String; let correctedName: String; let folders: [FolderRecord] }
