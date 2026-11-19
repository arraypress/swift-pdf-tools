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
//  Two rules for the ink. Text drawn here is never cut: it shrinks to fit
//  the page, then wraps, and only when it still cannot fit at the smallest
//  readable size does it run past the edge — and the caller is told.
//  And the page's own annotations survive: notes, links and form fields
//  are carried across live, not flattened into pictures of themselves.
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
    /// page's box with a bottom-left origin at zero.
    ///
    /// Annotations are not burned in. Drawn into the content, a sticky
    /// note became an icon with its text gone, a link stopped being one and
    /// a form stopped being fillable — the words of a note simply vanished.
    /// They are drawn hidden and carried across to the new page instead,
    /// moved by the same transform the page's content was.
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
            let shown = page.displaysAnnotations
            page.displaysAnnotations = false
            page.draw(with: .mediaBox, to: context)
            page.displaysAnnotations = shown
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
        carryAnnotations(from: document, to: out)
        return out
    }

    /// Copies every annotation onto the re-rendered pages, where the
    /// content they sit on was moved to.
    ///
    /// Rebuilt from each annotation's own dictionary: `copy()` keeps the
    /// type and little else — a field came back renamed `text11` and empty,
    /// a note without its words. The page reference and rectangle are left
    /// behind, since both belong to the old page. A popup is not carried on
    /// its own: it belongs to the note that owns it.
    static func carryAnnotations(from source: PDFDocument, to out: PDFDocument) {
        for index in 0..<min(source.pageCount, out.pageCount) {
            guard let page = source.page(at: index), let target = out.page(at: index) else { continue }
            let transform = page.transform(for: .mediaBox)
            for annotation in page.annotations where annotation.type != "Popup" {
                guard let type = annotation.type else { continue }
                let properties = annotation.annotationKeyValues.filter { key, _ in
                    !["/P", "/Rect", "/Popup", "/Parent"].contains("\(key.base)")
                }
                let moved = annotation.bounds.applying(transform)
                target.addAnnotation(PDFAnnotation(bounds: moved, forType: PDFAnnotationSubtype(rawValue: type),
                                                   withProperties: properties))
            }
        }
    }

    /// Stamps text (and/or an image) over every page.
    ///
    /// - Parameters:
    ///   - text: The watermark text, drawn in grey at `opacity`.
    ///   - image: An image watermark, drawn at half the page's width.
    ///   - opacity: `0…1`.
    ///   - angle: Degrees anticlockwise; 45 is the classic DRAFT slant.
    ///   - anchor: Where it sits; `.tile` repeats text across the page.
    ///   - onWarning: Told when the text cannot fit a page even at the
    ///     smallest size; it is still drawn whole, past the edge.
    ///
    /// Text shrinks to fit the page at its angle, then wraps onto more
    /// lines; it is never cut.
    static func watermark(_ document: PDFDocument, text: String? = nil, image: CGImage? = nil,
                          opacity: Double = 0.2, angle: Double = 45,
                          anchor: Anchor = .centre,
                          onWarning: (String) -> Void = { _ in }) throws -> PDFDocument {
        guard text != nil || image != nil else { throw PDFToolsError.badValue("A watermark wants text, an image, or both") }
        guard (0...1).contains(opacity) else { throw PDFToolsError.badValue("--opacity is 0…1") }
        var overflowing: [Int] = []
        let out = try overlay(document) { index, ctx, box in
            ctx.setAlpha(CGFloat(opacity))
            if let image {
                let width = box.width * 0.5
                let height = width * CGFloat(image.height) / CGFloat(max(1, image.width))
                let rect = CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
                ctx.draw(image, in: rect)
            }
            guard let text else { return }
            let preferred = max(18, min(box.width, box.height) * 0.09)
            let room = box.insetBy(dx: Self.edge, dy: Self.edge).size
            let set = Self.fit(text, font: "Helvetica-Bold", preferred: preferred, minimum: Self.smallestWatermark,
                               angle: angle, within: room, color: CGColor(gray: 0.35, alpha: 1))
            if !set.fits { overflowing.append(index + 1) }
            let radians = angle * .pi / 180
            func stamp(at point: CGPoint) {
                ctx.saveGState()
                ctx.translateBy(x: point.x, y: point.y)
                ctx.rotate(by: radians)
                set.draw(in: ctx, align: .centre)
                ctx.restoreGState()
            }
            switch anchor {
            case .tile:
                // A grid through the centre, so at least one copy is whole
                // however the steps fall at the edges.
                let stepX = max(set.width * 1.6, 120)
                let stepY = max(set.height * 6 / CGFloat(set.lines.count), 120)
                let rows = Int((box.height / 2) / stepY) + 2
                let columns = Int((box.width / 2) / stepX) + 2
                for row in -rows...rows {
                    let y = box.midY + CGFloat(row) * stepY
                    let shift = row % 2 == 0 ? 0 : stepX / 2
                    for column in -columns...columns {
                        stamp(at: CGPoint(x: box.midX + shift + CGFloat(column) * stepX, y: y))
                    }
                }
            default:
                let span = set.rotatedSize(angle)
                stamp(at: Self.point(for: anchor, in: box,
                                     insetX: min(max(span.width / 2 + Self.edge, 60), box.width / 2),
                                     insetY: min(max(span.height / 2 + Self.edge, 60), box.height / 2)))
            }
        }
        if !overflowing.isEmpty, let text {
            onWarning("The watermark \"\(text)\" does not fit \(Self.pages(overflowing)) even at "
                + "\(Int(Self.smallestWatermark)) pt; it is drawn whole but runs past the edge of the page.")
        }
        return out
    }

    /// Draws page numbers.
    ///
    /// `format` takes one or two `%d`s: the page number, then the total —
    /// `"Page %d of %d"`. Numbers start at `start` and `skipFirst` leaves
    /// a cover page clean (it still counts).
    ///
    /// A left anchor sets the text flush left at the inset and a right one
    /// flush right — centring it on a point 28 points from the edge put
    /// the first letters of "Page 100 of 120" off the page. Text too wide
    /// for the page shrinks, then wraps; `onWarning` hears of any that
    /// still cannot fit, which is drawn whole regardless.
    static func number(_ document: PDFDocument, format: String = "%d",
                       anchor: Anchor = .bottomCentre, start: Int = 1,
                       skipFirst: Bool = false,
                       onWarning: (String) -> Void = { _ in }) throws -> PDFDocument {
        let holes = format.components(separatedBy: "%d").count - 1
        guard (1...2).contains(holes) else {
            throw PDFToolsError.badValue("--format wants one or two %d — the page number, then the total")
        }
        guard anchor != .tile else { throw PDFToolsError.badValue("Page numbers do not tile") }
        let total = document.pageCount + start - 1
        let inset: CGFloat = 28
        var overflowing: [Int] = []
        var sample = ""
        let out = try overlay(document) { index, ctx, box in
            if skipFirst && index == 0 { return }
            let text = holes == 2 ? String(format: format, index + start, total)
                                  : String(format: format, index + start)
            let room = CGSize(width: box.width - inset * 2, height: box.height / 3)
            let set = Self.fit(text, font: "Helvetica", preferred: 10, minimum: Self.smallestNumber,
                               angle: 0, within: room, color: CGColor(gray: 0.25, alpha: 1))
            if !set.fits { overflowing.append(index + 1); sample = text }
            let at = Self.point(for: anchor, in: box, insetX: inset, insetY: inset)
            let align: Alignment
            let x: CGFloat
            switch anchor {
            case .topLeft, .bottomLeft: align = .left; x = at.x
            case .topRight, .bottomRight: align = .right; x = at.x
            default: align = .centre; x = at.x
            }
            // The baseline of the line nearest the edge stays where a
            // single number always sat; extra lines stack inwards.
            let top: Bool = [.topLeft, .topCentre, .topRight].contains(anchor)
            let nearest = at.y - 5
            let firstBaseline = top ? nearest : nearest + set.leading * CGFloat(set.lines.count - 1)
            ctx.saveGState()
            ctx.translateBy(x: x, y: firstBaseline)
            set.draw(in: ctx, align: align, fromBaseline: true)
            ctx.restoreGState()
        }
        if !overflowing.isEmpty {
            onWarning("The page number \"\(sample)\" does not fit \(Self.pages(overflowing)) even at "
                + "\(Int(Self.smallestNumber)) pt; it is drawn whole but runs past the edge of the page.")
        }
        return out
    }

    static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes))
    }

    static func point(for anchor: Anchor, in box: CGRect, inset: CGFloat) -> CGPoint {
        point(for: anchor, in: box, insetX: inset, insetY: inset)
    }

    static func point(for anchor: Anchor, in box: CGRect, insetX: CGFloat, insetY: CGFloat) -> CGPoint {
        switch anchor {
        case .centre, .tile: return CGPoint(x: box.midX, y: box.midY)
        case .topLeft: return CGPoint(x: box.minX + insetX, y: box.maxY - insetY)
        case .topCentre: return CGPoint(x: box.midX, y: box.maxY - insetY)
        case .topRight: return CGPoint(x: box.maxX - insetX, y: box.maxY - insetY)
        case .bottomLeft: return CGPoint(x: box.minX + insetX, y: box.minY + insetY)
        case .bottomCentre: return CGPoint(x: box.midX, y: box.minY + insetY)
        case .bottomRight: return CGPoint(x: box.maxX - insetX, y: box.minY + insetY)
        }
    }

    /// "page 3" or "pages 1, 2, 5".
    static func pages(_ numbers: [Int]) -> String {
        numbers.count == 1 ? "page \(numbers[0])" : "pages " + numbers.map(String.init).joined(separator: ", ")
    }

    /// Space kept between a watermark and the page edge.
    static let edge: CGFloat = 24

    /// The smallest a watermark is set before it is allowed past the edge.
    static let smallestWatermark: CGFloat = 8

    /// The smallest a page number is set before it is allowed past the edge.
    static let smallestNumber: CGFloat = 6
}
