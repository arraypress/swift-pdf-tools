//
//  Sign.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  The signature stamp: a PNG of a real signature placed on a page —
//  at a point, above a label found by text search (the way documents
//  that arrive different every time get signed without coordinates),
//  or into a named form field. The stamp is FLATTENED into the page:
//  it is ink, not a cryptographic signature, and the help must say so.
//

import Foundation
import ImageIO
import PDFKit

public extension PDFTools {

    /// Where a signature goes.
    enum SignPlacement: Sendable, Equatable {
        /// Fractions of the page, top-left origin; the stamp is centred here.
        case at(Double, Double)
        /// Directly above the first match of this text — label left-aligned.
        case above(String)
        /// To the right of the first match of this text, on its baseline.
        case near(String)
        /// Fitted into the named form field's box.
        case field(String)
    }

    /// What `sign` did, so a caller can say where the ink went.
    struct SignReport: Sendable, Equatable {
        /// One-based page that was signed.
        public let page: Int
        /// The stamp's box in points, top-left origin, page-relative.
        public let rect: CGRect
    }

    /// Stamps `signature` onto the document.
    ///
    /// - Parameters:
    ///   - document: The document; re-rendered on the way out.
    ///   - signature: The signature image (transparent PNG reads best).
    ///   - placement: Where — see ``SignPlacement``.
    ///   - page: Zero-based page for `.at`, and a restriction for the
    ///     searching placements; `nil` means the last page for `.at` and
    ///     "wherever the text is first found" for the others.
    ///   - width: Stamp width in points; height keeps the image's aspect.
    ///   - dated: Draws today's date under the stamp.
    static func sign(_ document: PDFDocument, signature: CGImage,
                     placement: SignPlacement, page: Int? = nil,
                     width: Double = 160, dated: Bool = false) throws -> (PDFDocument, SignReport) {
        guard width > 8 else { throw PDFToolsError.badValue("--width is in points; \(width) is too small to see") }
        let stampW = CGFloat(width)
        let stampH = stampW * CGFloat(signature.height) / CGFloat(max(1, signature.width))

        // Resolve the target page and the stamp's rect in PDF space.
        var target: Int
        var rect: CGRect
        switch placement {
        case .at(let fx, let fy):
            guard (0...1).contains(fx), (0...1).contains(fy) else {
                throw PDFToolsError.badValue("--at wants fractions 0…1, top-left origin")
            }
            target = try resolved(page, in: document) ?? document.pageCount - 1
            let box = try pageBox(document, target)
            let centre = CGPoint(x: box.minX + box.width * fx, y: box.maxY - box.height * fy)
            rect = CGRect(x: centre.x - stampW / 2, y: centre.y - stampH / 2, width: stampW, height: stampH)
        case .above(let query), .near(let query):
            let restricted = try resolved(page, in: document)
            guard let hit = firstMatch(of: query, in: document, page: restricted) else {
                throw PDFToolsError.badValue("\"\(query)\" was not found" + (restricted.map { " on page \($0 + 1)" } ?? ""))
            }
            target = hit.page
            if case .above = placement {
                rect = CGRect(x: hit.bounds.minX, y: hit.bounds.maxY + 6, width: stampW, height: stampH)
            } else {
                rect = CGRect(x: hit.bounds.maxX + 12, y: hit.bounds.midY - stampH / 2, width: stampW, height: stampH)
            }
        case .field(let name):
            var found: (Int, CGRect)?
            for index in 0..<document.pageCount {
                guard let p = document.page(at: index) else { continue }
                if let widget = p.annotations.first(where: { $0.isWidgetAnnotation && $0.fieldName == name }) {
                    found = (index, widget.bounds)
                    break
                }
            }
            guard let (index, box) = found else {
                throw PDFToolsError.badValue("The document has no form field called \"\(name)\" — `form` lists them")
            }
            target = index
            let scale = min(box.width / stampW, box.height / stampH, 1)
            let w = stampW * scale, h = stampH * scale
            rect = CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
        }

        // Ink off the page helps nobody: keep the stamp inside the box,
        // shifted rather than shrunk (a label near an edge still gets
        // signed, just as close to it as fits).
        let media = try pageBox(document, target)
        var pinned = rect
        if pinned.width > media.width { 
            let scale = media.width / pinned.width
            pinned = CGRect(x: pinned.minX, y: pinned.minY, width: media.width, height: pinned.height * scale)
        }
        if pinned.height > media.height {
            let scale = media.height / pinned.height
            pinned = CGRect(x: pinned.minX, y: pinned.minY, width: pinned.width * scale, height: media.height)
        }
        if pinned.minX < media.minX { pinned.origin.x = media.minX }
        if pinned.maxX > media.maxX { pinned.origin.x = media.maxX - pinned.width }
        if pinned.minY < media.minY { pinned.origin.y = media.minY }
        if pinned.maxY > media.maxY { pinned.origin.y = media.maxY - pinned.height }
        let placedRect = pinned
        let out = try overlay(document) { index, ctx, _ in
            guard index == target else { return }
            ctx.draw(signature, in: placedRect)
            if dated {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let font = CTFontCreateWithName("Helvetica" as CFString, 9, nil)
                let line = Self.line(formatter.string(from: Date()), font: font, color: CGColor(gray: 0.3, alpha: 1))
                ctx.textPosition = CGPoint(x: placedRect.minX, y: placedRect.minY - 11)
                CTLineDraw(line, ctx)
            }
        }
        let topLeft = CGRect(x: placedRect.minX - media.minX, y: media.maxY - placedRect.maxY,
                             width: placedRect.width, height: placedRect.height)
        return (out, SignReport(page: target + 1, rect: topLeft))
    }

    /// Loads a signature image from disk.
    static func image(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PDFToolsError.badImage("\(url.path) is not an image this machine can read")
        }
        return image
    }

    private static func resolved(_ page: Int?, in document: PDFDocument) throws -> Int? {
        guard let page else { return nil }
        guard (0..<document.pageCount).contains(page) else {
            throw PDFToolsError.badPages("The document has \(document.pageCount) pages; page \(page + 1) does not exist")
        }
        return page
    }

    private static func pageBox(_ document: PDFDocument, _ index: Int) throws -> CGRect {
        guard let page = document.page(at: index) else {
            throw PDFToolsError.badPages("Page \(index + 1) could not be read")
        }
        return page.bounds(for: .mediaBox)
    }

    private static func firstMatch(of query: String, in document: PDFDocument, page: Int?) -> (page: Int, bounds: CGRect)? {
        for selection in document.findString(query, withOptions: .caseInsensitive) {
            guard let p = selection.pages.first, let index = pageIndex(of: p, in: document) else { continue }
            if let page, index != page { continue }
            return (index, selection.bounds(for: p))
        }
        return nil
    }

    static func pageIndex(of page: PDFPage, in document: PDFDocument) -> Int? {
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }
}
