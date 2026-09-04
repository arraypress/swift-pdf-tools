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

    /// The document cut into parts, none larger than `maxBytes` on disk.
    ///
    /// For a mail server, an upload limit, or anything else that counts
    /// megabytes rather than pages.
    ///
    /// Sizes are **measured, not estimated**. A PDF's pages share fonts and
    /// images, so bytes-per-page is not a number that exists: the same page
    /// costs almost nothing after its font is already embedded and a great
    /// deal before. What is true is that adding a page never makes the file
    /// smaller, and that monotonicity is what this leans on — each part grows
    /// by doubling until it overshoots, then binary-searches the boundary,
    /// so a part costs about `2 log n` serialisations rather than one per
    /// page.
    ///
    /// - Parameter oversize: called with the 1-based page number of any page
    ///   that exceeds `maxBytes` on its own. Such a page is emitted as a part
    ///   of its own — the alternative is an empty part and a loop that never
    ///   ends — so the caller can say the limit was not met and why.
    static func split(
        _ document: PDFDocument,
        maxBytes: Int,
        oversize: ((Int) -> Void)? = nil
    ) throws -> [PDFDocument] {

        guard maxBytes > 0 else { throw PDFToolsError.badValue("a size limit must be positive") }
        guard document.pageCount > 0 else { throw PDFToolsError.badPages("the document has no pages") }

        /// The serialised size of `count` pages starting at `start`.
        func size(from start: Int, count: Int) -> Int {
            let piece = PDFDocument()
            for index in start..<min(start + count, document.pageCount) {
                guard let page = document.page(at: index) else { continue }
                piece.insert(page, at: piece.pageCount)
            }
            return piece.dataRepresentation()?.count ?? Int.max
        }

        var parts: [PDFDocument] = []
        var start = 0

        while start < document.pageCount {
            let remaining = document.pageCount - start

            /// Double until it overshoots or the document runs out, so a
            /// document that fits whole costs one serialisation and not one
            /// per page.
            var fits = 0
            var probe = 1
            while probe <= remaining, size(from: start, count: probe) <= maxBytes {
                fits = probe
                if probe == remaining { break }
                probe = min(probe * 2, remaining)
            }

            if fits == 0 {
                /// Not even one page fits. Emit it alone and say so, rather
                /// than an empty part and a loop that never advances.
                oversize?(start + 1)
                fits = 1
            } else if fits < remaining, fits < probe {
                /// Somewhere between the last size that fitted and the first
                /// that did not. Size never falls as pages are added, so a
                /// binary search is sound.
                var low = fits, high = probe
                while low + 1 < high {
                    let middle = (low + high) / 2
                    if size(from: start, count: middle) <= maxBytes { low = middle } else { high = middle }
                }
                fits = low
            }

            let piece = PDFDocument()
            for index in start..<(start + fits) {
                guard let page = document.page(at: index) else { continue }
                piece.insert(page, at: piece.pageCount)
            }
            parts.append(piece)
            start += fits
        }
        return parts
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

// MARK: - Sizes

/// Reading a human-written size.
public enum ByteSize {

    /// `"5MB"`, `"500k"`, `"2.5 mb"`, `"1048576"` — bytes when no unit.
    ///
    /// Powers of 1024, because that is what a mail server's "25 MB" means
    /// and getting it wrong by 5% is the difference between a file that
    /// sends and one that bounces.
    public static func parse(_ text: String) -> Int? {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: "")
        let units: [(suffix: String, scale: Double)] = [
            ("gib", 1_073_741_824), ("gb", 1_073_741_824), ("g", 1_073_741_824),
            ("mib", 1_048_576), ("mb", 1_048_576), ("m", 1_048_576),
            ("kib", 1024), ("kb", 1024), ("k", 1024),
            ("b", 1),
        ]
        for (suffix, scale) in units where cleaned.hasSuffix(suffix) {
            guard let value = Double(cleaned.dropLast(suffix.count)), value > 0 else { return nil }
            return Int(value * scale)
        }
        guard let value = Double(cleaned), value > 0 else { return nil }
        return Int(value)
    }
}
