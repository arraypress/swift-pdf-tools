//
//  Fixtures.swift
//  PDFToolsTests
//
//  Created by David Sherlock on 2026.
//
//  Synthetic documents with exactly the content the assertions probe:
//  labelled pages, a signature label at a known spot, a noise image that
//  only JPEG can shrink, and a live form.
//

import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import PDFTools

enum Fixtures {

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdftools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Letter pages, "<label> N" near the top; page 1 also carries
    /// "Authorized signature" with its baseline at (72, 144) in PDF space.
    static func textPDF(pages: Int, label: String = "Hello page", in dir: URL, name: String = "text.pdf") throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for page in 1...pages {
            context.beginPDFPage(nil)
            let line = PDFTools.line("\(label) \(page)", font: font, color: CGColor(gray: 0, alpha: 1))
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            if page == 1 {
                let sig = PDFTools.line("Authorized signature", font: font, color: CGColor(gray: 0, alpha: 1))
                context.textPosition = CGPoint(x: 72, y: 144)
                CTLineDraw(sig, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// One page filled edge to edge with random noise, stored losslessly —
    /// the document JPEG re-rendering exists to shrink.
    static func noisePDF(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("noise.pdf")
        let width = 800, height = 1000
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var state: UInt64 = 0x9E3779B97F4A7C15
        for index in bytes.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let noise = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.draw(noise, in: box)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// A solid red 200×80 "signature" PNG.
    static func signaturePNG(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("sig.png")
        let ctx = CGContext(data: nil, width: 200, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.05, blue: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 80))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return url
    }

    /// A one-page form: a text field "Name" and a checkbox "Agree".
    static func formPDF(in dir: URL) throws -> URL {
        let base = try textPDF(pages: 1, in: dir, name: "form-base.pdf")
        let document = PDFDocument(url: base)!
        let page = document.page(at: 0)!
        let name = PDFAnnotation(bounds: CGRect(x: 300, y: 600, width: 200, height: 24),
                                 forType: .widget, withProperties: nil)
        name.widgetFieldType = .text
        name.fieldName = "Name"
        page.addAnnotation(name)
        let agree = PDFAnnotation(bounds: CGRect(x: 300, y: 560, width: 18, height: 18),
                                  forType: .widget, withProperties: nil)
        agree.widgetFieldType = .button
        agree.widgetControlType = .checkBoxControl
        agree.fieldName = "Agree"
        page.addAnnotation(agree)
        let url = dir.appendingPathComponent("form.pdf")
        _ = document.write(to: url)
        return url
    }

    /// A pixel of a rendered page, bottom-left page coordinates in points.
    static func probe(_ document: PDFDocument, page: Int, atPDF point: CGPoint, dpi: Double = 144) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let image = try PDFTools.render(document, page: page, dpi: dpi)
        let width = image.width, height = image.height
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let scale = dpi / 72
        let x = min(width - 1, max(0, Int(point.x * scale)))
        let row = min(height - 1, max(0, height - 1 - Int(point.y * scale)))
        let i = (row * width + x) * 4
        return (data[i], data[i + 1], data[i + 2])
    }
}
