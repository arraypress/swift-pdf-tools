//
//  PDFToolsTests.swift
//  PDFToolsTests
//
//  Created by David Sherlock on 2026.
//

import PDFKit
import XCTest
@testable import PDFTools

final class PDFToolsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws { dir = try Fixtures.scratch() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testMergeKeepsOrderAndCount() throws {
        let a = try PDFTools.open(try Fixtures.textPDF(pages: 2, in: dir, name: "a.pdf"))
        let b = try PDFTools.open(try Fixtures.textPDF(pages: 3, label: "Second", in: dir, name: "b.pdf"))
        let merged = PDFTools.merge([a, b])
        XCTAssertEqual(merged.pageCount, 5)
        XCTAssertTrue(merged.page(at: 2)!.string!.contains("Second 1"))
    }

    func testSplitEveryAndBefore() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 5, in: dir))
        XCTAssertEqual(try PDFTools.split(doc, every: 2).map(\.pageCount), [2, 2, 1])
        let parts = try PDFTools.split(doc, before: [3])
        XCTAssertEqual(parts.map(\.pageCount), [3, 2])
        XCTAssertTrue(parts[1].page(at: 0)!.string!.contains("page 4"))
        XCTAssertThrowsError(try PDFTools.split(doc, before: [0]))
    }

    func testExtractDeleteReorder() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 3, in: dir))
        let picked = try PDFTools.extract(doc, pages: [0, 2])
        XCTAssertEqual(picked.pageCount, 2)
        XCTAssertTrue(picked.page(at: 1)!.string!.contains("page 3"))
        let doomed = try PDFTools.open(try Fixtures.textPDF(pages: 3, in: dir, name: "d.pdf"))
        try PDFTools.delete(doomed, pages: [1])
        XCTAssertEqual(doomed.pageCount, 2)
        XCTAssertTrue(doomed.page(at: 1)!.string!.contains("page 3"))
        XCTAssertThrowsError(try PDFTools.delete(doomed, pages: [0, 1]))
        let shuffled = try PDFTools.reorder(doc, order: [2, 0, 1])
        XCTAssertTrue(shuffled.page(at: 0)!.string!.contains("page 3"))
        XCTAssertThrowsError(try PDFTools.reorder(doc, order: [0, 1]))
    }

    func testRotatePersistsAndRejectsNonQuarterTurns() throws {
        let url = try Fixtures.textPDF(pages: 2, in: dir)
        let doc = try PDFTools.open(url)
        try PDFTools.rotate(doc, by: 90)
        XCTAssertThrowsError(try PDFTools.rotate(doc, by: 45))
        let out = dir.appendingPathComponent("rotated.pdf")
        try PDFTools.write(doc, to: out)
        XCTAssertEqual(try PDFTools.open(out).page(at: 1)!.rotation, 90)
    }

    func testCropConvertsTopLeftToPDFSpace() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 1, in: dir))
        try PDFTools.crop(doc, toTopLeft: CGRect(x: 10, y: 10, width: 300, height: 400))
        let box = doc.page(at: 0)!.bounds(for: .cropBox)
        XCTAssertEqual(box.minX, 10, accuracy: 0.5)
        XCTAssertEqual(box.minY, 792 - 10 - 400, accuracy: 0.5)
        XCTAssertEqual(box.size, CGSize(width: 300, height: 400))
        XCTAssertThrowsError(try PDFTools.crop(doc, toTopLeft: CGRect(x: 5000, y: 0, width: 10, height: 10)))
    }

    func testWatermarkInksEveryPage() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 2, in: dir))
        let clean = try Fixtures.probe(doc, page: 1, atPDF: CGPoint(x: 306, y: 396))
        XCTAssertEqual(clean.r, 255)
        let marked = try PDFTools.watermark(doc, text: "DRAFT", opacity: 0.6, angle: 0)
        let inked = try Fixtures.probe(marked, page: 1, atPDF: CGPoint(x: 306, y: 396))
        XCTAssertLessThan(inked.r, 240, "the page centre should carry ink: \(inked)")
    }

    func testPageNumbersReadBackOut() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 3, in: dir))
        let numbered = try PDFTools.number(doc, format: "Page %d of %d", skipFirst: true)
        let text = try PDFTools.text(numbered)
        XCTAssertTrue(text.contains("Page 2 of 3"), text)
        XCTAssertFalse(text.contains("Page 1 of 3"), "skip-first must leave the cover clean")
        XCTAssertThrowsError(try PDFTools.number(doc, format: "no holes"))
    }

    func testProtectAndUnlockRoundTrip() throws {
        let url = try Fixtures.textPDF(pages: 1, in: dir)
        let secured = dir.appendingPathComponent("locked.pdf")
        try PDFTools.protect(try PDFTools.open(url), to: secured, userPassword: "secret")
        XCTAssertThrowsError(try PDFTools.open(secured)) { error in
            guard case PDFToolsError.locked = error as! PDFToolsError else { return XCTFail("\(error)") }
        }
        let unlocked = try PDFTools.open(secured, password: "secret")
        let free = dir.appendingPathComponent("free.pdf")
        // Writing the unlocked document as-is KEEPS the encryption; the
        // password-free copy comes from moving pages to a fresh document.
        try PDFTools.write(PDFTools.unlocked(unlocked), to: free)
        XCTAssertFalse(try PDFTools.open(free).isEncrypted)
        XCTAssertTrue(try PDFTools.open(free).page(at: 0)!.string!.contains("Hello"))
    }

    func testFindReturnsPageAndTopLeftRect() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 2, in: dir))
        let matches = PDFTools.find("authorized SIGNATURE", in: doc)
        XCTAssertEqual(matches.count, 1)
        let match = matches[0]
        XCTAssertEqual(match.page, 1)
        XCTAssertEqual(match.rect.minX, 72, accuracy: 4)
        XCTAssertEqual(match.rect.minY, 792 - 158, accuracy: 10, "top-left origin, label baseline at pdf 144")
        XCTAssertGreaterThan(match.rect.width, 80)
    }

    func testSignPlacesTheStampAboveTheLabel() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 2, in: dir))
        let signature = try PDFTools.image(at: try Fixtures.signaturePNG(in: dir))
        let (signed, report) = try PDFTools.sign(doc, signature: signature,
                                                 placement: .above("Authorized signature"), width: 120, dated: true)
        XCTAssertEqual(report.page, 1)
        // Stamp: 120×48 pt, bottom edge ~6 pt above the label's top (~158).
        let inked = try Fixtures.probe(signed, page: 0, atPDF: CGPoint(x: 132, y: 188))
        XCTAssertGreaterThan(inked.r, 150)
        XCTAssertLessThan(inked.g, 120)
        let clean = try Fixtures.probe(signed, page: 1, atPDF: CGPoint(x: 132, y: 188))
        XCTAssertEqual(clean.r, 255, "only the target page gets ink")
        XCTAssertEqual(report.rect.minX, 72, accuracy: 4)
        // Not-found and bad-page errors are named.
        XCTAssertThrowsError(try PDFTools.sign(doc, signature: signature, placement: .above("No such label")))
        // A stamp too tall to fit above a label near the top edge is pinned
        // onto the page, never drawn off it.
        let (_, pinned) = try PDFTools.sign(doc, signature: signature,
                                            placement: .above("Hello page"), width: 400)
        XCTAssertGreaterThanOrEqual(pinned.rect.minY, 0, "\(pinned.rect)")
        XCTAssertLessThanOrEqual(pinned.rect.maxY, 792.5)
        XCTAssertLessThanOrEqual(pinned.rect.maxX, 612.5)
    }

    func testSignAtFractionsAndIntoField() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 3, in: dir))
        let signature = try PDFTools.image(at: try Fixtures.signaturePNG(in: dir))
        let (_, atReport) = try PDFTools.sign(doc, signature: signature, placement: .at(0.5, 0.5), width: 100)
        XCTAssertEqual(atReport.page, 3, "default page for --at is the last")
        XCTAssertEqual(atReport.rect.midX, 306, accuracy: 2)
        XCTAssertEqual(atReport.rect.midY, 396, accuracy: 2)

        let form = try PDFTools.open(try Fixtures.formPDF(in: dir))
        let (_, fieldReport) = try PDFTools.sign(form, signature: signature, placement: .field("Name"), width: 400)
        XCTAssertEqual(fieldReport.page, 1)
        XCTAssertLessThanOrEqual(fieldReport.rect.width, 200.5, "the stamp fits inside the field")
        XCTAssertThrowsError(try PDFTools.sign(form, signature: signature, placement: .field("Ghost")))
    }

    func testRenderAndFromImages() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 1, in: dir))
        let image = try PDFTools.render(doc, page: 0, dpi: 144)
        XCTAssertEqual(image.width, 1224)
        let png = dir.appendingPathComponent("page.png")
        try PDFTools.writeImage(image, to: png)
        let sig = try Fixtures.signaturePNG(in: dir)
        let fitted = try PDFTools.fromImages([sig, png], pageSize: .fit)
        XCTAssertEqual(fitted.pageCount, 2)
        XCTAssertEqual(fitted.page(at: 0)!.bounds(for: .mediaBox).size, CGSize(width: 200, height: 80))
        let a4 = try PDFTools.fromImages([sig], pageSize: .a4)
        XCTAssertEqual(a4.page(at: 0)!.bounds(for: .mediaBox).width, 595.28, accuracy: 0.1)
    }

    func testCompressShrinksNoiseAndKeepsSmallerText() throws {
        let noise = try Fixtures.noisePDF(in: dir)
        let noiseBytes = try Data(contentsOf: noise).count
        let out = dir.appendingPathComponent("smaller.pdf")
        let report = try PDFTools.compress(try PDFTools.open(noise), originalBytes: noiseBytes, to: out,
                                           dpi: 100, quality: 0.5)
        XCTAssertTrue(report.keptCompressed)
        XCTAssertLessThan(report.compressed, noiseBytes / 2, "noise at q0.5 should at least halve")
        XCTAssertEqual(try Data(contentsOf: out).count, report.compressed)

        let text = try Fixtures.textPDF(pages: 1, in: dir)
        let textBytes = try Data(contentsOf: text).count
        let kept = dir.appendingPathComponent("kept.pdf")
        let textReport = try PDFTools.compress(try PDFTools.open(text), originalBytes: textBytes, to: kept)
        XCTAssertFalse(textReport.keptCompressed, "a tiny text PDF must not be replaced by a bigger raster")
        XCTAssertTrue(try PDFTools.open(kept).page(at: 0)!.string!.contains("Hello"))
    }

    func testFormListFillAndPersist() throws {
        let url = try Fixtures.formPDF(in: dir)
        let doc = try PDFTools.open(url)
        let fields = PDFTools.fields(doc)
        XCTAssertEqual(fields.map(\.name).sorted(), ["Agree", "Name"])
        XCTAssertEqual(fields.first { $0.name == "Agree" }?.kind, "checkbox")
        try PDFTools.fill(doc, values: ["Name": "David Sherlock", "Agree": "yes"])
        let out = dir.appendingPathComponent("filled.pdf")
        try PDFTools.write(doc, to: out)
        let reread = PDFTools.fields(try PDFTools.open(out))
        XCTAssertEqual(reread.first { $0.name == "Name" }?.value, "David Sherlock")
        XCTAssertEqual(reread.first { $0.name == "Agree" }?.value, "on")
        XCTAssertThrowsError(try PDFTools.fill(doc, values: ["Ghost": "x"]))
    }

    func testTextHonoursPageSelection() throws {
        let doc = try PDFTools.open(try Fixtures.textPDF(pages: 3, in: dir))
        let text = try PDFTools.text(doc, pages: [1])
        XCTAssertTrue(text.contains("page 2"))
        XCTAssertFalse(text.contains("page 1"))
        XCTAssertThrowsError(try PDFTools.text(doc, pages: [9]))
    }
}
