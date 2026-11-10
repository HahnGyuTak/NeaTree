import Darwin
import Foundation

/// User opt-ins and bounded retry bookkeeping. API credentials never belong here.
public struct AppPreferences: Codable, Equatable, Sendable {
    public var version = 1
    public var watchEnabled = false
    public var automaticAnalysis = false
    public var attemptedFingerprints: [String: String] = [:]
    public var reviewDrafts: [String: ReviewDraft] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, watchEnabled, automaticAnalysis, attemptedFingerprints, reviewDrafts
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        watchEnabled = try values.decodeIfPresent(Bool.self, forKey: .watchEnabled) ?? false
        automaticAnalysis = try values.decodeIfPresent(Bool.self, forKey: .automaticAnalysis) ?? false
        attemptedFingerprints = try values.decodeIfPresent([String: String].self, forKey: .attemptedFingerprints) ?? [:]
        reviewDrafts = try values.decodeIfPresent([String: ReviewDraft].self, forKey: .reviewDrafts) ?? [:]
    }
}

struct AppPreferenceStore {
    private let url: URL
    private let lockURL: URL
    private var committedData: Data?

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("preferences.json")
        lockURL = directory.appendingPathComponent("preferences.lock")
        if FileManager.default.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw AppPreferenceError.invalidStore
            }
            committedData = try Data(contentsOf: url)
        }
    }

    func load() throws -> AppPreferences {
        guard let committedData else { return AppPreferences() }
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: committedData)
        guard preferences.version == 1 else { throw AppPreferenceError.invalidStore }
        return preferences
    }

    mutating func save(_ preferences: AppPreferences) throws {
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AppPreferenceError.invalidStore }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw AppPreferenceError.invalidStore }
        defer { flock(descriptor, LOCK_UN) }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  try Data(contentsOf: url) == committedData else { throw AppPreferenceError.concurrentWrite }
        } else if committedData != nil { throw AppPreferenceError.concurrentWrite }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        try data.write(to: url, options: .atomic)
        committedData = data
    }
}

enum AppPreferenceError: LocalizedError {
    case invalidStore, concurrentWrite
    var errorDescription: String? {
        switch self {
        case .invalidStore: "앱 환경설정을 읽거나 저장하지 못했습니다."
        case .concurrentWrite: "다른 실행에서 환경설정이 변경되었습니다. 앱을 다시 열어 주세요."
        }
    }
}
