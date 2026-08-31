//
//  Opening.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  Reading and writing, with the lock handled in one place. Every verb
//  starts by opening a document, and a locked file must fail the same
//  way everywhere: naming the file, asking for the password.
//

import Foundation
import PDFKit

/// The manipulation toolkit: existing PDFs in, changed PDFs out.
public enum PDFTools {

    /// Opens a PDF, unlocking it when a password is given.
    ///
    /// - Throws: ``PDFToolsError/unreadable(_:)`` for non-PDFs,
    ///   ``PDFToolsError/locked(_:)`` when the document needs a password
    ///   this call was not given (or was given wrongly).
    public static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw PDFToolsError.unreadable("\(url.path) is not a PDF this machine can open")
        }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password) else {
                throw PDFToolsError.locked("\(url.lastPathComponent) is password-protected"
                                           + (password == nil ? "" : " and that password does not open it"))
            }
        }
        return document
    }

    /// Writes a document, throwing rather than failing silently.
    public static func write(_ document: PDFDocument, to url: URL,
                             options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard document.write(to: url, withOptions: options.isEmpty ? nil : options) else {
            throw PDFToolsError.writeFailed("Could not write \(url.path)")
        }
    }

    /// The pages named by `pages`, or every page when `pages` is nil —
    /// validated against the document, zero-based, in ascending order.
    static func indices(_ pages: [Int]?, in document: PDFDocument) throws -> [Int] {
        let all = Array(0..<document.pageCount)
        guard let pages else { return all }
        let bad = pages.filter { $0 < 0 || $0 >= document.pageCount }
        guard bad.isEmpty else {
            throw PDFToolsError.badPages("The document has \(document.pageCount) pages; page \(bad.map { String($0 + 1) }.joined(separator: ", ")) does not exist")
        }
        return pages.sorted()
    }
}
