import CryptoKit
import Darwin
import Foundation

public enum SerialAllocation: String, Codable, Sendable {
    case appendMax
    case fillGap
}

public struct SerialPolicy: Codable, Sendable {
    public let width: Int
    public let allocation: SerialAllocation

    public init(width: Int, allocation: SerialAllocation) {
        self.width = width
        self.allocation = allocation
    }
}

public struct FileFingerprint: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file
        case directory
    }

    public let kind: Kind
    public let sha256: String
    public let device: Int64
    public let inode: UInt64
}

public struct MoveRequest: Sendable {
    public let source: URL
    public let destinationDirectory: URL
    public let proposedName: String
    public let expectedFingerprint: FileFingerprint
    public let serial: SerialPolicy?

    public init(
        source: URL,
        destinationDirectory: URL,
        proposedName: String,
        expectedFingerprint: FileFingerprint,
        serial: SerialPolicy? = nil
    ) {
        self.source = source
        self.destinationDirectory = destinationDirectory
        self.proposedName = proposedName
        self.expectedFingerprint = expectedFingerprint
        self.serial = serial
    }
}

public struct MoveRecord: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable {
        case pending
        case applied
        case undoPending
        case undone
        case failed
    }

    public let id: UUID
    public let source: URL
    public let destination: URL
    public let fingerprint: FileFingerprint
    public fileprivate(set) var state: State
    public let createdAt: Date
    public fileprivate(set) var updatedAt: Date
    public fileprivate(set) var detail: String?
}

public enum FileOperationError: LocalizedError, Sendable {
    case invalidPath(String)
    case outsideAllowedRoots(String)
    case protectedStateDirectory
    case invalidFilename(String)
    case changedExtension
    case invalidSerialPolicy
    case serialExhausted
    case symbolicLink(String)
    case unsupportedFile(String)
    case sourceChanged
    case destinationChanged
    case pathOccupied(String)
    case crossVolume
    case unknownRecord(UUID)
    case invalidRecordState(MoveRecord.State)
    case pendingRecovery(UUID)
    case filesystem(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): "Invalid file path: \(path)"
        case .outsideAllowedRoots(let path): "Path is outside the selected folders: \(path)"
        case .protectedStateDirectory: "This location contains the app’s operation history."
        case .invalidFilename(let name): "Invalid file name: \(name)"
        case .changedExtension: "Keep the original file extension."
        case .invalidSerialPolicy: "Use one {serial} placeholder with a width from 1 to 12."
        case .serialExhausted: "There are no numbers available at this width."
        case .symbolicLink(let name): "Symbolic links are not supported: \(name)"
        case .unsupportedFile(let name): "Unsupported file type: \(name)"
        case .sourceChanged: "The source has changed since it was reviewed."
        case .destinationChanged: "The moved item has changed since it was applied."
        case .pathOccupied(let path): "An item already exists at \(path)."
        case .crossVolume: "The folders are on different volumes. This move requires the same volume."
        case .unknownRecord(let id): "No move with ID \(id) exists."
        case .invalidRecordState(let state): "The operation cannot be undone in state \(state.rawValue)."
        case .pendingRecovery(let id): "Operation \(id) requires history recovery before continuing."
        case .filesystem(let operation, let code):
            "\(operation): \(String(cString: strerror(code)))"
        }
    }
}

/// Verifies and applies file moves within the selected roots. State changes are serialized
/// both within this actor and across engines that use the same state directory.
public actor MoveEngine {
    private let sourceRoots: [AllowedRoot]
    private let destinationRoots: [AllowedRoot]
    private let statePath: LocalPath

    public init(
        sourceRoots: [URL], destinationRoots: [URL], stateDirectory: URL, exactSources: [URL] = []
    ) throws {
        self.sourceRoots = try sourceRoots.map { try AllowedRoot($0) } +
            exactSources.map { try AllowedRoot($0, exact: true) }
        self.destinationRoots = try destinationRoots.map { try AllowedRoot($0) }
        let requestedState = try LocalPath(stateDirectory)
        try FileManager.default.createDirectory(at: requestedState.url, withIntermediateDirectories: true)
        self.statePath = try canonicalPath(requestedState)
    }

    public func fingerprint(of url: URL) throws -> FileFingerprint {
        let location = try item(at: url, in: sourceRoots)
        return try inspectItem(at: location).fingerprint
    }

    public func history() throws -> [MoveRecord] {
        try withJournalLock { try readJournal(in: $0) }
    }

    /// Resolves interrupted operations whose before/after state can be proved.
    /// Ambiguous operations remain pending and their paths stay untouched.
    @discardableResult
    public func recoverPending() throws -> [MoveRecord] {
        try withJournalLock { state in
            var journal = try readJournal(in: state)
            if recoverEntries(in: &journal) {
                try writeJournal(journal, in: state)
            }
            return journal
        }
    }

    @discardableResult
    public func apply(_ request: MoveRequest) throws -> MoveRecord {
        try withJournalLock { state in
            var journal = try prepareJournal(in: state)
            let source = try item(at: request.source, in: sourceRoots)
            let destinationDirectory = try checkedPath(request.destinationDirectory, in: destinationRoots)
            let destinationParent = try openDirectory(destinationDirectory)
            let inspected: InspectedItem
            do {
                inspected = try inspectItem(at: source)
            } catch FileOperationError.filesystem(_, ENOENT) {
                throw FileOperationError.sourceChanged
            }
            let actualFingerprint = inspected.fingerprint
            guard actualFingerprint == request.expectedFingerprint else {
                throw FileOperationError.sourceChanged
            }

            let name = try allocateName(
                request.proposedName, using: request.serial, in: destinationParent
            )
            if actualFingerprint.kind == .file,
               (source.name as NSString).pathExtension != (name as NSString).pathExtension {
                throw FileOperationError.changedExtension
            }
            let destination = ItemLocation(
                path: destinationDirectory.appending(name), parent: destinationParent
            )
            try protectState(at: destination.path)
            guard actualFingerprint.kind != .directory || !source.path.contains(destination.path) else {
                throw FileOperationError.invalidPath(destination.path.string)
            }
            try preflightMove(from: source, to: destination, expected: inspected.metadata)

            let now = Date()
            let record = MoveRecord(
                id: UUID(), source: source.path.url, destination: destination.path.url,
                fingerprint: actualFingerprint, state: .pending,
                createdAt: now, updatedAt: now, detail: nil
            )
            journal.append(record)
            let index = journal.index(before: journal.endIndex)
            try writeJournal(journal, in: state)
            do {
                try exclusiveRename(from: source, to: destination, expected: inspected.metadata)
            } catch {
                update(&journal[index], to: .failed, detail: error.localizedDescription)
                try writeJournal(journal, in: state)
                throw error
            }
            return try finishMove(
                journal: &journal, index: index, state: state,
                from: source, to: destination, newState: .applied
            )
        }
    }

    @discardableResult
    public func undo(id: UUID) throws -> MoveRecord {
        try withJournalLock { state in
            var journal = try prepareJournal(in: state)
            guard let index = journal.firstIndex(where: { $0.id == id }) else {
                throw FileOperationError.unknownRecord(id)
            }
            let record = journal[index]
            guard record.state == .applied else {
                throw FileOperationError.invalidRecordState(record.state)
            }
            let current = try item(at: record.destination, in: destinationRoots)
            let original = try item(at: record.source, in: sourceRoots)
            let inspected: InspectedItem
            do {
                inspected = try inspectItem(at: current)
            } catch FileOperationError.filesystem(_, ENOENT) {
                throw FileOperationError.destinationChanged
            }
            guard inspected.fingerprint == record.fingerprint else {
                throw FileOperationError.destinationChanged
            }
            try preflightMove(from: current, to: original, expected: inspected.metadata)

            update(&journal[index], to: .undoPending)
            try writeJournal(journal, in: state)
            do {
                try exclusiveRename(from: current, to: original, expected: inspected.metadata)
            } catch {
                update(&journal[index], to: .applied, detail: error.localizedDescription)
                try writeJournal(journal, in: state)
                throw error
            }
            return try finishMove(
                journal: &journal, index: index, state: state,
                from: current, to: original, newState: .undone
            )
        }
    }

    private func checkedPath(_ url: URL, in roots: [AllowedRoot]) throws -> LocalPath {
        let path = try LocalPath(url)
        for root in roots.sorted(by: { $0.selected.parts.count > $1.selected.parts.count }) {
            if root.exact {
                if root.selected == path || root.canonical == path { return root.canonical }
                continue
            }
            if root.selected.contains(path) {
                return LocalPath(parts: root.canonical.parts + path.parts.dropFirst(root.selected.parts.count))
            }
            if root.canonical.contains(path) { return path }
        }
        throw FileOperationError.outsideAllowedRoots(path.string)
    }

    private func item(at url: URL, in roots: [AllowedRoot]) throws -> ItemLocation {
        let path = try checkedPath(url, in: roots)
        guard !path.parts.isEmpty,
              !roots.contains(where: { $0.canonical == path && !$0.exact }) else {
            throw FileOperationError.invalidPath(path.string)
        }
        try protectState(at: path)
        return ItemLocation(path: path, parent: try openDirectory(path.parent))
    }

    private func protectState(at path: LocalPath) throws {
        if statePath.contains(path) || path.contains(statePath) {
            throw FileOperationError.protectedStateDirectory
        }
    }

    private func prepareJournal(in state: DirectoryHandle) throws -> [MoveRecord] {
        var journal = try readJournal(in: state)
        if recoverEntries(in: &journal) {
            try writeJournal(journal, in: state)
        }
        if let unresolved = journal.first(where: { $0.state == .pending || $0.state == .undoPending }) {
            throw FileOperationError.pendingRecovery(unresolved.id)
        }
        return journal
    }

    private func recoverEntries(in journal: inout [MoveRecord]) -> Bool {
        var changed = false
        for index in journal.indices {
            let record = journal[index]
            guard record.state == .pending || record.state == .undoPending,
                  let source = try? item(at: record.source, in: sourceRoots),
                  let destination = try? item(at: record.destination, in: destinationRoots) else { continue }
            let sourceMatches = (try? inspectItem(at: source).fingerprint) == record.fingerprint
            let destinationMatches = (try? inspectItem(at: destination).fingerprint) == record.fingerprint
            let sourceEmpty = (try? isEmpty(source)) == true
            let destinationEmpty = (try? isEmpty(destination)) == true
            let resolved: MoveRecord.State
            if sourceMatches && destinationEmpty {
                resolved = record.state == .pending ? .failed : .undone
            } else if destinationMatches && sourceEmpty {
                resolved = .applied
            } else {
                continue
            }
            guard (try? syncMoveParents(source, destination)) != nil else { continue }
            update(&journal[index], to: resolved, detail: "Recovered after an interrupted operation.")
            changed = true
        }
        return changed
    }

    private func finishMove(
        journal: inout [MoveRecord], index: Int, state: DirectoryHandle,
        from: ItemLocation, to: ItemLocation, newState: MoveRecord.State
    ) throws -> MoveRecord {
        do {
            try syncMoveParents(from, to)
            update(&journal[index], to: newState)
            try writeJournal(journal, in: state)
        } catch {
            throw FileOperationError.pendingRecovery(journal[index].id)
        }
        return journal[index]
    }

    private func withJournalLock<T>(_ operation: (DirectoryHandle) throws -> T) throws -> T {
        let directory = try openDirectory(statePath)
        let fd = openat(directory.fd, "operations.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw posixError("Open operation lock") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw posixError("Lock operation history") }
        }
        return try operation(directory)
    }

    private func readJournal(in state: DirectoryHandle) throws -> [MoveRecord] {
        let fd = openat(state.fd, "operations.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return [] }
        guard fd >= 0 else { throw posixError("Read operation history") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard try info(for: fd).st_mode & S_IFMT == S_IFREG else {
            throw FileOperationError.unsupportedFile("operations.json")
        }
        return try JSONDecoder().decode([MoveRecord].self, from: handle.readToEnd() ?? Data())
    }

    private func writeJournal(_ journal: [MoveRecord], in state: DirectoryHandle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(journal)
        let temporary = ".operations-\(UUID().uuidString).tmp"
        let fd = openat(state.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw posixError("Create operation history") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        defer { _ = unlinkat(state.fd, temporary, 0) }
        try handle.write(contentsOf: data)
        try sync(fd, operation: "Save operation history")
        guard renameat(state.fd, temporary, state.fd, "operations.json") == 0 else {
            throw posixError("Replace operation history")
        }
        try sync(state.fd, operation: "Save operation history directory")
    }
}

private struct LocalPath: Equatable, Sendable {
    let parts: [String]

    init(parts: [String]) { self.parts = parts }

    init(_ url: URL) throws {
        let path = url.path(percentEncoded: false)
        guard url.isFileURL, (url.host() ?? "").isEmpty, path.hasPrefix("/"),
              !path.utf8.contains(0) else { throw FileOperationError.invalidPath(path) }
        if path == "/" {
            parts = []
            return
        }
        var components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        if components.last == "" { components.removeLast() }
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw FileOperationError.invalidPath(path)
        }
        parts = components.map(String.init)
    }

    var string: String { "/" + parts.joined(separator: "/") }
    var url: URL { URL(filePath: string, directoryHint: .notDirectory) }
    var parent: LocalPath { LocalPath(parts: Array(parts.dropLast())) }

    func contains(_ other: LocalPath) -> Bool {
        other.parts.starts(with: parts)
    }

    func appending(_ name: String) -> LocalPath {
        LocalPath(parts: parts + [name])
    }
}

private struct AllowedRoot: Sendable {
    let selected: LocalPath
    let canonical: LocalPath
    let exact: Bool

    init(_ url: URL, exact: Bool = false) throws {
        selected = try LocalPath(url)
        self.exact = exact
        if let leaf = selected.parts.last {
            let parent = try canonicalPath(selected.parent, allowMissing: exact)
            canonical = parent.appending(leaf)
        } else {
            guard !exact else { throw FileOperationError.invalidPath(selected.string) }
            canonical = selected
        }
        if !exact { _ = try openDirectory(canonical) }
    }
}

private final class DirectoryHandle {
    let fd: Int32

    init(_ fd: Int32) { self.fd = fd }

    deinit { close(fd) }
}

private struct ItemLocation {
    let path: LocalPath
    let parent: DirectoryHandle
    var name: String { path.parts.last! }
}

private func canonicalPath(_ path: LocalPath, allowMissing: Bool = false) throws -> LocalPath {
    guard let resolved = realpath(path.string, nil) else {
        let code = errno
        if code == ENOENT, allowMissing, let last = path.parts.last {
            return try canonicalPath(path.parent, allowMissing: true).appending(last)
        }
        throw FileOperationError.filesystem("Resolve \(path.string)", code)
    }
    defer { free(resolved) }
    return try LocalPath(URL(filePath: String(cString: resolved), directoryHint: .notDirectory))
}

private func openDirectory(_ path: LocalPath) throws -> DirectoryHandle {
    let initial = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard initial >= 0 else { throw posixError("Open file system root") }
    var current = DirectoryHandle(initial)
    for component in path.parts {
        let next = openat(current.fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if next < 0 {
            let error = errno
            if let entry = try? entryInfo(current.fd, component), entry.st_mode & S_IFMT == S_IFLNK {
                throw FileOperationError.symbolicLink(component)
            }
            throw FileOperationError.filesystem("Open directory \(component)", error)
        }
        current = DirectoryHandle(next)
    }
    return current
}

private func info(for fd: Int32) throws -> stat {
    var entry = stat()
    guard fstat(fd, &entry) == 0 else { throw posixError("Read open file metadata") }
    return entry
}

private func entryInfo(_ parent: Int32, _ name: String) throws -> stat {
    var entry = stat()
    guard fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw posixError("Read metadata for \(name)")
    }
    return entry
}

private func isEmpty(_ location: ItemLocation) throws -> Bool {
    do {
        _ = try entryInfo(location.parent.fd, location.name)
        return false
    } catch FileOperationError.filesystem(_, ENOENT) {
        return true
    }
}

private func directoryEntries(_ fd: Int32) throws -> [String] {
    let scan = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard scan >= 0 else { throw posixError("Open directory listing") }
    guard let listing = fdopendir(scan) else {
        let error = posixError("Read directory listing")
        close(scan)
        throw error
    }
    defer { closedir(listing) }
    var names: [String] = []
    while true {
        errno = 0
        guard let entry = readdir(listing) else {
            if errno != 0 { throw posixError("Read directory listing") }
            return names
        }
        let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingCString: $0) }
        }
        guard let name else { throw FileOperationError.invalidFilename("Non-UTF-8 directory entry") }
        if name != "." && name != ".." { names.append(name) }
    }
}

private struct InspectedItem {
    let fingerprint: FileFingerprint
    let metadata: stat
}

private func inspectItem(at location: ItemLocation) throws -> InspectedItem {
    let result = try treeDigest(location.name, in: location.parent.fd)
    let fingerprint = FileFingerprint(
        kind: result.kind,
        sha256: result.digest.map { String(format: "%02x", $0) }.joined(),
        device: Int64(result.metadata.st_dev),
        inode: UInt64(result.metadata.st_ino)
    )
    return InspectedItem(fingerprint: fingerprint, metadata: result.metadata)
}

private func treeDigest(
    _ name: String, in parent: Int32
) throws -> (kind: FileFingerprint.Kind, digest: SHA256.Digest, metadata: stat) {
    let entry = try entryInfo(parent, name)
    let kind: FileFingerprint.Kind
    switch entry.st_mode & S_IFMT {
    case S_IFREG: kind = .file
    case S_IFDIR: kind = .directory
    case S_IFLNK: throw FileOperationError.symbolicLink(name)
    default: throw FileOperationError.unsupportedFile(name)
    }

    let directoryFlag = kind == .directory ? O_DIRECTORY : 0
    let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | directoryFlag)
    guard fd >= 0 else { throw posixError("Open \(name)") }
    defer { close(fd) }
    let before = try info(for: fd)
    guard sameSnapshot(entry, before) else { throw FileOperationError.sourceChanged }

    var digest = SHA256()
    digest.update(data: Data([kind == .directory ? 1 : 0]))
    if kind == .directory {
        for child in try directoryEntries(fd).sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let result = try treeDigest(child, in: fd)
            let bytes = Data(child.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { digest.update(bufferPointer: $0) }
            digest.update(data: bytes)
            digest.update(data: Data(result.digest))
        }
    } else {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let size = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if size == 0 { break }
            if size < 0 {
                if errno == EINTR { continue }
                throw posixError("Read \(name)")
            }
            buffer.withUnsafeBytes {
                digest.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<size]))
            }
        }
    }

    guard sameSnapshot(before, try info(for: fd)),
          sameSnapshot(before, try entryInfo(parent, name)) else {
        throw FileOperationError.sourceChanged
    }
    return (kind, digest.finalize(), before)
}

private func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino &&
    lhs.st_mode == rhs.st_mode && lhs.st_size == rhs.st_size &&
    lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
    lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
    lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
    lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
}

private func validateFilename(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
          !name.contains("/"), !name.contains(":"),
          name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
        throw FileOperationError.invalidFilename(name)
    }
}

private func allocateName(_ name: String, using serial: SerialPolicy?, in directory: DirectoryHandle) throws -> String {
    let parts = name.components(separatedBy: "{serial}")
    guard let serial else {
        guard parts.count == 1 else { throw FileOperationError.invalidSerialPolicy }
        try validateFilename(name)
        return name
    }
    guard parts.count == 2, (1...12).contains(serial.width) else {
        throw FileOperationError.invalidSerialPolicy
    }
    try validateFilename(parts[0] + String(repeating: "0", count: serial.width) + parts[1])
    let digitsPattern = "([0-9]{\(serial.width)})"
    let expression: String
    if parts[0].isEmpty, let delimiter = parts[1].first, ["_", "-", " "].contains(delimiter) {
        // Conventional numbered prefixes share a series across titles and extensions.
        expression = "\\A\(digitsPattern)\(NSRegularExpression.escapedPattern(for: String(delimiter)))"
    } else {
        // The file system can return decomposed names even when the template is composed.
        let prefix = NSRegularExpression.escapedPattern(for: parts[0].precomposedStringWithCanonicalMapping)
        let suffix = NSRegularExpression.escapedPattern(for: parts[1].precomposedStringWithCanonicalMapping)
        expression = "\\A\(prefix)\(digitsPattern)\(suffix)\\z"
    }
    let pattern = try NSRegularExpression(pattern: expression, options: [.caseInsensitive])
    var used = Set<Int>()
    for entry in try directoryEntries(directory.fd) {
        let filename = entry.precomposedStringWithCanonicalMapping
        let range = NSRange(filename.startIndex..., in: filename)
        if let match = pattern.firstMatch(in: filename, range: range),
           let digits = Range(match.range(at: 1), in: filename),
           let number = Int(filename[digits]) {
            used.insert(number)
        }
    }
    let number: Int
    switch serial.allocation {
    case .appendMax: number = (used.max() ?? 0) + 1
    case .fillGap:
        var candidate = 1
        for occupied in used.sorted() where occupied >= candidate {
            if occupied > candidate { break }
            candidate += 1
        }
        number = candidate
    }
    let digits = String(number)
    guard digits.count <= serial.width else { throw FileOperationError.serialExhausted }
    return parts[0] + String(repeating: "0", count: serial.width - digits.count) + digits + parts[1]
}

private func preflightMove(from source: ItemLocation, to destination: ItemLocation, expected: stat) throws {
    let sourceEntry = try entryInfo(source.parent.fd, source.name)
    guard sameSnapshot(sourceEntry, expected) else {
        throw FileOperationError.sourceChanged
    }
    guard try info(for: destination.parent.fd).st_dev == sourceEntry.st_dev else {
        throw FileOperationError.crossVolume
    }
    guard try isEmpty(destination) else { throw FileOperationError.pathOccupied(destination.path.string) }
}

private func exclusiveRename(from source: ItemLocation, to destination: ItemLocation, expected: stat) throws {
    try preflightMove(from: source, to: destination, expected: expected)
    let result = renameatx_np(
        source.parent.fd, source.name, destination.parent.fd, destination.name, UInt32(RENAME_EXCL)
    )
    guard result != 0 else { return }
    let error = errno
    if error == EEXIST || error == ENOTEMPTY { throw FileOperationError.pathOccupied(destination.path.string) }
    if error == EXDEV { throw FileOperationError.crossVolume }
    throw FileOperationError.filesystem("Move \(source.name)", error)
}

private func syncMoveParents(_ first: ItemLocation, _ second: ItemLocation) throws {
    try sync(first.parent.fd, operation: "Save original directory")
    try sync(second.parent.fd, operation: "Save destination directory")
}

private func sync(_ fd: Int32, operation: String) throws {
    while fsync(fd) != 0 {
        if errno != EINTR { throw posixError(operation) }
    }
}

private func update(_ record: inout MoveRecord, to state: MoveRecord.State, detail: String? = nil) {
    record.state = state
    record.updatedAt = Date()
    record.detail = detail
}

private func posixError(_ operation: String) -> FileOperationError {
    .filesystem(operation, errno)
}
