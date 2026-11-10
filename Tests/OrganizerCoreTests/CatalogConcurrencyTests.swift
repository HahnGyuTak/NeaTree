import Foundation
import Testing
@testable import OrganizerCore

@Test func concurrentCatalogScansDoNotBlockSwiftTaskExecutors() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OrganizerConcurrentCatalog-" + UUID().uuidString).standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var roots: [URL] = []
    for index in 0..<16 {
        let folder = root.appendingPathComponent("Folder-\(index)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Example.app"), withIntermediateDirectories: true)
        try Data("메모 \(index)".utf8).write(to: folder.appendingPathComponent("note.txt"))
        roots.append(folder)
    }
    let catalogs = try await withThrowingTaskGroup(of: [FolderRecord].self) { group in
        for folder in roots {
            group.addTask { try await CatalogBuilder.scanAsync(roots: [folder]) }
        }
        var catalogs: [[FolderRecord]] = []
        for try await catalog in group { catalogs.append(catalog) }
        return catalogs
    }
    #expect(catalogs.count == 16)
    #expect(catalogs.allSatisfy { $0.count == 1 && $0[0].sampleNames.contains("note.txt") })
    #expect(Set(catalogs.flatMap { $0.map(\.id) }).count == 16)
}
