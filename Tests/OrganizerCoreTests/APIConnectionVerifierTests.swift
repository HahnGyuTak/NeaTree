import Foundation
import Testing
@testable import OrganizerCore

@Suite("Bounded synthetic API verification", .timeLimit(.minutes(1)))
struct APIConnectionVerifierTests {
    @Test func successfulVerificationUsesTwoBoundedRequestsAndReportsUsage() async throws {
        let recorder = VerificationTransportFixture()
        let report = try await APIConnectionVerifier.verify(apiKey: "dummy-verification-key", transport: recorder.respond)
        #expect(report.passed)
        #expect(report.requestsAttempted == 2)
        #expect(report.maximumRequests == 2)
        #expect(report.maxOutputTokensPerRequest == 1_536)
        #expect(report.usage.map(\.inputTokens) == [80, 90])
        #expect(report.usage.map(\.outputTokens) == [20, 30])
        let requests = await recorder.requests
        #expect(requests.count == 2)
        for request in requests {
            let data = try #require(request.httpBody)
            let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["max_output_tokens"] as? Int == 1_536)
            #expect(body["store"] as? Bool == false)
            #expect(body["model"] as? String == OpenAIClient.model)
            let input = try #require(body["input"] as? [[String: Any]])
            let inputText = try #require(input.last?["content"] as? String)
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(inputText.utf8)) as? [String: Any])
            let folders = try #require(payload["folders"] as? [[String: Any]])
            #expect(folders.allSatisfy { ($0["path"] as? String)?.hasPrefix("/NeaTreeVerification/") == true })
        }
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!encoded.contains("dummy-verification-key"))
    }

    @Test func authenticationFailureStopsAfterOneAttemptAndRedactsProviderBody() async throws {
        let recorder = VerificationTransportFixture(failureStatus: 401)
        let report = try await APIConnectionVerifier.verify(apiKey: "dummy-verification-key", transport: recorder.respond)
        #expect(!report.passed)
        #expect(report.requestsAttempted == 1)
        #expect(report.checks.count == 1)
        #expect(report.usage.first?.httpStatus == 401)
        #expect(await recorder.requests.count == 1)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE_PROVIDER_BODY"))
        #expect(!encoded.contains("dummy-verification-key"))
    }

    @Test func missingCredentialMakesNoRequest() async throws {
        let recorder = VerificationTransportFixture()
        let report = try await APIConnectionVerifier.verify(apiKey: "", transport: recorder.respond)
        #expect(!report.passed)
        #expect(report.requestsAttempted == 0)
        #expect(await recorder.requests.isEmpty)
    }

    @Test func validJSONWithWrongClassificationFailsSemanticCheck() async throws {
        let recorder = VerificationTransportFixture(wrongDestination: true)
        let report = try await APIConnectionVerifier.verify(apiKey: "dummy-verification-key", transport: recorder.respond)
        #expect(!report.passed)
        #expect(report.checks.first?.passed == true)
        #expect(report.checks.last?.stage == "proposal")
        #expect(report.checks.last?.passed == false)
        #expect(report.requestsAttempted == 2)
    }

    @Test func cancellationIsNotTurnedIntoACompletedReport() async throws {
        do {
            _ = try await APIConnectionVerifier.verify(apiKey: "dummy-verification-key", transport: { _ in throw CancellationError() })
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func invalidOutputTokenLimitsAreRejectedBeforeTransport() async throws {
        for maximum in [0, -1, 6_001] {
            let recorder = VerificationTransportFixture()
            let client = OpenAIClient(apiKey: "dummy-verification-key", maxOutputTokens: maximum, transport: recorder.respond)
            do {
                _ = try await client.analyzeStructure(folders: [FolderRecord(id: "fixture", path: "/Fixture", sampleNames: [])])
                Issue.record("Expected invalid configuration")
            } catch { #expect(error as? OpenAIClientError == .invalidInput) }
            #expect(await recorder.requests.isEmpty)
        }
    }
}

private actor VerificationTransportFixture {
    private(set) var requests: [URLRequest] = []
    let failureStatus: Int?
    let wrongDestination: Bool
    init(failureStatus: Int? = nil, wrongDestination: Bool = false) {
        self.failureStatus = failureStatus
        self.wrongDestination = wrongDestination
    }
    func respond(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let status = failureStatus ?? 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        if failureStatus != nil {
            return (try JSONSerialization.data(withJSONObject: ["error": ["message": "PRIVATE_PROVIDER_BODY dummy-verification-key"]]), response)
        }
        let payload: [String: Any]
        if requests.count == 1 {
            payload = ["candidates": [["folderID": "verification-invoices", "instruction": "청구서에 순번과 날짜를 사용한다.", "evidence": ["001_2026-01-10_invoice.pdf"], "uncertainties": []]]]
        } else {
            payload = ["fileID": "verification-invoice-1", "status": "ready",
                       "destinationFolderID": wrongDestination ? "verification-meetings" : "verification-invoices",
                       "proposedName": "{serial}_2026-03-10_invoice.pdf", "reason": "합성 청구서",
                       "evidence": ["INVOICE"], "alternatives": [], "missingInformation": []]
        }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let body: [String: Any] = ["status": "completed",
            "output": [["type": "message", "status": "completed", "content": [["type": "output_text", "text": text]]]],
            "usage": ["input_tokens": requests.count == 1 ? 80 : 90,
                      "output_tokens": requests.count == 1 ? 20 : 30, "total_tokens": requests.count == 1 ? 100 : 120]]
        return (try JSONSerialization.data(withJSONObject: body), response)
    }
}
