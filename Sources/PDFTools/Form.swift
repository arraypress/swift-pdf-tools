//
//  Form.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  Form fields: what a document asks for, and filling it in. PDFKit's
//  widget annotations round-trip through save, so a filled form stays
//  filled in any reader.
//

import Foundation
import PDFKit

public extension PDFTools {

    /// One form field.
    struct Field: Sendable, Equatable {
        /// The field's name — what `--set` addresses.
        public let name: String
        /// `text`, `checkbox`, `radio`, `choice` or `button`.
        public let kind: String
        /// The current value, as text ("on"/"off" for checkboxes).
        public let value: String
        /// One-based page the field sits on.
        public let page: Int
    }

    /// Every form field in the document, in page order.
    static func fields(_ document: PDFDocument) -> [Field] {
        var out: [Field] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for widget in page.annotations where widget.isWidgetAnnotation {
                let kind: String
                let value: String
                switch widget.widgetFieldType {
                case .button:
                    kind = widget.widgetControlType == .radioButtonControl ? "radio"
                         : widget.widgetControlType == .checkBoxControl ? "checkbox" : "button"
                    value = widget.buttonWidgetState == .onState ? "on" : "off"
                case .choice:
                    kind = "choice"
                    value = widget.widgetStringValue ?? ""
                default:
                    kind = "text"
                    value = widget.widgetStringValue ?? ""
                }
                out.append(Field(name: widget.fieldName ?? "", kind: kind, value: value, page: index + 1))
            }
        }
        return out
    }

    /// Sets fields by name, in place. Checkboxes take truthy text
    /// (`true`, `on`, `yes`, `1` — anything else is off).
    static func fill(_ document: PDFDocument, values: [String: String]) throws {
        var unmet = Set(values.keys)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for widget in page.annotations where widget.isWidgetAnnotation {
                guard let name = widget.fieldName, let value = values[name] else { continue }
                unmet.remove(name)
                if widget.widgetFieldType == .button {
                    let truthy = ["true", "on", "yes", "1"].contains(value.lowercased())
                    widget.buttonWidgetState = truthy ? .onState : .offState
                } else {
                    widget.widgetStringValue = value
                }
            }
        }
        guard unmet.isEmpty else {
            throw PDFToolsError.badValue("No form field called \(unmet.sorted().map { "\"\($0)\"" }.joined(separator: ", ")) — `form` lists them")
        }
    }

    /// A password-free copy of an unlocked document.
    ///
    /// Writing an unlocked `PDFDocument` back to disk KEEPS its encryption —
    /// the lock rides along in the saved bytes. Moving the pages into a
    /// fresh document is what actually drops it.
    static func unlocked(_ document: PDFDocument) -> PDFDocument {
        merge([document])
    }

    /// Encrypts on write; `nil` owner falls back to the user password.
    static func protect(_ document: PDFDocument, to url: URL, userPassword: String, ownerPassword: String? = nil) throws {
        guard !userPassword.isEmpty else { throw PDFToolsError.badValue("An empty password protects nothing") }
        try write(document, to: url, options: [
            .userPasswordOption: userPassword,
            .ownerPasswordOption: ownerPassword ?? userPassword,
        ])
    }
}

extension PDFAnnotation {
    /// Whether this annotation is a form widget.
    var isWidgetAnnotation: Bool { type == "Widget" }
}
