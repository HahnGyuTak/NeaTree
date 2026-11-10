import Foundation
import OrganizerCore

/// Editable values and the exact evidence the user reviewed are saved together.
public struct ReviewDraft: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { itemID }
    public let itemID: UUID
    public var name: String
    public var folderID: String
    public var serialWidth: Int?
    public var fillGaps: Bool
    public var learnForFuture: Bool
    public let reviewedFingerprint: String
    public let reviewedProposal: FileProposal?
    public let reviewedConfigurationRevision: UUID
    public let reviewedProposalRevision: UUID?

    public init(itemID: UUID, name: String, folderID: String, serialWidth: Int? = nil, fillGaps: Bool = false, learnForFuture: Bool = false, reviewedFingerprint: String, reviewedProposal: FileProposal?, reviewedConfigurationRevision: UUID, reviewedProposalRevision: UUID?) {
        self.itemID = itemID
        self.name = name
        self.folderID = folderID
        self.serialWidth = serialWidth
        self.fillGaps = fillGaps
        self.learnForFuture = learnForFuture
        self.reviewedFingerprint = reviewedFingerprint
        self.reviewedProposal = reviewedProposal
        self.reviewedConfigurationRevision = reviewedConfigurationRevision
        self.reviewedProposalRevision = reviewedProposalRevision
    }
}

public enum BatchAction: String, Codable, Sendable {
    case review, apply, hold, unclassified, undo
}

public struct BatchItemResult: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var itemID: UUID { id }
    public let action: BatchAction
    public let succeeded: Bool
    public let message: String
    public let operationID: UUID?

    public init(itemID: UUID, action: BatchAction, succeeded: Bool, message: String, operationID: UUID? = nil) {
        id = itemID
        self.action = action
        self.succeeded = succeeded
        self.message = message
        self.operationID = operationID
    }
}
