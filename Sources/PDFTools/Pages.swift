//
//  Pages.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  The page-shuffling verbs: merge, split, extract, delete, reorder,
//  rotate, crop. All of them are PDFKit page moves — no rendering, so
//  text, links and form fields ride along untouched.
//

import Foundation
import PDFKit

public extension PDFTools {

    /// One document from many, pages in the order the inputs were given.
    static func merge(_ inputs: [PDFDocument]) -> PDFDocument {
        let merged = PDFDocument()
        for document in inputs {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }
        return merged
    }

    /// The document as chunks of `every` pages (the last may be shorter).
    static func split(_ document: PDFDocument, every: Int) throws -> [PDFDocument] {
        guard every >= 1 else { throw PDFToolsError.badValue("--every wants at least 1") }
        var cuts: [Int] = []
        var next = every
        while next < document.pageCount { cuts.append(next); next += every }
        return try split(document, before: cuts)
    }

    /// The document cut before each zero-based index in `cuts`.
    static func split(_ document: PDFDocument, before cuts: [Int]) throws -> [PDFDocument] {
        let bad = cuts.filter { $0 <= 0 || $0 >= document.pageCount }
        guard bad.isEmpty else {
            throw PDFToolsError.badPages("A split point must fall inside the document (pages 2…\(document.pageCount)); \(bad.map { String($0 + 1) }.joined(separator: ", ")) does not")
        }
        let bounds = [0] + cuts.sorted() + [document.pageCount]
        return (0..<(bounds.count - 1)).map { part in
            let piece = PDFDocument()
            for index in bounds[part]..<bounds[part + 1] {
                guard let page = document.page(at: index) else { continue }
                piece.insert(page, at: piece.pageCount)
            }
            return piece
        }
    }

    /// A new document holding only `pages` (zero-based), in ascending order.
    static func extract(_ document: PDFDocument, pages: [Int]) throws -> PDFDocument {
        let keep = try indices(pages, in: document)
        guard !keep.isEmpty else { throw PDFToolsError.badPages("Nothing to extract") }
        let piece = PDFDocument()
        for index in keep {
            guard let page = document.page(at: index) else { continue }
            piece.insert(page, at: piece.pageCount)
        }
        return piece
    }

    /// Removes `pages` (zero-based) in place.
    static func delete(_ document: PDFDocument, pages: [Int]) throws {
        let doomed = try indices(pages, in: document)
        guard doomed.count < document.pageCount else {
            throw PDFToolsError.badPages("Deleting every page leaves no document")
        }
        for index in doomed.reversed() { document.removePage(at: index) }
    }

    /// Rebuilds the document in `order` — a complete permutation of its
    /// pages, zero-based, because a partial order silently dropping pages
    /// is a data-loss trap.
    static func reorder(_ document: PDFDocument, order: [Int]) throws -> PDFDocument {
        guard order.sorted() == Array(0..<document.pageCount) else {
            throw PDFToolsError.badPages("--reorder must name every page exactly once (the document has \(document.pageCount))")
        }
        let shuffled = PDFDocument()
        for index in order {
            guard let page = document.page(at: index) else { continue }
            shuffled.insert(page, at: shuffled.pageCount)
        }
        return shuffled
    }

    /// Rotates pages clockwise by 90, 180 or 270 degrees, in place.
    static func rotate(_ document: PDFDocument, pages: [Int]? = nil, by degrees: Int) throws {
        guard [90, 180, 270].contains(degrees) else {
            throw PDFToolsError.badValue("PDF pages rotate in quarter turns: 90, 180 or 270")
        }
        for index in try indices(pages, in: document) {
            guard let page = document.page(at: index) else { continue }
            page.rotation = (page.rotation + degrees) % 360
        }
    }

    /// Crops pages to `box`, given in points with a TOP-LEFT origin — the
    /// way people read a page — converted here to PDF space, in place.
    static func crop(_ document: PDFDocument, pages: [Int]? = nil, toTopLeft box: CGRect) throws {
        guard box.width > 0, box.height > 0 else {
            throw PDFToolsError.badValue("--box wants x,y,width,height with a positive size")
        }
        for index in try indices(pages, in: document) {
            guard let page = document.page(at: index) else { continue }
            let media = page.bounds(for: .mediaBox)
            let pdfBox = CGRect(x: media.minX + box.minX,
                                y: media.maxY - box.minY - box.height,
                                width: box.width, height: box.height)
            let clipped = pdfBox.intersection(media)
            guard !clipped.isEmpty else {
                throw PDFToolsError.badValue("The crop box lies outside page \(index + 1) (\(Int(media.width))×\(Int(media.height)) pt)")
            }
            page.setBounds(clipped, for: .cropBox)
        }
    }
}
