//
//  Repair.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  Salvage, never a promise. A damaged PDF is rewritten by copying every
//  page that still parses into a fresh document — new cross-reference
//  table, new structure. What no longer parses is REPORTED lost, not
//  silently dropped; and when the file's structure is gone entirely,
//  the honest answer is that rewriting cannot recover it.
//

import CoreGraphics
import Foundation
import PDFKit

public extension PDFTools {

    /// What a salvage pass managed.
    struct RepairReport: Sendable, Equatable {
        /// Pages the damaged file claims to have.
        public let claimed: Int
        /// Pages that parsed and were copied out.
        public let recovered: Int
        /// The pages that were lost, counting from 1.
        public let lostPages: [Int]
        /// True when the file opened cleanly and nothing needed saving.
        public let wasIntact: Bool
    }

    /// Rewrites `url` into `output`, keeping every page that still parses.
    ///
    /// - Throws: ``PDFToolsError/unreadable(_:)`` when the document's
    ///   structure is gone — a file whose cross-reference table cannot be
    ///   found holds nothing a rewrite can reach.
    static func repair(_ url: URL, to output: URL) throws -> RepairReport {
        guard let source = CGPDFDocument(url as CFURL) else {
            throw PDFToolsError.unreadable(
                "\(url.lastPathComponent) has no readable PDF structure — rewriting cannot recover it")
        }
        if source.isEncrypted, !source.isUnlocked {
            throw PDFToolsError.locked("\(url.lastPathComponent) is password-protected; unlock it before repairing")
        }
        let claimed = source.numberOfPages
        guard claimed > 0 else {
            throw PDFToolsError.unreadable(
                "\(url.lastPathComponent) parses but holds no readable pages — rewriting cannot recover it")
        }

        // Whether PDFKit already reads the whole thing cleanly.
        let intact: Bool = {
            guard let doc = PDFDocument(url: url), doc.pageCount == claimed else { return false }
            return (0..<doc.pageCount).allSatisfy { doc.page(at: $0) != nil }
        }()

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw PDFToolsError.writeFailed("Could not start a PDF context")
        }
        var lost: [Int] = []
        for number in 1...claimed {
            guard let page = source.page(at: number) else {
                lost.append(number)
                continue
            }
            var box = page.getBoxRect(.mediaBox)
            if box.isEmpty { box = CGRect(x: 0, y: 0, width: 612, height: 792) }
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(info as CFDictionary)
            context.saveGState()
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()

        let recovered = claimed - lost.count
        guard recovered > 0 else {
            throw PDFToolsError.unreadable(
                "\(url.lastPathComponent): none of its \(claimed) pages parse — rewriting cannot recover it")
        }
        guard data.write(to: output, atomically: true) else {
            throw PDFToolsError.writeFailed("Could not write \(output.path)")
        }
        return RepairReport(claimed: claimed, recovered: recovered, lostPages: lost, wasIntact: intact && lost.isEmpty)
    }
}
