//
//  Meta.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  The document's card catalogue entry: who wrote it, what it is, when.
//  Reading costs nothing; writing goes through a save, so the setter
//  returns the document for the caller to write.
//

import Foundation
import PDFKit

public extension PDFTools {

    /// A document's attributes, empty strings for what is absent.
    struct Metadata: Sendable, Equatable {
        public let title: String
        public let author: String
        public let subject: String
        public let keywords: String
        public let creator: String
        public let producer: String
        public let created: String
        public let modified: String
    }

    /// The attribute names `setMetadata` accepts.
    static let metadataKeys = ["title", "author", "subject", "keywords", "creator"]

    /// Reads the document's attributes.
    static func metadata(_ document: PDFDocument) -> Metadata {
        let attributes = document.documentAttributes ?? [:]
        func text(_ key: PDFDocumentAttribute) -> String {
            if let value = attributes[key] as? String { return value }
            if let list = attributes[key] as? [String] { return list.joined(separator: ", ") }
            if let date = attributes[key] as? Date {
                let formatter = ISO8601DateFormatter()
                return formatter.string(from: date)
            }
            return ""
        }
        return Metadata(title: text(.titleAttribute), author: text(.authorAttribute),
                        subject: text(.subjectAttribute), keywords: text(.keywordsAttribute),
                        creator: text(.creatorAttribute), producer: text(.producerAttribute),
                        created: text(.creationDateAttribute), modified: text(.modificationDateAttribute))
    }

    /// Sets attributes by name (see ``metadataKeys``); keywords split on commas.
    static func setMetadata(_ document: PDFDocument, values: [String: String]) throws {
        var attributes = document.documentAttributes ?? [:]
        for (key, value) in values {
            switch key.lowercased() {
            case "title": attributes[PDFDocumentAttribute.titleAttribute] = value
            case "author": attributes[PDFDocumentAttribute.authorAttribute] = value
            case "subject": attributes[PDFDocumentAttribute.subjectAttribute] = value
            case "creator": attributes[PDFDocumentAttribute.creatorAttribute] = value
            case "keywords":
                attributes[PDFDocumentAttribute.keywordsAttribute] = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            default:
                throw PDFToolsError.badValue("Metadata keys are \(metadataKeys.joined(separator: ", ")); \"\(key)\" is not one")
            }
        }
        document.documentAttributes = attributes
    }
}
