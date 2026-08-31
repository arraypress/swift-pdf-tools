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
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

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
    /// `allowsPrinting`/`allowsCopying` false turn the permission off in
    /// the saved file. The flags bind USER-password openers only — an
    /// owner password holds owner rights — so restricting anything with
    /// `nil` owner restricts nobody; pass a distinct owner password.
    static func protect(_ document: PDFDocument, to url: URL, userPassword: String, ownerPassword: String? = nil,
                        allowsPrinting: Bool = true, allowsCopying: Bool = true) throws {
        guard !userPassword.isEmpty else { throw PDFToolsError.badValue("An empty password protects nothing") }
        var options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: userPassword,
            .ownerPasswordOption: ownerPassword ?? userPassword,
        ]
        if !allowsPrinting { options[PDFDocumentWriteOption(rawValue: kCGPDFContextAllowsPrinting as String)] = false }
        if !allowsCopying { options[PDFDocumentWriteOption(rawValue: kCGPDFContextAllowsCopying as String)] = false }
        try write(document, to: url, options: options)
    }

    /// The field kinds `addField` can author.
    enum FieldKind: String, CaseIterable, Sendable {
        case text, checkbox, choice
    }

    /// Authors one form widget on `page`, `rect` in points with a
    /// top-left origin. `options` populates a `choice` field's menu.
    static func addField(_ document: PDFDocument, kind: FieldKind, name: String,
                         page index: Int, rect topLeft: CGRect, options: [String] = []) throws {
        guard !name.isEmpty else { throw PDFToolsError.badValue("A field needs a name") }
        guard let page = document.page(at: index) else {
            throw PDFToolsError.badPages("The document has \(document.pageCount) pages; page \(index + 1) does not exist")
        }
        if kind == .choice, options.isEmpty {
            throw PDFToolsError.badValue("A choice field needs --options a,b,c")
        }
        let media = page.bounds(for: .mediaBox)
        let bounds = CGRect(x: media.minX + topLeft.minX,
                            y: media.maxY - topLeft.minY - topLeft.height,
                            width: topLeft.width, height: topLeft.height)
        let widget = PDFAnnotation(bounds: bounds, forType: .widget, withProperties: nil)
        // The ORDER below is load-bearing: a name set before the field type
        // is thrown away by the save and the field reopens as "text0" —
        // type first, name second, found by probing every permutation.
        switch kind {
        case .text:
            widget.widgetFieldType = .text
            widget.backgroundColor = PlatformColor(white: 0.97, alpha: 1)
        case .checkbox:
            widget.widgetFieldType = .button
            widget.widgetControlType = .checkBoxControl
        case .choice:
            widget.widgetFieldType = .choice
            widget.choices = options
            widget.backgroundColor = PlatformColor(white: 0.97, alpha: 1)
        }
        widget.fieldName = name
        widget.border = PDFBorder()
        widget.border?.lineWidth = 0.75
        page.addAnnotation(widget)
    }
}

extension PDFAnnotation {
    /// Whether this annotation is a form widget.
    var isWidgetAnnotation: Bool { type == "Widget" }
}
