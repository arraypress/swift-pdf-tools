//
//  Raster.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  Where pages meet pixels: rendering pages out as images, building a
//  PDF from images, and compression — which here is honest re-rendering
//  to JPEG at a chosen density. That suits the files people actually
//  need shrunk (scans and image-heavy decks); a vector-text PDF would
//  come out BIGGER, so the caller is told which version was kept.
//

import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public extension PDFTools {

    /// Renders one page to an image at `dpi` (72 = natural size).
    static func render(_ document: PDFDocument, page index: Int, dpi: Double = 144) throws -> CGImage {
        guard let page = document.page(at: index) else {
            throw PDFToolsError.badPages("The document has \(document.pageCount) pages; page \(index + 1) does not exist")
        }
        let media = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = CGSize(width: rotated ? media.height : media.width,
                          height: rotated ? media.width : media.height)
        let scale = dpi / 72
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PDFToolsError.writeFailed("Could not make a canvas for page \(index + 1)")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else {
            throw PDFToolsError.writeFailed("Page \(index + 1) would not render")
        }
        return image
    }

    /// Writes an image as PNG or JPEG.
    static func writeImage(_ image: CGImage, to url: URL, jpegQuality: Double? = nil) throws {
        let type = url.pathExtension.lowercased() == "png" ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw PDFToolsError.writeFailed("Could not write \(url.path)")
        }
        var options: [CFString: Any] = [:]
        if type == .jpeg { options[kCGImageDestinationLossyCompressionQuality] = jpegQuality ?? 0.9 }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PDFToolsError.writeFailed("Could not write \(url.path)")
        }
    }

    /// The page sizes `fromImages` lays pictures onto.
    enum PageSize: String, CaseIterable, Sendable {
        case a4, letter
        /// Each page exactly the image's pixel size, one point per pixel.
        case fit

        var points: CGSize? {
            switch self {
            case .a4: return CGSize(width: 595.28, height: 841.89)
            case .letter: return CGSize(width: 612, height: 792)
            case .fit: return nil
            }
        }
    }

    /// One PDF from many images, a page each, aspect kept.
    static func fromImages(_ urls: [URL], pageSize: PageSize = .fit) throws -> PDFDocument {
        guard !urls.isEmpty else { throw PDFToolsError.badValue("No images to bind") }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PDFToolsError.writeFailed("Could not start a PDF context")
        }
        for url in urls {
            let picture = try image(at: url)
            let natural = CGSize(width: picture.width, height: picture.height)
            var box: CGRect
            var target: CGRect
            if let page = pageSize.points {
                box = CGRect(origin: .zero, size: page)
                let scale = min(page.width / natural.width, page.height / natural.height)
                let size = CGSize(width: natural.width * scale, height: natural.height * scale)
                target = CGRect(x: (page.width - size.width) / 2, y: (page.height - size.height) / 2,
                                width: size.width, height: size.height)
            } else {
                box = CGRect(origin: .zero, size: natural)
                target = box
            }
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(info as CFDictionary)
            context.draw(picture, in: target)
            context.endPDFPage()
        }
        context.closePDF()
        guard let out = PDFDocument(data: data as Data) else {
            throw PDFToolsError.writeFailed("The bound document could not be read back")
        }
        return out
    }

    /// What `compress` did.
    struct CompressReport: Sendable, Equatable {
        /// Input size in bytes.
        public let before: Int
        /// The size of the re-rendered version.
        public let compressed: Int
        /// Whether the compressed version was kept — false means the
        /// original was already smaller and IT was written instead.
        public let keptCompressed: Bool
    }

    /// Re-renders the document to JPEG pages at `dpi` and `quality`,
    /// writing whichever version is SMALLER to `output`.
    ///
    /// Rasterising is the honest trade: text stops being selectable, and
    /// scans shrink dramatically. A vector-text PDF usually grows — then
    /// the original is written and the report says so.
    static func compress(_ document: PDFDocument, originalBytes: Int, to output: URL,
                         dpi: Double = 150, quality: Double = 0.7) throws -> CompressReport {
        guard (36...600).contains(dpi) else { throw PDFToolsError.badValue("--dpi is 36…600") }
        guard (0.05...1).contains(quality) else { throw PDFToolsError.badValue("--quality is 0.05…1") }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PDFToolsError.writeFailed("Could not start a PDF context")
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            let rotated = page.rotation % 180 != 0
            var box = CGRect(x: 0, y: 0,
                             width: rotated ? media.height : media.width,
                             height: rotated ? media.width : media.height)
            let raster = try render(document, page: index, dpi: dpi)
            // Encode to JPEG and decode again: an image whose backing data
            // IS JPEG passes through into the PDF, which is the shrink.
            let jpeg = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(jpeg as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw PDFToolsError.writeFailed("JPEG encoding failed on page \(index + 1)")
            }
            CGImageDestinationAddImage(dest, raster, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(dest),
                  let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let encoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw PDFToolsError.writeFailed("JPEG encoding failed on page \(index + 1)")
            }
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(info as CFDictionary)
            context.draw(encoded, in: box)
            context.endPDFPage()
        }
        context.closePDF()
        let compressed = data.length
        if compressed < originalBytes {
            guard data.write(to: output, atomically: true) else {
                throw PDFToolsError.writeFailed("Could not write \(output.path)")
            }
            return CompressReport(before: originalBytes, compressed: compressed, keptCompressed: true)
        }
        // The original was already smaller — keep it, and say so.
        try write(document, to: output)
        return CompressReport(before: originalBytes, compressed: compressed, keptCompressed: false)
    }
}
