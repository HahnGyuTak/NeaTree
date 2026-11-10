import Foundation
import CryptoKit
import PDFKit

public enum CatalogError: Error, LocalizedError, Equatable {
    case unsupportedLocation(String)
    case symbolicLink(String)
    case notFound(String)
    case inspectionLimit(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocation(let path): return "분석 대상에서 제외된 위치입니다: \(path)"
        case .symbolicLink(let path): return "심볼릭 링크는 분석하지 않습니다: \(path)"
        case .notFound(let path): return "파일을 찾을 수 없습니다: \(path)"
        case .inspectionLimit(let path): return "분석 범위를 초과했습니다: \(path)"
        }
    }
}

/// Read-only, bounded folder inventory. File names are samples, not a complete index.
public enum CatalogBuilder {
    /// Foundation package metadata may wait on work scheduled outside Swift's cooperative pool.
    /// Async callers use a dedicated dispatch worker so those waits cannot exhaust task executors.
    public static func scanAsync(roots: [URL], maxFolders: Int = 500) async throws -> [FolderRecord] {
        try await FileMetadataWorker.run { try scan(roots: roots, maxFolders: maxFolders) }
    }

    public static func scan(roots: [URL], maxFolders: Int = 500) throws -> [FolderRecord] {
        guard maxFolders > 0 else { return [] }
        var queue: [(URL, Int)] = []
        for root in roots {
            let root = try CatalogPaths.checked(root)
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values.isDirectory == true, values.isPackage != true,
                  !CatalogPaths.isExcludedLocation(root) else {
                throw CatalogError.unsupportedLocation(root.path)
            }
            queue.append((root, 0))
        }
        let authorizedRoots = queue.map { $0.0.path }
        var result: [FolderRecord] = []
        var seen = Set<String>()
        var cursor = 0
        while cursor < queue.count && result.count < maxFolders {
            let (folder, depth) = queue[cursor]
            cursor += 1
            guard seen.insert(folder.path).inserted else { continue }
            let current = try CatalogPaths.checked(folder)
            guard current.path == folder.path,
                  authorizedRoots.contains(where: { current.path == $0 || current.path.hasPrefix($0 + "/") }) else {
                throw CatalogError.symbolicLink(folder.path)
            }
            let children = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                options: [.skipsHiddenFiles]
            ).map(\.standardizedFileURL).sorted { $0.lastPathComponent < $1.lastPathComponent }
            var sampleNames: [String] = []
            for child in children.prefix(2_000) {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                guard values.isSymbolicLink != true, !CatalogPaths.isExcludedLocation(child) else { continue }
                if values.isDirectory == true && values.isPackage != true {
                    if depth < 12, queue.count < maxFolders * 4 { queue.append((child, depth + 1)) }
                } else if sampleNames.count < 30 {
                    sampleNames.append(child.lastPathComponent)
                }
            }
            result.append(FolderRecord(id: CatalogPaths.identifier(folder), path: folder.path, sampleNames: sampleNames))
        }
        return result
    }
}

public enum FileInspector {
    public static func inspectAsync(_ url: URL) async throws -> FileEvidence {
        try await FileMetadataWorker.run { try inspect(url) }
    }

    /// Extracts up to 128 KiB of text, the first 12 PDF pages, or a shallow folder listing.
    public static func inspect(_ url: URL) throws -> FileEvidence {
        let url = try CatalogPaths.checked(url)
        guard !CatalogPaths.isExcludedLocation(url) else { throw CatalogError.unsupportedLocation(url.path) }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey])
        let size = Int64(values.fileSize ?? 0)
        let modified = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        var text = ""
        var readStatus = "unsupported"
        var kind = url.pathExtension.lowercased()
        if values.isDirectory == true {
            kind = values.isPackage == true ? "package" : "folder"
            if values.isPackage != true {
                let children = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
                ).map(\.standardizedFileURL).sorted { $0.lastPathComponent < $1.lastPathComponent }
                var names: [String] = []
                for child in children.prefix(100) {
                    if try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true {
                        names.append(child.lastPathComponent)
                    }
                }
                text = names.joined(separator: "\n")
                readStatus = children.count > 100 ? "partial_directory_listing" : "directory_listing"
            }
        } else if kind == "pdf" {
            if size > 64 * 1_024 * 1_024 {
                readStatus = "oversized_pdf"
            } else if let document = PDFDocument(url: url) {
                if document.isLocked {
                    readStatus = "locked_pdf"
                } else {
                    let pageLimit = min(document.pageCount, 12)
                    text = (0..<pageLimit).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
                    let truncated = text.count > 32_000
                    if truncated { text = String(text.prefix(32_000)) }
                    readStatus = text.isEmpty ? "no_text_extracted" : (document.pageCount > pageLimit || truncated ? "partial_text" : "full_text")
                }
            } else { readStatus = "unreadable_pdf" }
        } else if ["txt", "md", "csv", "tsv", "json", "yaml", "yml", "xml", "html", "htm", "log", "rtf"].contains(kind) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 131_072) ?? Data()
            if let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") {
                text = decoded
                readStatus = size > Int64(data.count) ? "partial_text" : "full_text"
            } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
                      let decoded = String(data: data, encoding: .utf16) {
                text = decoded
                readStatus = size > Int64(data.count) ? "partial_text" : "full_text"
            } else if size > Int64(data.count), !data.contains(0) {
                // A UTF-8 sequence can be split at the extraction limit.
                text = String(decoding: data, as: UTF8.self)
                readStatus = "partial_text"
            } else { readStatus = "unreadable_text" }
        }
        return FileEvidence(id: CatalogPaths.identifier(url), path: url.path, kind: kind,
                            byteCount: size, modifiedAt: modified, extractedText: text, readStatus: readStatus)
    }
}

enum FileMetadataWorker {
    private static let queue = DispatchQueue(label: "FileOrganizer.file-metadata", qos: .utility,
                                             attributes: .concurrent, autoreleaseFrequency: .workItem)

    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let value: Value = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return value
    }
}

enum CatalogPaths {
    static func identifier(_ url: URL) -> String {
        // APFS can enumerate decomposed names while drag/drop supplies NFC.
        // Canonically equivalent paths must share the same persisted identifier.
        let canonicalPath = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        return "path_" + SHA256.hash(data: Data(canonicalPath.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func checked(_ input: URL) throws -> URL {
        guard input.isFileURL else { throw CatalogError.unsupportedLocation(input.absoluteString) }
        let url = input.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { throw CatalogError.notFound(url.path) }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CatalogError.symbolicLink(url.path) }
        return url.resolvingSymlinksInPath()
    }

    static func isExcludedLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path == "/" { return true }
        let excluded = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/dev", "/cores"]
        if excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        let components = url.pathComponents
        if components.count >= 4, components[1] == "Users", components[3] == "Library" { return true }
        return false
    }

    /// A complete snapshot of regular file bytes and directory structure; limits fail closed.
    /// Folder metadata is also included so in-progress writes reset the settle timer.
    static func fingerprint(_ input: URL) throws -> String {
        let root = try checked(input)
        var hash = SHA256()
        var byteBudget = 64 * 1_024 * 1_024
        var nodeBudget = 5_000
        func append(_ value: String) { hash.update(data: Data((value + "\0").utf8)) }
        func walk(_ url: URL, relative: String, depth: Int) throws {
            nodeBudget -= 1
            guard nodeBudget >= 0, depth <= 24 else { throw CatalogError.inspectionLimit(root.path) }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw CatalogError.symbolicLink(url.path) }
            append(relative)
            if values.isDirectory == true {
                append("directory")
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .map(\.standardizedFileURL)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children {
                    try walk(child, relative: relative + "/" + child.lastPathComponent, depth: depth + 1)
                }
            } else {
                guard values.isRegularFile == true else { throw CatalogError.unsupportedLocation(url.path) }
                let size = values.fileSize ?? 0
                guard size <= byteBudget else { throw CatalogError.inspectionLimit(root.path) }
                append("file:\(size)")
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: min(byteBudget + 1, 65_536)), !chunk.isEmpty {
                    byteBudget -= chunk.count
                    guard byteBudget >= 0 else { throw CatalogError.inspectionLimit(root.path) }
                    hash.update(data: chunk)
                }
                let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard after.fileSize == values.fileSize,
                      after.contentModificationDate == values.contentModificationDate else {
                    throw CatalogError.inspectionLimit(root.path)
                }
            }
        }
        try walk(root, relative: "", depth: 0)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
