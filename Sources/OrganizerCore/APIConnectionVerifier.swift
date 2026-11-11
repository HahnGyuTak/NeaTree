import Foundation

public struct APIVerificationUsage: Codable, Sendable, Equatable {
    public let stage: String
    public let httpStatus: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
}

public struct APIVerificationCheck: Codable, Sendable, Equatable {
    public let stage: String
    public let passed: Bool
    public let detail: String
}

public struct APIVerificationReport: Codable, Sendable, Equatable {
    public let model: String
    public let passed: Bool
    public let requestsAttempted: Int
    public let maximumRequests: Int
    public let maxOutputTokensPerRequest: Int
    public let checks: [APIVerificationCheck]
    public let usage: [APIVerificationUsage]
    public let scope: String
}

/// Opt-in live check using fixed synthetic data, not the user's catalog/files.
/// It makes at most two requests, stops after a failure and never retries.
public enum APIConnectionVerifier {
    public static let maximumRequests = 2
    public static let maxOutputTokensPerRequest = 1_536

    public static func verify(apiKey: String, session: URLSession = .shared) async throws -> APIVerificationReport {
        try await verify(apiKey: apiKey, transport: { request in try await session.data(for: request) })
    }

    static func verify(apiKey: String,
                       transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws -> APIVerificationReport {
        let recorder = VerificationRecorder()
        let client = OpenAIClient(apiKey: apiKey, maxOutputTokens: maxOutputTokensPerRequest, transport: { request in
            try Task.checkCancellation()
            let stage = try await recorder.beginRequest()
            do {
                let result = try await transport(request)
                await recorder.finish(stage: stage, data: result.0, response: result.1)
                return result
            } catch {
                await recorder.finish(stage: stage, data: nil, response: nil)
                throw error
            }
        })
        let folders = [
            FolderRecord(id: "verification-invoices", path: "/NeaTreeVerification/Invoices",
                         sampleNames: ["001_2026-01-10_invoice.pdf", "002_2026-02-10_invoice.pdf"]),
            FolderRecord(id: "verification-meetings", path: "/NeaTreeVerification/Meetings",
                         sampleNames: ["2026-02-12_meeting-notes.txt"])
        ]
        var checks: [APIVerificationCheck] = []
        do {
            let rules = try await client.analyzeStructure(folders: folders)
            let passed = !rules.candidates.isEmpty
            checks.append(APIVerificationCheck(stage: "structure", passed: passed,
                detail: passed ? "합성 폴더 목록에서 유효한 규칙 후보 응답을 받았습니다." : "응답 형식은 유효하지만 규칙 후보가 비어 있습니다."))
        } catch is CancellationError { throw CancellationError() }
        catch {
            checks.append(APIVerificationCheck(stage: "structure", passed: false, detail: safeDetail(error)))
        }
        if checks.last?.passed == true {
            let file = FileEvidence(id: "verification-invoice-1", path: "/NeaTreeVerification/Incoming/source.pdf",
                kind: "pdf", byteCount: 128, modifiedAt: Date(timeIntervalSince1970: 0),
                extractedText: "합성 검증 문서. INVOICE — 2026-03-10. 공급자: 예시 회사. 청구 금액: 100.00. 실제 개인 자료가 아닙니다.",
                readStatus: "full")
            let rules = [
                FolderRule(id: "verification-rule-invoice", folderID: "verification-invoices",
                           instruction: "청구서와 INVOICE 문서를 보관한다. 파일명은 {serial}_YYYY-MM-DD_invoice.pdf 형식이다.", confirmed: true),
                FolderRule(id: "verification-rule-meetings", folderID: "verification-meetings",
                           instruction: "회의록만 보관한다. 청구서는 이 폴더에 넣지 않는다.", confirmed: true)
            ]
            do {
                let proposal = try await client.propose(file: file, folders: folders, rules: rules)
                let passed = proposal.status == "ready" && proposal.destinationFolderID == "verification-invoices"
                checks.append(APIVerificationCheck(stage: "proposal", passed: passed,
                    detail: passed ? "합성 청구서에 대해 허용된 청구서 폴더와 유효한 파일명을 제안했습니다." : "응답 형식은 유효하지만 합성 청구서의 기대 분류와 일치하지 않습니다."))
            } catch is CancellationError { throw CancellationError() }
            catch {
                checks.append(APIVerificationCheck(stage: "proposal", passed: false, detail: safeDetail(error)))
            }
        }
        let snapshot = await recorder.snapshot()
        return APIVerificationReport(model: OpenAIClient.model,
            passed: checks.count == 2 && checks.allSatisfy(\.passed), requestsAttempted: snapshot.count,
            maximumRequests: maximumRequests, maxOutputTokensPerRequest: maxOutputTokensPerRequest,
            checks: checks, usage: snapshot.usage,
            scope: "합성 자료만 이용한 모델 접근·구조화 응답·기초 분류 검증. 파일 읽기·이동·설정 변경 없음. 토큰 사용량은 요금 한도가 아니며 전체 분류 품질을 보증하지 않습니다.")
    }

    private static func safeDetail(_ error: Error) -> String {
        // OpenAIClient's errors deliberately omit server bodies and credentials.
        (error as? OpenAIClientError)?.localizedDescription ?? "API 검증을 완료하지 못했습니다."
    }
}

private actor VerificationRecorder {
    private var attempts = 0
    private var usage: [APIVerificationUsage] = []

    func beginRequest() throws -> String {
        guard attempts < APIConnectionVerifier.maximumRequests else { throw OpenAIClientError.invalidInput }
        attempts += 1
        return attempts == 1 ? "structure" : "proposal"
    }

    func finish(stage: String, data: Data?, response: URLResponse?) {
        let http = response as? HTTPURLResponse
        var input: Int?, output: Int?, total: Int?
        if let data, data.count <= 8_000_000, let http, (200..<300).contains(http.statusCode),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = object["usage"] as? [String: Any] {
            func count(_ key: String) -> Int? {
                guard let value = tokens[key] as? Int, value >= 0 else { return nil }
                return value
            }
            input = count("input_tokens"); output = count("output_tokens"); total = count("total_tokens")
        }
        usage.append(APIVerificationUsage(stage: stage, httpStatus: http?.statusCode,
                                          inputTokens: input, outputTokens: output, totalTokens: total))
    }

    func snapshot() -> (count: Int, usage: [APIVerificationUsage]) { (attempts, usage) }
}
