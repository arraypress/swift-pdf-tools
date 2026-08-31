//
//  Outline.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  The table of contents: reading the outline tree, and building one.
//  Building goes through a Core Graphics re-render, because PDFKit's own
//  save DROPS a changed `outlineRoot` on current macOS — probed in every
//  permutation (assign before or after building, `write(to:)` and
//  `dataRepresentation()`, documents from URL and from data; the outline
//  survives none of them). `CGPDFContextSetOutline` survives, at the
//  overlay engine's usual price: the output is a re-rendered document.
//  Building supports flat entries plus one nesting level ("Parent>Child")
//  — deep hierarchies are an authoring-tool job.
//

import CoreGraphics
import Foundation
import PDFKit

public extension PDFTools {

    /// One line of the table of contents.
    struct TOCEntry: Sendable, Equatable {
        /// The label as the reader shows it.
        public let title: String
        /// One-based destination page, 0 when the entry points nowhere.
        public let page: Int
        /// 0 for top level, 1 for a child, and so on.
        public let depth: Int
    }

    /// The document's outline, walked depth-first.
    static func outline(_ document: PDFDocument) -> [TOCEntry] {
        var out: [TOCEntry] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let page = child.destination?.page.flatMap { pageIndex(of: $0, in: document) }
                out.append(TOCEntry(title: child.label ?? "", page: (page ?? -1) + 1, depth: depth))
                walk(child, depth: depth + 1)
            }
        }
        if let root = document.outlineRoot { walk(root, depth: 0) }
        return out
    }

    /// A copy of the document carrying the given outline entries on top of
    /// what it already had (one existing nesting level is preserved).
    ///
    /// Entries are `(title, page)` flat, or a title of `"Parent>Child"` to
    /// nest one level under `Parent` (created on the child's page when it
    /// does not exist yet). The copy is RE-RENDERED — same trade as the
    /// overlay verbs, and the reason the outline actually persists.
    static func addOutline(_ document: PDFDocument, entries: [(title: String, page: Int)]) throws -> PDFDocument {
        // The tree: title → (page, children in order).
        struct Node { var title: String; var page: Int; var children: [(String, Int)] = [] }
        var top: [Node] = []
        for existing in outline(document) where existing.depth <= 1 {
            if existing.depth == 0 {
                top.append(Node(title: existing.title, page: max(0, existing.page - 1)))
            } else if !top.isEmpty {
                top[top.count - 1].children.append((existing.title, max(0, existing.page - 1)))
            }
        }
        for entry in entries {
            guard (0..<document.pageCount).contains(entry.page) else {
                throw PDFToolsError.badPages("The document has \(document.pageCount) pages; page \(entry.page + 1) does not exist")
            }
            let parts = entry.title.split(separator: ">", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let leaf = parts.last, !leaf.isEmpty else {
                throw PDFToolsError.badValue("An outline entry needs a title")
            }
            if parts.count == 2 {
                if let index = top.firstIndex(where: { $0.title == parts[0] }) {
                    top[index].children.append((leaf, entry.page))
                } else {
                    top.append(Node(title: parts[0], page: entry.page, children: [(leaf, entry.page)]))
                }
            } else {
                top.append(Node(title: leaf, page: entry.page))
            }
        }

        func dictionary(_ title: String, _ page: Int, _ children: [(String, Int)]) -> [String: Any] {
            var node: [String: Any] = ["Title": title, "Destination": page + 1]
            if !children.isEmpty { node["Children"] = children.map { ["Title": $0.0, "Destination": $0.1 + 1] } }
            return node
        }
        let tree: [String: Any] = ["Children": top.map { dictionary($0.title, $0.page, $0.children) }]

        // Re-render with the outline set at the Core Graphics level.
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
            page.draw(with: .mediaBox, to: context)
            context.endPDFPage()
        }
        CGPDFContextSetOutline(context, tree as CFDictionary)
        context.closePDF()
        guard let out = PDFDocument(data: data as Data) else {
            throw PDFToolsError.writeFailed("The re-rendered document could not be read back")
        }
        return out
    }
}
