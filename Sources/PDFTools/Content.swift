//
//  Content.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  What the document says and where it says it. `find` is the anchor
//  primitive: it turns "above the signature line" into a page and a
//  rectangle, which is what lets a robot handle documents that arrive
//  laid out differently every time.
//

import Foundation
import PDFKit

public extension PDFTools {

    /// One place a query matched.
    struct Match: Sendable, Equatable {
        /// One-based page.
        public let page: Int
        /// The match's box in points, top-left origin, page-relative.
        public let rect: CGRect
        /// The matched text as it appears.
        public let text: String
    }

    /// The document's text, optionally only from `pages` (zero-based).
    static func text(_ document: PDFDocument, pages: [Int]? = nil) throws -> String {
        try indices(pages, in: document)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    /// Every match of `query`, case-insensitively, with page and box.
    static func find(_ query: String, in document: PDFDocument) -> [Match] {
        document.findString(query, withOptions: .caseInsensitive).compactMap { selection in
            guard let page = selection.pages.first, let index = pageIndex(of: page, in: document) else { return nil }
            let media = page.bounds(for: .mediaBox)
            let bounds = selection.bounds(for: page)
            return Match(page: index + 1,
                         rect: CGRect(x: bounds.minX - media.minX, y: media.maxY - bounds.maxY,
                                      width: bounds.width, height: bounds.height),
                         text: selection.string ?? query)
        }
    }
}
