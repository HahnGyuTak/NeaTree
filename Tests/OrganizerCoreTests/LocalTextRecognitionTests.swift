import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import Testing
@testable import OrganizerCore

// Allow first-run Vision model initialization, observed above one minute before fast warm runs.
@Suite(.timeLimit(.minutes(2)))
struct LocalTextRecognitionTests {
    @Test func generatedImageAndScannedPDFUseLocalVision() async throws {
        let result = try await FileMetadataWorker.run {
            let fixture = try OCRFixture()
            defer { fixture.cleanup() }
            let imageURL = try fixture.imageFile()
            let pdfURL = try fixture.pdfFile(pages: [.image])
            let hasNoTextLayer = PDFDocument(url: pdfURL)?.page(at: 0)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            return (try FileInspector.inspect(imageURL), LocalTextRecognition.inspectPDF(pdfURL, byteCount: 0), hasNoTextLayer)
        }
        #expect(result.2, "The PDF fixture must contain a raster image, without selectable text.")
        #expect(result.0.kind == "png")
        #expect(result.0.readStatus == "ocr_text")
        #expect(result.0.extractedText.uppercased().contains("INVOICE"))
        #expect(result.0.extractedText.contains("2026"))
        #expect(result.1.failureDiagnostic == nil)
        #expect(result.1.readStatus == "ocr_text")
        #expect(result.1.text.uppercased().contains("INVOICE"))
    }

    @Test func diagnosticCodesNeverContainDocumentPathsTextOrArbitraryErrorDomains() {
        let privateText = "PRIVATE_DOCUMENT_CONTENT"
        let privatePath = "/Users/example/private-receipt.png"
        let underlying = NSError(domain: NSCocoaErrorDomain, code: 257,
                                 userInfo: [NSFilePathErrorKey: privatePath, NSLocalizedDescriptionKey: privateText])
        let error = NSError(domain: "untrusted-" + privateText, code: 42,
                            userInfo: [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: privatePath])
        let diagnostic = LocalTextRecognition.FailureDiagnostic(error, stage: .recognition)
        #expect(diagnostic.description == "recognition:other:42>cocoa:257")
        #expect(!diagnostic.description.contains(privateText))
        #expect(!diagnostic.description.contains(privatePath))
    }

    @Test func selectablePDFTextSkipsOCRAndPreservesTextLimits() async throws {
        let result = try await FileMetadataWorker.run {
            let fixture = try OCRFixture()
            defer { fixture.cleanup() }
            let pdf = try fixture.pdfFile(pages: [.text("INVOICE 2026"), .text("SECOND PAGE")])
            var calls = 0
            let full = LocalTextRecognition.inspectPDF(pdf, byteCount: 0) { _ in
                calls += 1
                throw OCRFixture.Failure.unexpectedRecognition
            }
            var limits = LocalTextRecognition.Limits.standard
            limits.pdfPages = 1
            let firstPage = LocalTextRecognition.inspectPDF(pdf, byteCount: 0, limits: limits) { _ in
                calls += 1
                throw OCRFixture.Failure.unexpectedRecognition
            }
            limits.textCharacters = 5
            let prefix = LocalTextRecognition.inspectPDF(pdf, byteCount: 0, limits: limits) { _ in
                calls += 1
                throw OCRFixture.Failure.unexpectedRecognition
            }
            return (full, firstPage, prefix, calls)
        }
        #expect(result.0.readStatus == "full_text")
        #expect(result.0.text.contains("INVOICE 2026"))
        #expect(result.0.text.contains("SECOND PAGE"))
        #expect(result.1.readStatus == "partial_text")
        #expect(!result.1.text.contains("SECOND PAGE"))
        #expect(result.2.readStatus == "partial_text")
        #expect(result.2.text.count == 5)
        #expect(result.3 == 0)
    }

    @Test func byteAndSourcePixelLimitsRejectBeforeRecognition() async throws {
        let result = try await FileMetadataWorker.run {
            let fixture = try OCRFixture()
            defer { fixture.cleanup() }
            let image = try fixture.imageFile()
            let pdf = try fixture.pdfFile(pages: [.image])
            var calls = 0
            var limits = LocalTextRecognition.Limits.standard
            limits.imageBytes = 1
            limits.pdfBytes = 1
            // A stale/smaller byte count must not bypass the actual bounded file read.
            let imageBytes = LocalTextRecognition.inspectImage(image, byteCount: 0, limits: limits) { _ in
                calls += 1; return "unexpected"
            }
            let pdfBytes = LocalTextRecognition.inspectPDF(pdf, byteCount: 0, limits: limits) { _ in
                calls += 1; return "unexpected"
            }
            limits = .standard
            limits.sourcePixels = 100
            let pixels = LocalTextRecognition.inspectImage(image, byteCount: 0, limits: limits) { _ in
                calls += 1; return "unexpected"
            }
            return (imageBytes, pdfBytes, pixels, calls)
        }
        #expect(result.0.readStatus == "oversized_image")
        #expect(result.1.readStatus == "oversized_pdf")
        #expect(result.2.readStatus == "image_pixel_limit")
        #expect(result.0.text.isEmpty && result.1.text.isEmpty && result.2.text.isEmpty)
        #expect(result.3 == 0)
    }

    @Test func imageDownsamplingFramesAndOutputTruncationAreMarkedPartial() async throws {
        let result = try await FileMetadataWorker.run {
            let fixture = try OCRFixture()
            defer { fixture.cleanup() }
            let image = try fixture.imageFile()
            let frames = try fixture.imageFile(name: "pages.tiff", frames: 2)
            var limits = LocalTextRecognition.Limits.standard
            limits.longestEdge = 100
            limits.renderedPixels = 10_000
            limits.textCharacters = 6
            var dimensions: [Int] = []
            let reduced = LocalTextRecognition.inspectImage(image, byteCount: 0, limits: limits) { image in
                dimensions = [image.width, image.height]
                return "INVOICE 2026"
            }
            let firstFrame = LocalTextRecognition.inspectImage(frames, byteCount: 0) { _ in "INVOICE" }
            return (reduced, firstFrame, dimensions)
        }
        #expect(result.0.readStatus == "partial_ocr_text")
        #expect(result.0.text == "INVOIC")
        #expect(result.1.readStatus == "partial_ocr_text")
        #expect(result.1.text == "INVOICE")
        #expect(result.2.count == 2 && result.2.allSatisfy { $0 > 0 && $0 <= 100 })
    }

    @Test func scannedPDFLimitsRecognitionPagesAndRenderedPixels() async throws {
        let result = try await FileMetadataWorker.run {
            let fixture = try OCRFixture()
            defer { fixture.cleanup() }
            let pdf = try fixture.pdfFile(pages: [.image, .image, .image])
            var limits = LocalTextRecognition.Limits.standard
            limits.pdfOCRPages = 1
            limits.longestEdge = 128
            limits.renderedPixels = 4_096
            var calls = 0
            var dimensions: [Int] = []
            let extraction = LocalTextRecognition.inspectPDF(pdf, byteCount: 0, limits: limits) { image in
                calls += 1
                dimensions = [image.width, image.height]
                return "FIRST SCANNED PAGE"
            }
            let noText = LocalTextRecognition.inspectPDF(pdf, byteCount: 0, limits: limits) { _ in "" }
            return (extraction, noText, calls, dimensions)
        }
        #expect(result.0.readStatus == "partial_ocr_text")
        #expect(result.0.text == "FIRST SCANNED PAGE")
        #expect(result.1.readStatus == "ocr_limit")
        #expect(result.2 == 1)
        #expect(result.3.count == 2 && result.3.allSatisfy { $0 > 0 && $0 <= 64 })
    }

    @Test func failedOrEmptyOCRNeverClaimsFullyReadContent() async throws {
        let result = try await FileMetadataWorker.run {
            let fixture = try OCRFixture()
            defer { fixture.cleanup() }
            let image = try fixture.imageFile()
            let mixedPDF = try fixture.pdfFile(pages: [.text("SELECTABLE TEXT"), .image])
            let empty = LocalTextRecognition.inspectImage(image, byteCount: 0) { _ in " \n " }
            let failure = LocalTextRecognition.inspectImage(image, byteCount: 0) { _ in
                throw OCRFixture.Failure.unexpectedRecognition
            }
            let partial = LocalTextRecognition.inspectPDF(mixedPDF, byteCount: 0) { _ in
                throw OCRFixture.Failure.unexpectedRecognition
            }
            return (empty, failure, partial)
        }
        #expect(result.0.readStatus == "no_text_recognized" && result.0.text.isEmpty)
        #expect(result.1.readStatus == "ocr_failed" && result.1.text.isEmpty)
        #expect(result.2.readStatus == "partial_ocr_text")
        #expect(result.2.text.contains("SELECTABLE TEXT"))
    }

    @Test func unsupportedAndCorruptFilesRemainHonest() async throws {
        let result = try await FileMetadataWorker.run {
            let fixture = try OCRFixture()
            defer { fixture.cleanup() }
            let unsupported = fixture.root.appendingPathComponent("archive.zip")
            let corrupt = fixture.root.appendingPathComponent("broken.png")
            for url in [unsupported, corrupt] { try Data([0, 1, 2, 3]).write(to: url) }
            return (try FileInspector.inspect(unsupported), try FileInspector.inspect(corrupt))
        }
        #expect(result.0.readStatus == "unsupported" && result.0.extractedText.isEmpty)
        #expect(result.1.readStatus == "unreadable_image" && result.1.extractedText.isEmpty)
    }
}

private struct OCRFixture {
    enum Failure: Error { case fixtureCreation, unexpectedRecognition }
    enum Page { case image, text(String) }
    let root: URL
    private let width = 1_000
    private let height = 320

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NeaTreeOCRTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func imageFile(name: String = "invoice.png", frames: Int = 1) throws -> URL {
        let url = root.appendingPathComponent(name)
        let type = frames > 1 ? "public.tiff" : "public.png"
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames, nil) else {
            throw Failure.fixtureCreation
        }
        let image = try generatedImage()
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
        guard CGImageDestinationFinalize(destination) else { throw Failure.fixtureCreation }
        return url
    }

    func pdfFile(pages: [Page]) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".pdf")
        var rectangle = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &rectangle, nil) else {
            throw Failure.fixtureCreation
        }
        let image = try generatedImage()
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .image: context.draw(image, in: rectangle)
            case .text(let text): drawText(text, in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func generatedImage() throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure.fixtureCreation
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        drawText("INVOICE 2026", in: context)
        guard let image = context.makeImage() else { throw Failure.fixtureCreation }
        return image
    }

    private func drawText(_ text: String, in context: CGContext) {
        let attributes = [kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 72, nil),
                          kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes)!
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 40, y: 120)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
}
