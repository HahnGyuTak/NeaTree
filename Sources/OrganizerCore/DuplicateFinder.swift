import Foundation

public struct DuplicateReport: Codable, Sendable, Equatable {
    public let matches: [String]
    /// Regular files successfully compared, including files ruled out by their byte size.
    public let checkedCount: Int
    /// Hidden/link/non-file entries or unreadable candidates excluded from the comparison.
    public let skippedCount: Int
    /// True if a limit, inaccessible folder, or failed comparison left eligible files unchecked.
    public let truncated: Bool

    public init(matches: [String], checkedCount: Int, skippedCount: Int, truncated: Bool) {
        self.matches = matches; self.checkedCount = checkedCount
        self.skippedCount = skippedCount; self.truncated = truncated
    }
}

public enum DuplicateFinderError: Error, LocalizedError {
    case unsupportedSource
    case sourceChanged
    case invalidLimit

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource: return "정확한 중복 비교는 일반 파일만 지원합니다. 폴더는 비교하지 않습니다."
        case .sourceChanged: return "중복 비교 중 원본 파일이 변경되었습니다. 다시 확인해 주세요."
        case .invalidLimit: return "중복 비교할 파일 수는 0 이상이어야 합니다."
        }
    }
}

/// Searches only the direct children of explicitly supplied catalog folders, without modifying files.
public enum DuplicateFinder {
    public static func findAsync(for source: URL, in folders: [FolderRecord], maximumFiles: Int = 1_000) async throws -> DuplicateReport {
        try await FileMetadataWorker.run { try find(for: source, in: folders, maximumFiles: maximumFiles) }
    }

    public static func find(for source: URL, in folders: [FolderRecord], maximumFiles: Int = 1_000) throws -> DuplicateReport {
        guard maximumFiles >= 0 else { throw DuplicateFinderError.invalidLimit }
        let source = try checkedUnredirected(source)
        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard sourceValues.isRegularFile == true else { throw DuplicateFinderError.unsupportedSource }
        let sourceFingerprint = try CatalogPaths.fingerprint(source)
        var matches: [String] = []
        var checkedCount = 0
        var skippedCount = 0
        var truncated = false
        var attemptedCount = 0
        var seenFolders = Set<String>()
        var seenFiles = Set<String>()

        for record in folders {
            let folder: URL
            let children: [URL]
            do {
                folder = try checkedUnredirected(URL(fileURLWithPath: record.path))
                guard seenFolders.insert(folder.path).inserted else { continue }
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                guard values.isDirectory == true, values.isPackage != true else {
                    throw CatalogError.unsupportedLocation(folder.path)
                }
                children = try FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                ).map(\.standardizedFileURL).sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch {
                skippedCount += 1
                truncated = true
                continue
            }

            for child in children {
                // Excluding the source is not counted as a skipped search candidate.
                guard child.path != source.path, seenFiles.insert(child.path).inserted else { continue }
                if child.lastPathComponent.hasPrefix(".") {
                    skippedCount += 1
                    continue
                }
                do {
                    let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isSymbolicLink != true, values.isRegularFile == true else {
                        skippedCount += 1
                        continue
                    }
                    guard attemptedCount < maximumFiles else {
                        skippedCount += 1
                        truncated = true
                        continue
                    }
                    attemptedCount += 1
                    let checkedChild = try checkedUnredirected(child)
                    guard checkedChild.deletingLastPathComponent().path == folder.path else {
                        throw CatalogError.symbolicLink(child.path)
                    }
                    if values.fileSize == sourceValues.fileSize,
                       try CatalogPaths.fingerprint(checkedChild) == sourceFingerprint {
                        matches.append(checkedChild.path)
                    }
                    checkedCount += 1
                } catch {
                    skippedCount += 1
                    truncated = true
                }
            }
        }

        guard try CatalogPaths.fingerprint(source) == sourceFingerprint else {
            throw DuplicateFinderError.sourceChanged
        }
        return DuplicateReport(matches: matches.sorted(), checkedCount: checkedCount,
                               skippedCount: skippedCount, truncated: truncated)
    }

    private static func checkedUnredirected(_ url: URL) throws -> URL {
        let checked = try CatalogPaths.checked(url)
        guard checked.path == url.standardizedFileURL.path else { throw CatalogError.symbolicLink(url.path) }
        guard !CatalogPaths.isExcludedLocation(checked) else { throw CatalogError.unsupportedLocation(checked.path) }
        return checked
    }
}
