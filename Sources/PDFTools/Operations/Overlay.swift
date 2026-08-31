//
//  Overlay.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  Drawing ON pages: watermarks, page numbers and signature stamps. One
//  engine re-renders each page into a fresh PDF context and hands the
//  context over for the extra ink, so the three verbs cannot drift apart.
//  The price of the engine is stated where it is paid: the output is a
//  re-rendered document, and a signature placed this way is a stamped
//  image — not a cryptographic signature.
//

import CoreText
import Foundation
import ImageIO
import PDFKit

public extension PDFTools {

    /// Where an overlay sits on the page.
    enum Anchor: String, CaseIterable, Sendable {
        case centre, tile
        case topLeft = "top-left", topCentre = "top-centre", topRight = "top-right"
        case bottomLeft = "bottom-left", bottomCentre = "bottom-centre", bottomRight = "bottom-right"
    }

    /// Re-renders the document, calling `ink` over each page's content.
    ///
    /// `ink` receives the zero-based page index, the context, and the
    /// page's box with a bottom-left origin at zero. Annotation ink is
    /// burned in — the output is what the page LOOKS like, plus yours.
    static func overlay(_ document: PDFDocument,
                        ink: (Int, CGContext, CGRect) -> Void) throws -> PDFDocument {
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
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(info as CFDictionary)
            context.saveGState()
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            context.saveGState()
            ink(index, context, box)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        guard let out = PDFDocument(data: data as Data) else {
            throw PDFToolsError.writeFailed("The re-rendered document could not be read back")
        }
        return out
    }

    /// Stamps text (and/or an image) over every page.
    ///
    /// - Parameters:
    ///   - text: The watermark text, drawn in grey at `opacity`.
    ///   - image: An image watermark, drawn at half the page's width.
    ///   - opacity: `0…1`.
    ///   - angle: Degrees anticlockwise; 45 is the classic DRAFT slant.
    ///   - anchor: Where it sits; `.tile` repeats text across the page.
    static func watermark(_ document: PDFDocument, text: String? = nil, image: CGImage? = nil,
                          opacity: Double = 0.2, angle: Double = 45,
                          anchor: Anchor = .centre) throws -> PDFDocument {
        guard text != nil || image != nil else { throw PDFToolsError.badValue("A watermark wants text, an image, or both") }
        guard (0...1).contains(opacity) else { throw PDFToolsError.badValue("--opacity is 0…1") }
        return try overlay(document) { _, ctx, box in
            ctx.setAlpha(CGFloat(opacity))
            if let image {
                let width = box.width * 0.5
                let height = width * CGFloat(image.height) / CGFloat(max(1, image.width))
                let rect = CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
                ctx.draw(image, in: rect)
            }
            guard let text else { return }
            let size = max(18, min(box.width, box.height) * 0.09)
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let line = Self.line(text, font: font, color: CGColor(gray: 0.35, alpha: 1))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let radians = angle * .pi / 180
            func stamp(at point: CGPoint) {
                ctx.saveGState()
                ctx.translateBy(x: point.x, y: point.y)
                ctx.rotate(by: radians)
                ctx.textPosition = CGPoint(x: -width / 2, y: -size / 2)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            switch anchor {
            case .tile:
                let stepX = max(width * 1.6, 120)
                let stepY = max(size * 6, 120)
                var y = box.minY
                var offset = false
                while y < box.maxY + stepY {
                    var x = box.minX + (offset ? stepX / 2 : 0)
                    while x < box.maxX + stepX { stamp(at: CGPoint(x: x, y: y)); x += stepX }
                    y += stepY
                    offset.toggle()
                }
            default:
                stamp(at: Self.point(for: anchor, in: box, inset: max(width / 2 + 24, 60)))
            }
        }
    }

    /// Draws page numbers.
    ///
    /// `format` takes one or two `%d`s: the page number, then the total —
    /// `"Page %d of %d"`. Numbers start at `start` and `skipFirst` leaves
    /// a cover page clean (it still counts).
    static func number(_ document: PDFDocument, format: String = "%d",
                       anchor: Anchor = .bottomCentre, start: Int = 1,
                       skipFirst: Bool = false) throws -> PDFDocument {
        let holes = format.components(separatedBy: "%d").count - 1
        guard (1...2).contains(holes) else {
            throw PDFToolsError.badValue("--format wants one or two %d — the page number, then the total")
        }
        guard anchor != .tile else { throw PDFToolsError.badValue("Page numbers do not tile") }
        let total = document.pageCount + start - 1
        return try overlay(document) { index, ctx, box in
            if skipFirst && index == 0 { return }
            let text = holes == 2 ? String(format: format, index + start, total)
                                  : String(format: format, index + start)
            let font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
            let line = Self.line(text, font: font, color: CGColor(gray: 0.25, alpha: 1))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let at = Self.point(for: anchor, in: box, inset: 28)
            ctx.textPosition = CGPoint(x: at.x - width / 2, y: at.y - 5)
            CTLineDraw(line, ctx)
        }
    }

    static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes))
    }

    static func point(for anchor: Anchor, in box: CGRect, inset: CGFloat) -> CGPoint {
        switch anchor {
        case .centre, .tile: return CGPoint(x: box.midX, y: box.midY)
        case .topLeft: return CGPoint(x: box.minX + inset, y: box.maxY - inset)
        case .topCentre: return CGPoint(x: box.midX, y: box.maxY - inset)
        case .topRight: return CGPoint(x: box.maxX - inset, y: box.maxY - inset)
        case .bottomLeft: return CGPoint(x: box.minX + inset, y: box.minY + inset)
        case .bottomCentre: return CGPoint(x: box.midX, y: box.minY + inset)
        case .bottomRight: return CGPoint(x: box.maxX - inset, y: box.minY + inset)
        }
    }
}
