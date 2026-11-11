import AppKit
import Darwin
import Foundation

public enum APIKeyFileError: Error, LocalizedError, Sendable, Equatable {
    case unreadable
    case notRegularFile
    case tooLarge
    case invalidEncoding
    case invalidDocument
    case invalidContents

    public var errorDescription: String? {
        switch self {
        case .unreadable: "API 키 파일을 읽지 못했습니다. 지정한 파일과 읽기 권한을 확인하세요."
        case .notRegularFile: "API 키는 심볼릭 링크가 아닌 일반 파일로 지정하세요."
        case .tooLarge: "API 키 파일이 너무 큽니다. 키 한 줄만 저장하세요."
        case .invalidEncoding: "API 키 파일은 UTF-8 텍스트 또는 RTF 문서여야 합니다."
        case .invalidDocument: "RTF 문서의 텍스트를 읽지 못했습니다. 키 한 줄만 담긴 문서를 지정하세요."
        case .invalidContents: "API 키만 한 줄로 저장하세요. 변수 이름, 따옴표, 설명은 넣지 마세요."
        }
    }
}

/// Reads only the file explicitly selected by the caller. Does not persist or
/// transmit it, and never includes its contents or path in an error message.
public enum APIKeyFile {
    public static let maximumBytes = 8_192
    public static let maximumFileBytes = 65_536

    public static func read(from url: URL) throws -> String {
        guard url.isFileURL else { throw APIKeyFileError.unreadable }
        // NONBLOCK prevents an accidentally selected FIFO from hanging import.
        // NOFOLLOW prevents following a final-component symlink to another file.
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw APIKeyFileError.notRegularFile }
            throw APIKeyFileError.unreadable
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw APIKeyFileError.unreadable }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw APIKeyFileError.notRegularFile }
        guard info.st_size <= maximumFileBytes else { throw APIKeyFileError.tooLarge }
        var bytes = [UInt8](repeating: 0, count: maximumFileBytes + 1)
        var count = 0
        while count < bytes.count {
            let amount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if amount < 0 {
                if errno == EINTR { continue }
                throw APIKeyFileError.unreadable
            }
            if amount == 0 { break }
            count += amount
        }
        guard count <= maximumFileBytes else { throw APIKeyFileError.tooLarge }
        return try parse(Data(bytes.prefix(count)))
    }

    public static func importIntoKeychain(from url: URL) throws {
        try importKey(from: url, save: APIKeyStore.save)
    }

    static func importKey(from url: URL, save: (String) throws -> Void) throws {
        // Decode and validate completely before replacing any stored key.
        let key = try read(from: url)
        try save(key)
    }

    /// No key-prefix assumption: credential formats may evolve independently.
    public static func parse(_ data: Data) throws -> String {
        guard data.count <= maximumFileBytes else { throw APIKeyFileError.tooLarge }
        let input = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        let text: String
        if input.starts(with: Data("{\\rtf".utf8)) {
            guard let document = try? NSAttributedString(data: input,
                options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
                throw APIKeyFileError.invalidDocument
            }
            text = document.string
        } else {
            guard let decoded = String(data: input, encoding: .utf8) else { throw APIKeyFileError.invalidEncoding }
            text = decoded
        }
        guard text.utf8.count <= maximumBytes else { throw APIKeyFileError.tooLarge }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.hasPrefix("OPENAI_API_KEY="),
              key.utf8.allSatisfy({ (33...126).contains($0) && $0 != 34 && $0 != 39 && $0 != 96 }) else {
            throw APIKeyFileError.invalidContents
        }
        return key
    }
}
