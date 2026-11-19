//
//  InkSurvivalTests.swift
//  PDFToolsTests
//
//  Created by David Sherlock on 2026.
//
//  Nothing drawn or carried by the overlay engine is lost without a word.
//  A page number centred on a point 28 pt from the edge lost its first
//  letters; a long watermark came back as "T FOR DISTRIBUTION OU"; a dated
//  signature at the foot of a page had its date drawn under the page; and
//  every note, link and form field on a page was flattened away. Each is
//  asserted by reading the output back — its text, where that text sits,
//  and its annotations — never by trusting the arithmetic.
//

import PDFKit
import XCTest
@testable import PDFTools

final class InkSurvivalTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws { dir = try Fixtures.scratch() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// PDF text extraction inserts its own spacing and line breaks.
    private func squeezed(_ text: String) -> String { text.replacing(/\s+/, with: "") }

    private func pageText(_ document: PDFDocument, _ index: Int = 0) -> String {
        squeezed(document.page(at: index)?.string ?? "")
    }

    /// Every rectangle `query` occupies, in PDF space.
    private func boxes(_ query: String, in document: PDFDocument) -> [CGRect] {
        document.findString(query, withOptions: []).flatMap { selection in
            selection.selectionsByLine().compactMap { line in line.pages.first.map { line.bounds(for: $0) } }
        }
    }

    private func assertOnPage(_ query: String, in document: PDFDocument,
                              file: StaticString = #filePath, line: UInt = #line) {
        let found = boxes(query, in: document)
        XCTAssertFalse(found.isEmpty, "\"\(query)\" is not on the page", file: file, line: line)
        let page = document.page(at: 0)!.bounds(for: .mediaBox).insetBy(dx: -0.5, dy: -0.5)
        for box in found {
            XCTAssertTrue(page.contains(box), "\"\(query)\" at \(box) runs off \(page)", file: file, line: line)
        }
    }

    // MARK: Page numbers

    func testPageNumbersInEveryCornerStayWhole() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 1, in: dir))
        for anchor in [PDFTools.Anchor.bottomLeft, .bottomRight, .topLeft, .topRight, .bottomCentre, .topCentre] {
            var warnings: [String] = []
            let numbered = try PDFTools.number(doc, format: "Page %d of %d", anchor: anchor, start: 100,
                                               onWarning: { warnings.append($0) })
            XCTAssertTrue(pageText(numbered).contains("Page100of100"), "\(anchor): \(pageText(numbered))")
            assertOnPage("Page 100 of 100", in: numbered)
            XCTAssertEqual(warnings, [], "\(anchor)")
        }
    }

    func testAPageNumberTooWideShrinksThenWraps() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 1, in: dir))
        let format = "Page %d of %d — " + String(repeating: "Confidential settlement draft ", count: 5)
        var warnings: [String] = []
        let numbered = try PDFTools.number(doc, format: format, anchor: .bottomRight,
                                           onWarning: { warnings.append($0) })
        XCTAssertTrue(pageText(numbered).contains(squeezed(String(format: format, 1, 1))), pageText(numbered))
        XCTAssertEqual(warnings, [])
        assertOnPage("Page 1 of 1", in: numbered)
    }

    func testAPageNumberThatCannotFitIsDrawnWholeAndReported() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 2, in: dir))
        let format = "%d " + String(repeating: "overlong ", count: 400)
        var warnings: [String] = []
        let numbered = try PDFTools.number(doc, format: format, onWarning: { warnings.append($0) })
        // At six points, wrapped to the width of the page, it is all on the
        // page: it overruns upwards over the content, not off the sides.
        XCTAssertTrue(pageText(numbered, 1).contains(squeezed(String(format: format, 2))), pageText(numbered, 1))
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("pages 1, 2"), warnings[0])
    }

    // MARK: Watermarks

    func testALongWatermarkShrinksToStayWhole() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 1, in: dir))
        let text = "CONFIDENTIAL — NOT FOR DISTRIBUTION OUTSIDE THE COMPANY"
        for anchor in [PDFTools.Anchor.centre, .topLeft, .bottomRight] {
            var warnings: [String] = []
            let marked = try PDFTools.watermark(doc, text: text, angle: 0, anchor: anchor,
                                                onWarning: { warnings.append($0) })
            XCTAssertTrue(pageText(marked).contains(squeezed(text)), "\(anchor): \(pageText(marked))")
            assertOnPage("CONFIDENTIAL", in: marked)
            assertOnPage("COMPANY", in: marked)
            XCTAssertEqual(warnings, [])
        }
    }

    /// Turned to 45°, the block has to fit the page's diagonal room.
    func testASlantedWatermarkStaysOnThePage() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 1, in: dir))
        let text = "CONFIDENTIAL — NOT FOR DISTRIBUTION OUTSIDE THE COMPANY"
        let marked = try PDFTools.watermark(doc, text: text, opacity: 1, angle: 45)
        // The ends of a centred 45° line sit on the diagonal; at the old
        // fixed size they were well past the corners.
        let set = PDFTools.fit(text, font: "Helvetica-Bold", preferred: 71.28, minimum: 8, angle: 45,
                               within: CGSize(width: 564, height: 744), color: CGColor(gray: 0, alpha: 1))
        XCTAssertTrue(set.fits)
        XCTAssertLessThanOrEqual(set.rotatedSize(45).width, 564.5)
        XCTAssertLessThan(set.size, 71.28, "it had to shrink")
        XCTAssertFalse(pageText(marked).isEmpty)
    }

    func testAWatermarkTooLongForOneLineWraps() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 1, in: dir))
        let text = String(repeating: "Draft for review only ", count: 12)
        var warnings: [String] = []
        let marked = try PDFTools.watermark(doc, text: text, angle: 0, onWarning: { warnings.append($0) })
        XCTAssertTrue(pageText(marked).contains(squeezed(text)), pageText(marked))
        XCTAssertEqual(warnings, [])
        assertOnPage("Draft", in: marked)
    }

    func testAWatermarkThatCannotFitIsDrawnWholeAndReported() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 1, in: dir))
        let text = String(repeating: "overlong ", count: 900)
        var warnings: [String] = []
        let marked = try PDFTools.watermark(doc, text: text, angle: 0, onWarning: { warnings.append($0) })
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("page 1"), warnings[0])
        // Wrapped to the page's width, it overruns top and bottom, never
        // the sides: every line that is on the page is whole.
        let lines = (marked.page(at: 0)!.string ?? "").components(separatedBy: .newlines)
            .filter { $0.contains("overlong") }
        XCTAssertGreaterThan(lines.count, 20)
        for line in lines.dropFirst().dropLast() {
            XCTAssertTrue(line.trimmingCharacters(in: .whitespaces).hasPrefix("overlong"), line)
        }
    }

    func testANonLatinWatermarkReachesThePage() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 1, in: dir))
        let marked = try PDFTools.watermark(doc, text: "Черновик 草稿 مسودة", angle: 0)
        for word in ["Черновик", "草稿", "مسودة"] {
            XCTAssertTrue(pageText(marked).contains(word), "lost \(word): \(pageText(marked))")
        }
    }

    /// A tiled watermark repeats past the edges by design, but at least one
    /// copy has to be whole.
    func testATiledWatermarkHasAWholeCopy() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 1, in: dir))
        let text = "CONFIDENTIAL — NOT FOR DISTRIBUTION OUTSIDE THE COMPANY"
        let marked = try PDFTools.watermark(doc, text: text, angle: 0, anchor: .tile)
        let page = marked.page(at: 0)!.bounds(for: .mediaBox)
        let whole = boxes(text, in: marked).filter { page.contains($0) }
        XCTAssertFalse(whole.isEmpty, "no whole copy of the tiled watermark")
    }

    // MARK: Signatures

    private func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    func testADatedSignatureAtTheFootKeepsItsDate() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 1, in: dir))
        let signature = try PDFTools.image(at: try Fixtures.signaturePNG(in: dir))
        let (signed, report) = try PDFTools.sign(doc, signature: signature, placement: .at(0.5, 1), dated: true)
        XCTAssertTrue(pageText(signed).contains(today()), pageText(signed))
        assertOnPage(today(), in: signed)
        XCTAssertLessThanOrEqual(report.rect.maxY, 792 - 11, "room is kept under the stamp for the date")
    }

    func testANarrowStampAtTheRightEdgeKeepsItsDate() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 1, in: dir))
        let signature = try PDFTools.image(at: try Fixtures.signaturePNG(in: dir))
        let (signed, _) = try PDFTools.sign(doc, signature: signature, placement: .at(1, 0.5),
                                            width: 20, dated: true)
        assertOnPage(today(), in: signed)
    }

    /// An undated stamp still goes right to the foot, as it always did.
    func testAnUndatedStampStillReachesTheFoot() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 1, in: dir))
        let signature = try PDFTools.image(at: try Fixtures.signaturePNG(in: dir))
        let (_, report) = try PDFTools.sign(doc, signature: signature, placement: .at(0.5, 1))
        XCTAssertEqual(report.rect.maxY, 792, accuracy: 0.5)
    }

    // MARK: Annotations

    private func annotated() throws -> PDFDocument {
        let doc = try PDFTools.open(try Fixtures.formPDF(in: dir))
        try PDFTools.fill(doc, values: ["Name": "Ada Lovelace", "Agree": "yes"])
        _ = try PDFTools.note(doc, text: "Please check clause 4", placement: .at(0, 100, 100))
        _ = try PDFTools.link(doc, query: "Hello page", url: URL(string: "https://example.com/terms")!)
        return doc
    }

    private func assertAnnotationsSurvive(_ out: PDFDocument, file: StaticString = #filePath, line: UInt = #line) throws {
        // Through a save, as a reader would meet it.
        let saved = dir.appendingPathComponent("out-\(UUID().uuidString).pdf")
        try PDFTools.write(out, to: saved)
        let reopened = try PDFTools.open(saved)
        let annotations = reopened.page(at: 0)!.annotations
        XCTAssertTrue(annotations.contains { $0.type == "Text" && $0.contents == "Please check clause 4" },
                      "the note's words were lost", file: file, line: line)
        XCTAssertTrue(annotations.contains { ($0.action as? PDFActionURL)?.url?.absoluteString == "https://example.com/terms" },
                      "the link was lost", file: file, line: line)
        let fields = PDFTools.fields(reopened)
        XCTAssertTrue(fields.contains { $0.name == "Name" && $0.value == "Ada Lovelace" }, "\(fields)", file: file, line: line)
        XCTAssertTrue(fields.contains { $0.name == "Agree" && $0.value == "on" }, "\(fields)", file: file, line: line)
        // Still fillable, not a picture of a form.
        try PDFTools.fill(reopened, values: ["Name": "Grace Hopper"])
        XCTAssertTrue(PDFTools.fields(reopened).contains { $0.value == "Grace Hopper" }, file: file, line: line)
    }

    func testWatermarkKeepsNotesLinksAndFields() throws {
        try assertAnnotationsSurvive(try PDFTools.watermark(try annotated(), text: "DRAFT"))
    }

    func testNumberingKeepsNotesLinksAndFields() throws {
        try assertAnnotationsSurvive(try PDFTools.number(try annotated()))
    }

    func testSigningKeepsNotesLinksAndFields() throws {
        let signature = try PDFTools.image(at: try Fixtures.signaturePNG(in: dir))
        try assertAnnotationsSurvive(try PDFTools.sign(try annotated(), signature: signature, placement: .at(0.5, 0.5)).0)
    }

    /// Carried live, not ALSO burned in: a field drawn into the content and
    /// carried on top shows its old value underneath the moment it is
    /// edited.
    func testCarriedAnnotationsAreNotAlsoBurnedIn() throws {
        let out = try PDFTools.watermark(try annotated(), text: "DRAFT")
        let page = out.page(at: 0)!
        for annotation in page.annotations { page.removeAnnotation(annotation) }
        XCTAssertFalse(pageText(out).contains("AdaLovelace"), pageText(out))
    }

    /// Carried annotations land where their content went, not where they
    /// were in the old page's coordinates — a link left behind covers
    /// nothing.
    func testACarriedLinkStillCoversItsText() throws {
        let doc = try annotated()
        let before = boxes("Hello page", in: doc)[0]
        let out = try PDFTools.watermark(doc, text: "DRAFT")
        let link = try XCTUnwrap(out.page(at: 0)!.annotations.first { $0.action is PDFActionURL })
        let after = boxes("Hello page", in: out)[0]
        XCTAssertEqual(link.bounds.midX, after.midX, accuracy: 2)
        XCTAssertEqual(link.bounds.midY, after.midY, accuracy: 2)
        XCTAssertEqual(before.midY, after.midY, accuracy: 2)
    }

    /// The same on a page turned a quarter: the transform that moved the
    /// content moves the annotation.
    func testACarriedNoteFollowsARotatedPage() throws {
        let doc = try annotated()
        try PDFTools.rotate(doc, by: 90)
        let out = try PDFTools.number(doc)
        let link = try XCTUnwrap(out.page(at: 0)!.annotations.first { $0.action is PDFActionURL })
        let text = try XCTUnwrap(boxes("Hello page 1", in: out).first)
        XCTAssertTrue(link.bounds.insetBy(dx: -4, dy: -4).intersects(text), "\(link.bounds) vs \(text)")
    }

    // MARK: The arithmetic

    func testWrappingKeepsEveryCharacterInOrder() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) }
        let text = "a supercalifragilisticexpialidocious word https://example.com/a/very/long/path"
        let lines = Fitting.wrap([text], limit: 10, measure: measure)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 10 }, "\(lines)")
        XCTAssertEqual(lines.joined().replacing(" ", with: ""), text.replacing(" ", with: ""))
    }

    func testBalancedWrapEvensTheLines() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) }
        let lines = Fitting.balanced(["aaaa bbbb cccc dddd"], into: 2, measure: measure)
        XCTAssertEqual(lines, ["aaaa bbbb", "cccc dddd"])
    }

    func testARotatedBlockCoversItsDiagonal() {
        let turned = Fitting.rotated(CGSize(width: 100, height: 10), 90)
        XCTAssertEqual(turned.width, 10, accuracy: 0.001)
        XCTAssertEqual(turned.height, 100, accuracy: 0.001)
        let slanted = Fitting.rotated(CGSize(width: 100, height: 0), 45)
        XCTAssertEqual(slanted.width, 100 / 2.squareRoot(), accuracy: 0.001)
        XCTAssertEqual(Fitting.largestSize(for: CGSize(width: 200, height: 120), at: 100, angle: 0,
                                           within: CGSize(width: 100, height: 600)), 50, accuracy: 0.001)
    }
}
