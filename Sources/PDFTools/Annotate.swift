//
//  Annotate.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  Live annotations — the ones a reader can see, select and delete,
//  unlike the overlay engine's burned-in ink. Markup rides on text
//  search: "highlight every mention" needs no coordinates, which is
//  what makes it usable on documents that arrive laid out differently
//  every time. Freehand ink is deliberately absent: a terminal has no
//  hand to draw with, and pretending otherwise would only produce
//  scribbles nobody chose.
//

import Foundation
import PDFKit
#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

public extension PDFTools {

    /// The text-markup styles.
    enum MarkupStyle: String, CaseIterable, Sendable {
        case highlight, underline, strikeout

        var annotationType: PDFAnnotationSubtype {
            switch self {
            case .highlight: return .highlight
            case .underline: return .underline
            case .strikeout: return .strikeOut
            }
        }
    }

    /// Marks every match of `query` with a live annotation, per text line.
    ///
    /// - Returns: The matches marked, page and box included.
    /// - Throws: ``PDFToolsError/badValue(_:)`` when nothing matches.
    @discardableResult
    static func markup(_ document: PDFDocument, query: String,
                       style: MarkupStyle = .highlight, color: CGColor? = nil,
                       pages: [Int]? = nil) throws -> [Match] {
        let wanted = try indices(pages, in: document)
        var marked: [Match] = []
        for selection in document.findString(query, withOptions: .caseInsensitive) {
            for line in selection.selectionsByLine() {
                guard let page = line.pages.first,
                      let index = pageIndex(of: page, in: document),
                      wanted.contains(index) else { continue }
                let bounds = line.bounds(for: page)
                let annotation = PDFAnnotation(bounds: bounds, forType: style.annotationType, withProperties: nil)
                annotation.color = Self.resolvedColor(color ?? Self.defaultMarkupColor(style))
                annotation.contents = query
                page.addAnnotation(annotation)
                let media = page.bounds(for: .mediaBox)
                marked.append(Match(page: index + 1,
                                    rect: CGRect(x: bounds.minX - media.minX, y: media.maxY - bounds.maxY,
                                                 width: bounds.width, height: bounds.height),
                                    text: line.string ?? query))
            }
        }
        guard !marked.isEmpty else {
            throw PDFToolsError.badValue("\"\(query)\" was not found — `find` shows what is")
        }
        return marked
    }

    /// Where a note goes.
    enum NotePlacement: Sendable, Equatable {
        /// Page (zero-based) and a point in top-left coordinates.
        case at(Int, Double, Double)
        /// Beside the first match of this text.
        case above(String)
    }

    /// Adds a sticky-note annotation carrying `text`.
    @discardableResult
    static func note(_ document: PDFDocument, text: String, placement: NotePlacement) throws -> Match {
        let target: Int
        let anchor: CGPoint   // PDF space
        switch placement {
        case .at(let index, let x, let y):
            guard (0..<document.pageCount).contains(index) else {
                throw PDFToolsError.badPages("The document has \(document.pageCount) pages; page \(index + 1) does not exist")
            }
            let media = document.page(at: index)!.bounds(for: .mediaBox)
            target = index
            anchor = CGPoint(x: media.minX + x, y: media.maxY - y)
        case .above(let query):
            guard let first = find(query, in: document).first else {
                throw PDFToolsError.badValue("\"\(query)\" was not found — `find` shows what is")
            }
            target = first.page - 1
            let media = document.page(at: target)!.bounds(for: .mediaBox)
            anchor = CGPoint(x: media.minX + first.rect.maxX + 4, y: media.maxY - first.rect.minY)
        }
        guard let page = document.page(at: target) else {
            throw PDFToolsError.badPages("Page \(target + 1) could not be read")
        }
        let size: CGFloat = 20
        let bounds = CGRect(x: anchor.x, y: anchor.y - size, width: size, height: size)
        let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
        annotation.contents = text
        annotation.color = PlatformColor.systemYellow
        annotation.iconType = .note
        page.addAnnotation(annotation)
        let media = page.bounds(for: .mediaBox)
        return Match(page: target + 1,
                     rect: CGRect(x: bounds.minX - media.minX, y: media.maxY - bounds.maxY,
                                  width: bounds.width, height: bounds.height),
                     text: text)
    }

    /// Turns every match of `query` into a live link to `url`.
    @discardableResult
    static func link(_ document: PDFDocument, query: String, url: URL) throws -> [Match] {
        var linked: [Match] = []
        for selection in document.findString(query, withOptions: .caseInsensitive) {
            for line in selection.selectionsByLine() {
                guard let page = line.pages.first, let index = pageIndex(of: page, in: document) else { continue }
                let bounds = line.bounds(for: page)
                let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
                annotation.action = PDFActionURL(url: url)
                page.addAnnotation(annotation)
                let media = page.bounds(for: .mediaBox)
                linked.append(Match(page: index + 1,
                                    rect: CGRect(x: bounds.minX - media.minX, y: media.maxY - bounds.maxY,
                                                 width: bounds.width, height: bounds.height),
                                    text: line.string ?? query))
            }
        }
        guard !linked.isEmpty else {
            throw PDFToolsError.badValue("\"\(query)\" was not found — `find` shows what is")
        }
        return linked
    }

    /// The platform colour for a CGColor, total on both platforms.
    private static func resolvedColor(_ cg: CGColor) -> PlatformColor {
        #if canImport(AppKit)
        return NSColor(cgColor: cg) ?? .yellow
        #else
        return UIColor(cgColor: cg)
        #endif
    }

    private static func defaultMarkupColor(_ style: MarkupStyle) -> CGColor {
        style == .highlight
            ? CGColor(red: 1, green: 0.9, blue: 0.2, alpha: 1)
            : CGColor(red: 0.85, green: 0.15, blue: 0.1, alpha: 1)
    }
}
