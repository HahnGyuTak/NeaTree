import Foundation
import Darwin

public enum InboxStatus: String, Codable, Sendable, CaseIterable {
    case pending, ready, held, proposed, applied, unclassified, failed, missing
}

public struct InboxEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let path: String
    public var fingerprint: String
    public var status: InboxStatus
    public let createdAt: Date
    public var updatedAt: Date
    public var note: String?
    public var proposal: FileProposal?
    public var stableSince: Date
    public var stableObservations: Int

    init(path: String, fingerprint: String, status: InboxStatus, now: Date) {
        self.id = UUID(); self.path = path; self.fingerprint = fingerprint; self.status = status
        self.createdAt = now; self.updatedAt = now; self.note = nil; self.proposal = nil
        self.stableSince = now; self.stableObservations = 1
    }
}

public enum InboxError: Error, LocalizedError {
    case unknownEntry
    case staleFile
    case invalidTransition
    case invalidStore
    case excludedItem
    case concurrentWrite
    public var errorDescription: String? {
        switch self {
        case .unknownEntry: return "검토함에서 항목을 찾을 수 없습니다."
        case .staleFile: return "분석 이후 파일이 변경되었습니다. 다시 분석해 주세요."
        case .invalidTransition: return "현재 상태에서는 이 작업을 할 수 없습니다."
        case .invalidStore: return "검토함 저장소 형식이 올바르지 않습니다."
        case .excludedItem: return "감시에서 제외된 항목입니다."
        case .concurrentWrite: return "다른 실행에서 검토함이 변경되었습니다. 다시 열어 주세요."
        }
    }
}

/// Persistent inbox and polling state. The caller schedules poll; this actor starts no background work.
public actor InboxStore {
    private struct Document: Codable {
        var version: Int = 1
        var entries: [InboxEntry]
    }
    private let storeURL: URL
    private let lockURL: URL
    private let settleInterval: TimeInterval
    private let excludedExtensions: Set<String>
    private var items: [InboxEntry]
    private var committedItems: [InboxEntry]
    private var committedData: Data?

    public init(stateDirectory: URL, settleInterval: TimeInterval = 2, excludedExtensions: Set<String> = []) throws {
        self.storeURL = stateDirectory.appendingPathComponent("inbox.json")
        self.lockURL = stateDirectory.appendingPathComponent("inbox.lock")
        self.settleInterval = max(0, settleInterval)
        self.excludedExtensions = Set(excludedExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: storeURL.path) {
            guard try storeURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw InboxError.invalidStore
            }
            let bytes = try Data(contentsOf: storeURL)
            let document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.version == 1 else { throw InboxError.invalidStore }
            self.items = document.entries
            self.committedItems = document.entries
            self.committedData = bytes
        } else { self.items = []; self.committedItems = []; self.committedData = nil }
    }

    public func entries() -> [InboxEntry] { items.sorted { $0.createdAt < $1.createdAt } }

    /// Explicit import is ready immediately. Subsequent mutation is checked before recording a proposal.
    @discardableResult
    public func add(url: URL, now: Date = Date()) throws -> InboxEntry {
        let url = try CatalogPaths.checked(url)
        guard !CatalogPaths.isExcludedLocation(url) else { throw CatalogError.unsupportedLocation(url.path) }
        let fingerprint = try CatalogPaths.fingerprint(url)
        if let index = items.firstIndex(where: { $0.path == url.path }) {
            if items[index].fingerprint == fingerprint && items[index].status != .missing { return items[index] }
            items[index].fingerprint = fingerprint
            items[index].status = .ready
            items[index].proposal = nil
            items[index].updatedAt = now
            items[index].stableSince = now
            items[index].stableObservations = 2
            items[index].note = "다시 가져온 파일"
            try persist()
            return items[index]
        }
        let entry = InboxEntry(path: url.path, fingerprint: fingerprint, status: .ready, now: now)
        items.append(entry)
        try persist()
        return entry
    }

    /// Returns only newly ready items. Direct children are kept as units, including directories.
    public func poll(downloads: URL, now: Date = Date()) throws -> [InboxEntry] {
        let downloads = try CatalogPaths.checked(downloads)
        guard !CatalogPaths.isExcludedLocation(downloads),
              try downloads.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CatalogError.unsupportedLocation(downloads.path)
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: downloads, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ).map(\.standardizedFileURL).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var present = Set<String>()
        var becameReady: [InboxEntry] = []
        for child in children {
            guard !isExcluded(child) else { continue }
            present.insert(child.path)
            do {
                guard try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw CatalogError.symbolicLink(child.path)
                }
                let fingerprint = try CatalogPaths.fingerprint(child)
                if let index = items.firstIndex(where: { $0.path == child.path }) {
                    if items[index].fingerprint != fingerprint || [.missing, .failed].contains(items[index].status) {
                        let wasHeld = items[index].status == .held
                        items[index].fingerprint = fingerprint
                        items[index].status = wasHeld ? .held : .pending
                        items[index].proposal = nil
                        items[index].stableSince = now
                        items[index].stableObservations = 1
                        items[index].updatedAt = now
                        items[index].note = "파일 변경 감지"
                    } else if items[index].status == .pending {
                        items[index].stableObservations += 1
                        if items[index].stableObservations >= 2,
                           now.timeIntervalSince(items[index].stableSince) >= settleInterval {
                            items[index].status = .ready
                            items[index].updatedAt = now
                            items[index].note = nil
                            becameReady.append(items[index])
                        }
                    }
                } else {
                    items.append(InboxEntry(path: child.path, fingerprint: fingerprint, status: .pending, now: now))
                }
            } catch {
                // A single unreadable/oversized file must not disable the entire downloads queue.
                if let index = items.firstIndex(where: { $0.path == child.path }) {
                    if ![.applied, .unclassified, .held].contains(items[index].status) {
                        items[index].status = .failed
                        items[index].proposal = nil
                        items[index].updatedAt = now
                        items[index].note = error.localizedDescription
                    }
                } else {
                    var entry = InboxEntry(path: child.path, fingerprint: "", status: .failed, now: now)
                    entry.note = error.localizedDescription
                    items.append(entry)
                }
            }
        }
        for index in items.indices {
            let parent = URL(fileURLWithPath: items[index].path).deletingLastPathComponent().path
            if parent == downloads.path, !present.contains(items[index].path),
               ![.applied, .unclassified, .missing].contains(items[index].status) {
                items[index].status = .missing
                items[index].proposal = nil
                items[index].updatedAt = now
                items[index].note = "현재 위치에 파일이 없습니다."
            }
        }
        try persist()
        return becameReady
    }

    public func setStatus(id: UUID, status: InboxStatus, note: String? = nil) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw InboxError.unknownEntry }
        guard status != .proposed else { throw InboxError.invalidTransition }
        if status == .ready {
            let fingerprint = try CatalogPaths.fingerprint(URL(fileURLWithPath: items[index].path))
            guard fingerprint == items[index].fingerprint else { throw InboxError.staleFile }
        }
        items[index].status = status
        items[index].note = note
        items[index].updatedAt = Date()
        if status != .proposed { items[index].proposal = nil }
        try persist()
    }

    public func recordProposal(id: UUID, proposal: FileProposal) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw InboxError.unknownEntry }
        guard [.ready, .proposed].contains(items[index].status) else { throw InboxError.invalidTransition }
        let url = URL(fileURLWithPath: items[index].path)
        guard proposal.fileID == CatalogPaths.identifier(url),
              try CatalogPaths.fingerprint(url) == items[index].fingerprint else { throw InboxError.staleFile }
        items[index].proposal = proposal
        items[index].status = .proposed
        items[index].updatedAt = Date()
        try persist()
    }

    private func isExcluded(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(".") || name == "미분류"
            || ["download", "crdownload", "part", "partial", "tmp"].contains(url.pathExtension.lowercased())
            || excludedExtensions.contains(url.pathExtension.lowercased())
            || CatalogPaths.isExcludedLocation(url)
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw InboxError.invalidStore }
            defer { _ = Darwin.close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw InboxError.invalidStore }
            defer { _ = flock(fd, LOCK_UN) }
            let exists = FileManager.default.fileExists(atPath: storeURL.path)
            if exists {
                guard try storeURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                      try Data(contentsOf: storeURL) == committedData else { throw InboxError.concurrentWrite }
            } else if committedData != nil { throw InboxError.concurrentWrite }
            let bytes = try encoder.encode(Document(entries: items))
            try bytes.write(to: storeURL, options: [.atomic])
            committedItems = items
            committedData = bytes
        } catch {
            items = committedItems
            throw error
        }
    }
}
