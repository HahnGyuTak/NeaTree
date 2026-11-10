import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Vision
import OSLog

/// Synchronous, local-only extraction. FileInspector runs this on FileMetadataWorker.
/// OCR is evidence, not a guarantee that every word in an image was read correctly.
enum LocalTextRecognition {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"]
    private static let logger = Logger(subsystem: "com.neatree.core", category: "LocalOCR")

    /// A bounded diagnostic made only from fixed labels and numeric error codes.
    /// NSError descriptions, arbitrary domains, userInfo and document data are never retained.
    struct FailureDiagnostic: Error, Sendable, Equatable, CustomStringConvertible {
        enum Stage: String, Sendable { case languages, recognition, rendering }
        let stage: Stage
        let codes: [String]
        var description: String { stage.rawValue + ":" + codes.joined(separator: ">") }

        init(_ error: Error, stage: Stage) {
            if let sanitized = error as? FailureDiagnostic { self = sanitized; return }
            self.stage = stage
            let domains = [VNErrorDomain: "vision", NSCocoaErrorDomain: "cocoa", NSPOSIXErrorDomain: "posix",
                           NSOSStatusErrorDomain: "osstatus", NSMachErrorDomain: "mach",
                           "com.apple.CoreML": "coreml", "com.apple.espresso": "espresso"]
            var current: NSError? = error as NSError
            var sanitizedCodes: [String] = []
            for _ in 0..<3 {
                guard let value = current else { break }
                sanitizedCodes.append((domains[value.domain] ?? "other") + ":" + String(value.code))
                current = value.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            self.codes = sanitizedCodes
        }
    }

    struct Limits: Sendable {
        var imageBytes = 32 * 1_024 * 1_024
        var pdfBytes = 64 * 1_024 * 1_024
        var sourcePixels = 60_000_000
        var renderedPixels = 4_194_304
        var longestEdge = 2_048
        var pdfPages = 12
        var pdfOCRPages = 3
        var textCharacters = 32_000
        static let standard = Limits()
    }

    struct Extraction: Sendable, Equatable {
        let text: String
        let readStatus: String
        let failureDiagnostic: FailureDiagnostic?
        init(_ readStatus: String, failureDiagnostic: FailureDiagnostic? = nil) {
            self.init("", readStatus, failureDiagnostic: failureDiagnostic)
        }
        init(_ text: String, _ readStatus: String, failureDiagnostic: FailureDiagnostic? = nil) {
            self.text = text
            self.readStatus = readStatus
            self.failureDiagnostic = failureDiagnostic
        }
    }

    private enum ExtractionError: Error { case byteLimit, invalidDimensions, unreadable }

    static func inspectImage(
        _ url: URL, byteCount: Int64, limits: Limits = .standard,
        recognize: (CGImage) throws -> String = recognizeText
    ) -> Extraction {
        guard byteCount >= 0, byteCount <= limits.imageBytes else { return Extraction("oversized_image") }
        guard limits.longestEdge > 0, limits.renderedPixels > 0, limits.textCharacters > 0 else {
            return Extraction("ocr_limit")
        }
        let data: Data
        do { data = try boundedData(url, maximumBytes: limits.imageBytes) }
        catch ExtractionError.byteLimit { return Extraction("oversized_image") }
        catch { return Extraction("unreadable_image") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return Extraction("unreadable_image") }
        let imageIndex = CGImageSourceGetPrimaryImageIndex(source)
        guard imageIndex < CGImageSourceGetCount(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, imageIndex, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return Extraction("unreadable_image")
        }
        let sourceWidth = width.doubleValue
        let sourceHeight = height.doubleValue
        guard sourceWidth.isFinite, sourceHeight.isFinite, sourceWidth > 0, sourceHeight > 0,
              sourceWidth * sourceHeight <= Double(limits.sourcePixels) else {
            return Extraction("image_pixel_limit")
        }
        // Always create a size-bounded thumbnail from the source, including its EXIF orientation.
        // https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailfromimagealways
        let edgeLimit = min(limits.longestEdge, Int(Double(limits.renderedPixels).squareRoot()))
        guard edgeLimit > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, imageIndex, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edgeLimit,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, imageIndex) == .statusComplete,
              image.width > 0, image.height > 0,
              image.width <= edgeLimit, image.height <= edgeLimit,
              image.width <= limits.renderedPixels / image.height else {
            return Extraction("unreadable_image")
        }
        let omittedImageDetail = CGImageSourceGetCount(source) > 1 || max(sourceWidth, sourceHeight) > Double(edgeLimit)
        do {
            let recognized = try recognize(image).trimmingCharacters(in: .whitespacesAndNewlines)
            if recognized.isEmpty { return Extraction(omittedImageDetail ? "ocr_limit" : "no_text_recognized") }
            let partial = omittedImageDetail || recognized.count > limits.textCharacters
            return Extraction(String(recognized.prefix(limits.textCharacters)), partial ? "partial_ocr_text" : "ocr_text")
        } catch { return Extraction("ocr_failed", failureDiagnostic: report(error, stage: .recognition)) }
    }

    static func inspectPDF(
        _ url: URL, byteCount: Int64, limits: Limits = .standard,
        recognize: (CGImage) throws -> String = recognizeText
    ) -> Extraction {
        guard byteCount >= 0, byteCount <= limits.pdfBytes else { return Extraction("oversized_pdf") }
        guard limits.pdfPages > 0, limits.textCharacters > 0 else { return Extraction("ocr_limit") }
        let data: Data
        do { data = try boundedData(url, maximumBytes: limits.pdfBytes) }
        catch ExtractionError.byteLimit { return Extraction("oversized_pdf") }
        catch { return Extraction("unreadable_pdf") }
        guard let document = PDFDocument(data: data) else { return Extraction("unreadable_pdf") }
        guard !document.isLocked else { return Extraction("locked_pdf") }

        let pageLimit = min(document.pageCount, limits.pdfPages)
        var text = ""
        var partial = document.pageCount > pageLimit
        var ocrAttemptCount = 0
        var ocrLimitReached = false
        var unreadPage = false
        var failed = false
        var firstFailure: FailureDiagnostic?
        for index in 0..<pageLimit {
            let pageText: String = autoreleasepool {
                guard let page = document.page(at: index) else { failed = true; return "" }
                if let selectableText = page.string,
                   !selectableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return selectableText
                }
                guard ocrAttemptCount < limits.pdfOCRPages else {
                    ocrLimitReached = true
                    partial = true
                    return ""
                }
                ocrAttemptCount += 1
                do {
                    let (image, reducedResolution) = try render(page, limits: limits)
                    partial = partial || reducedResolution
                    let recognized: String
                    do { recognized = try recognize(image).trimmingCharacters(in: .whitespacesAndNewlines) }
                    catch { throw FailureDiagnostic(error, stage: .recognition) }
                    unreadPage = unreadPage || recognized.isEmpty
                    return recognized
                } catch {
                    failed = true
                    let diagnostic = report(error, stage: .rendering)
                    if firstFailure == nil { firstFailure = diagnostic }
                    return ""
                }
            }
            if !pageText.isEmpty {
                let separator = text.isEmpty ? "" : "\n"
                let remaining = limits.textCharacters - text.count - separator.count
                guard remaining > 0 else { partial = true; break }
                text += separator + String(pageText.prefix(remaining))
                partial = partial || pageText.count > remaining
            }
            if text.count >= limits.textCharacters {
                partial = partial || index + 1 < document.pageCount
                break
            }
        }
        if !text.isEmpty {
            partial = partial || unreadPage || failed
            if ocrAttemptCount > 0 || ocrLimitReached {
                return Extraction(text, partial ? "partial_ocr_text" : "ocr_text", failureDiagnostic: firstFailure)
            }
            return Extraction(text, partial ? "partial_text" : "full_text")
        }
        if ocrLimitReached || (partial && !failed && ocrAttemptCount > 0) { return Extraction("ocr_limit") }
        if failed { return Extraction(ocrAttemptCount > 0 ? "ocr_failed" : "unreadable_pdf", failureDiagnostic: firstFailure) }
        return Extraction(ocrAttemptCount > 0 ? "no_text_recognized" : "no_text_extracted")
    }

    /// Apple Vision recognizes text entirely on the device; there is no URLSession or remote fallback.
    /// https://developer.apple.com/documentation/vision/recognizing-text-in-images
    private static func recognizeText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported: [String]
        do { supported = try request.supportedRecognitionLanguages() }
        catch { throw FailureDiagnostic(error, stage: .languages) }
        let preferred = ["ko-KR", "en-US"].filter { supported.contains($0) }
        if !preferred.isEmpty { request.recognitionLanguages = preferred }
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
        catch { throw FailureDiagnostic(error, stage: .recognition) }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func report(_ error: Error, stage: FailureDiagnostic.Stage) -> FailureDiagnostic {
        let diagnostic = FailureDiagnostic(error, stage: stage)
        logger.error("Local OCR failed: \(diagnostic.description, privacy: .public)")
        return diagnostic
    }

    private static func boundedData(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw ExtractionError.byteLimit }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ExtractionError.byteLimit }
        return data
    }

    private static func render(_ page: PDFPage, limits: Limits) throws -> (CGImage, Bool) {
        guard let pageRef = page.pageRef, limits.longestEdge > 0, limits.renderedPixels > 0 else {
            throw ExtractionError.unreadable
        }
        let bounds = pageRef.getBoxRect(.cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw ExtractionError.invalidDimensions
        }
        let rotated = abs(pageRef.rotationAngle % 180) == 90
        let width = Double(rotated ? bounds.height : bounds.width)
        let height = Double(rotated ? bounds.width : bounds.height)
        let edgeLimit = min(limits.longestEdge, Int(Double(limits.renderedPixels).squareRoot()))
        let scale = min(2, Double(edgeLimit) / max(width, height))
        guard scale.isFinite, scale > 0 else { throw ExtractionError.invalidDimensions }
        let pixelWidth = max(1, Int((width * scale).rounded(.down)))
        let pixelHeight = max(1, Int((height * scale).rounded(.down)))
        guard pixelWidth <= edgeLimit, pixelHeight <= edgeLimit,
              pixelWidth <= limits.renderedPixels / pixelHeight,
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ExtractionError.invalidDimensions
        }
        let rectangle = CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rectangle)
        context.concatenate(pageRef.getDrawingTransform(.cropBox, rect: rectangle, rotate: 0, preserveAspectRatio: true))
        context.clip(to: bounds)
        context.drawPDFPage(pageRef)
        guard let image = context.makeImage() else { throw ExtractionError.unreadable }
        return (image, scale < 2)
    }
}
