//
//  PDFToolsError.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  What goes wrong with a PDF, in words a person can act on. The library
//  says what happened; a command-line client maps each case to its exit
//  code, a window shows the message.
//

import Foundation

/// A PDF could not be read, changed or written.
public enum PDFToolsError: Error, LocalizedError, Sendable, Equatable {
    /// The file is not a PDF this machine can open.
    case unreadable(String)
    /// The document is encrypted and the password given (or none) does not open it.
    case locked(String)
    /// A page selection names pages the document does not have.
    case badPages(String)
    /// An option's value cannot mean anything ("rotate by 45").
    case badValue(String)
    /// An image could not be read or placed.
    case badImage(String)
    /// The output could not be written.
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let m), .locked(let m), .badPages(let m),
             .badValue(let m), .badImage(let m), .writeFailed(let m):
            return m
        }
    }
}
