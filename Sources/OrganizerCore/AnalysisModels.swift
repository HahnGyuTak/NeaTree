import Foundation

public struct FolderRecord: Codable, Sendable, Equatable {
    public let id: String
    public let path: String
    public let sampleNames: [String]
    public init(id: String, path: String, sampleNames: [String]) {
        self.id = id; self.path = path; self.sampleNames = sampleNames
    }
}

public struct FileEvidence: Codable, Sendable, Equatable {
    public let id: String
    public let path: String
    public let kind: String
    public let byteCount: Int64
    public let modifiedAt: Date
    public let extractedText: String
    public let readStatus: String
    public init(id: String, path: String, kind: String, byteCount: Int64, modifiedAt: Date, extractedText: String, readStatus: String) {
        self.id = id; self.path = path; self.kind = kind; self.byteCount = byteCount
        self.modifiedAt = modifiedAt; self.extractedText = extractedText; self.readStatus = readStatus
    }
}

public struct FolderRule: Codable, Sendable, Equatable {
    public let id: String
    public let folderID: String
    public let instruction: String
    public let confirmed: Bool
    public init(id: String, folderID: String, instruction: String, confirmed: Bool) {
        self.id = id; self.folderID = folderID; self.instruction = instruction; self.confirmed = confirmed
    }
}

public struct ProposalAlternative: Codable, Sendable, Equatable {
    public let folderID: String
    public let reason: String
    public init(folderID: String, reason: String) { self.folderID = folderID; self.reason = reason }
}

public struct FileProposal: Codable, Sendable, Equatable {
    public let fileID: String
    public let status: String
    public let destinationFolderID: String?
    public let proposedName: String?
    public let reason: String
    public let evidence: [String]
    public let alternatives: [ProposalAlternative]
    public let missingInformation: [String]
    public init(fileID: String, status: String, destinationFolderID: String?, proposedName: String?, reason: String, evidence: [String], alternatives: [ProposalAlternative], missingInformation: [String]) {
        self.fileID = fileID; self.status = status; self.destinationFolderID = destinationFolderID
        self.proposedName = proposedName; self.reason = reason; self.evidence = evidence
        self.alternatives = alternatives; self.missingInformation = missingInformation
    }
}

public struct RuleCandidate: Codable, Sendable, Equatable {
    public let folderID: String
    public let instruction: String
    public let evidence: [String]
    public let uncertainties: [String]
    public init(folderID: String, instruction: String, evidence: [String], uncertainties: [String]) {
        self.folderID = folderID; self.instruction = instruction; self.evidence = evidence; self.uncertainties = uncertainties
    }
}

public struct RuleAnalysis: Codable, Sendable, Equatable {
    public let candidates: [RuleCandidate]
    public init(candidates: [RuleCandidate]) { self.candidates = candidates }
}
