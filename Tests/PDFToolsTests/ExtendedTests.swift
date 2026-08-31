//
//  ExtendedTests.swift
//  PDFToolsTests
//
//  Created by David Sherlock on 2026.
//
//  The second wave: HTML rendering, comparison, salvage, live
//  annotations, metadata, outlines, field authoring and permissions.
//  Repair's expectations were set empirically first: damage that spares
//  the cross-reference table loses exactly the pages it hit; damage
//  that reaches the xref loses everything, and the library must say so.
//

import PDFKit
import XCTest
@testable import PDFTools

final class ExtendedTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws { dir = try Fixtures.scratch() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: HTML

    @MainActor
    func testHTMLPaginatesOntoPaperAndSinglePageStaysWhole() async throws {
        let html = dir.appendingPathComponent("long.html")
        let body = (1...220).map { "<p>HTMLPROBE paragraph \($0) with enough words to occupy a line.</p>" }.joined()
        try "<html><body><h1>HTMLPROBE title</h1>\(body)</body></html>".write(to: html, atomically: true, encoding: .utf8)

        let paged = try await PDFTools.renderHTML(html, options: .init(paper: .a4, margin: 36, settle: 0.3))
        let pagedDoc = try XCTUnwrap(PDFDocument(data: paged))
        XCTAssertGreaterThan(pagedDoc.pageCount, 1, "220 paragraphs must not fit one A4 page")
        XCTAssertTrue(try PDFTools.text(pagedDoc).contains("HTMLPROBE"), "the text layer survives printing")

        let single = try await PDFTools.renderHTML(html, options: .init(paper: nil, settle: 0.3))
        let singleDoc = try XCTUnwrap(PDFDocument(data: single))
        XCTAssertEqual(singleDoc.pageCount, 1, "the long-page shape is one endless page")
        XCTAssertTrue(try PDFTools.text(singleDoc).contains("HTMLPROBE paragraph 219"))
    }

    // MARK: Compare

    func testCompareSeesNoDifferenceInIdenticalDocuments() throws {
        let a = try PDFTools.open(try Fixtures.textPDF(pages: 3, in: dir, name: "a.pdf"))
        let b = try PDFTools.open(try Fixtures.textPDF(pages: 3, in: dir, name: "b.pdf"))
        let diffs = try PDFTools.compare(a, b, dpi: 72)
        XCTAssertEqual(diffs.count, 3)
        XCTAssertTrue(diffs.allSatisfy { $0.status == "same" && $0.changedPercent == 0 }, "\(diffs)")
    }

    func testCompareFlagsExactlyTheChangedPageAndCountsExtras() throws {
        let a = try PDFTools.open(try Fixtures.textPDF(pages: 4, in: dir, name: "a.pdf"))
        // Same fixture, but a different label from page 2 on: page 2+ text differs.
        let b = try PDFTools.open(try Fixtures.textPDF(pages: 5, label: "Hello page", in: dir, name: "b.pdf"))
        // Rewrite page 2 of b with different words by overlaying opaque ink there.
        let changed = try PDFTools.overlay(b) { index, ctx, box in
            guard index == 1 else { return }
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: 60, y: 600, width: 300, height: 60))
        }
        let diffs = try PDFTools.compare(a, changed, dpi: 72)
        XCTAssertEqual(diffs.count, 5)
        XCTAssertEqual(diffs[0].status, "same")
        XCTAssertEqual(diffs[1].status, "changed")
        XCTAssertGreaterThan(diffs[1].changedPercent, 0.5)
        XCTAssertGreaterThanOrEqual(diffs[1].regions, 1)
        XCTAssertEqual(diffs[2].status, "same")
        XCTAssertEqual(diffs[4].status, "added", "the fifth page exists only in the second document")
        // The visual diff builds and matches the render's size.
        let picture = try PDFTools.diffImage(a, changed, page: 1, dpi: 72)
        XCTAssertGreaterThan(picture.width, 100)
    }

    // MARK: Repair

    func testRepairPassesAnIntactFileThrough() throws {
        let url = try Fixtures.textPDF(pages: 4, in: dir)
        let out = dir.appendingPathComponent("repaired.pdf")
        let report = try PDFTools.repair(url, to: out)
        XCTAssertTrue(report.wasIntact)
        XCTAssertEqual(report.recovered, 4)
        XCTAssertEqual(report.lostPages, [])
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 4)
    }

    func testRepairSalvagesAroundMidFileDamageAndNamesTheLoss() throws {
        let url = try Fixtures.fatPDF(pages: 20, in: dir)
        var data = try Data(contentsOf: url)
        let at = Int(Double(data.count) * 0.3)
        for index in at..<(at + 2048) { data[index] = 0x41 }
        let damaged = dir.appendingPathComponent("damaged.pdf")
        try data.write(to: damaged)

        let out = dir.appendingPathComponent("salvaged.pdf")
        let report = try PDFTools.repair(damaged, to: out)
        XCTAssertFalse(report.wasIntact)
        XCTAssertEqual(report.claimed, 20)
        XCTAssertEqual(report.recovered + report.lostPages.count, 20)
        XCTAssertFalse(report.lostPages.isEmpty, "mid-file damage costs the page it hit")
        XCTAssertLessThan(report.lostPages.count, 4, "and only around there: \(report.lostPages)")
        let salvaged = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(salvaged.pageCount, report.recovered)
    }

    func testRepairIsHonestWhenTheStructureIsGone() throws {
        let url = try Fixtures.textPDF(pages: 3, in: dir)
        let data = try Data(contentsOf: url)
        let truncated = dir.appendingPathComponent("truncated.pdf")
        try data.prefix(Int(Double(data.count) * 0.6)).write(to: truncated)
        XCTAssertThrowsError(try PDFTools.repair(truncated, to: dir.appendingPathComponent("no.pdf"))) { error in
            guard case PDFToolsError.unreadable(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("cannot recover"), message)
        }
        let garbage = dir.appendingPathComponent("garbage.pdf")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: garbage)
        XCTAssertThrowsError(try PDFTools.repair(garbage, to: dir.appendingPathComponent("no2.pdf")))
    }

    // MARK: Annotations

    func testMarkupLandsOnTheMatchAndSurvivesSaving() throws {
        let url = try Fixtures.textPDF(pages: 3, in: dir)
        let document = try PDFTools.open(url)
        let marks = try PDFTools.markup(document, query: "Hello page 2", style: .highlight)
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks[0].page, 2)
        XCTAssertEqual(Int(marks[0].rect.minX), 72, "the label draws at x 72")

        let out = dir.appendingPathComponent("marked.pdf")
        try PDFTools.write(document, to: out)
        let reopened = try XCTUnwrap(PDFDocument(url: out))
        let annotations = reopened.page(at: 1)!.annotations.filter { $0.type == "Highlight" }
        XCTAssertEqual(annotations.count, 1, "the highlight is live, not ink")
        XCTAssertThrowsError(try PDFTools.markup(document, query: "no such words"))
    }

    func testNoteAnchorsBesideTheLabelAndLinkWrapsEveryMatch() throws {
        let url = try Fixtures.textPDF(pages: 2, in: dir)
        let document = try PDFTools.open(url)
        let note = try PDFTools.note(document, text: "check this", placement: .above("Authorized signature"))
        XCTAssertEqual(note.page, 1)

        let links = try PDFTools.link(document, query: "Hello page", url: URL(string: "https://example.com/x")!)
        XCTAssertEqual(links.count, 2, "one per page")
        let out = dir.appendingPathComponent("annotated.pdf")
        try PDFTools.write(document, to: out)
        let reopened = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertTrue(reopened.page(at: 0)!.annotations.contains { $0.type == "Text" })
        let linkAnnotation = reopened.page(at: 1)!.annotations.first { $0.type == "Link" }
        XCTAssertEqual((linkAnnotation?.action as? PDFActionURL)?.url?.absoluteString, "https://example.com/x")
    }

    // MARK: Metadata

    func testMetadataRoundTripsThroughSave() throws {
        let url = try Fixtures.textPDF(pages: 1, in: dir)
        let document = try PDFTools.open(url)
        try PDFTools.setMetadata(document, values: [
            "title": "The Probe", "author": "D. Sherlock", "keywords": "alpha, beta",
        ])
        let out = dir.appendingPathComponent("meta.pdf")
        try PDFTools.write(document, to: out)
        let meta = PDFTools.metadata(try PDFTools.open(out))
        XCTAssertEqual(meta.title, "The Probe")
        XCTAssertEqual(meta.author, "D. Sherlock")
        XCTAssertEqual(meta.keywords, "alpha, beta")
        XCTAssertThrowsError(try PDFTools.setMetadata(document, values: ["producer": "x"]),
                             "producer is written by the writer, not set by hand")
    }

    // MARK: Outline

    func testOutlineBuildsFlatAndNestedAndReadsBack() throws {
        let url = try Fixtures.textPDF(pages: 6, in: dir)
        let document = try PDFTools.open(url)
        let withTOC = try PDFTools.addOutline(document, entries: [
            (title: "Introduction", page: 0),
            (title: "Chapters>One", page: 1),
            (title: "Chapters>Two", page: 3),
            (title: "Appendix", page: 5),
        ])
        let out = dir.appendingPathComponent("toc.pdf")
        try PDFTools.write(withTOC, to: out)
        let entries = PDFTools.outline(try PDFTools.open(out))
        XCTAssertEqual(entries.map(\.title), ["Introduction", "Chapters", "One", "Two", "Appendix"])
        XCTAssertEqual(entries.map(\.depth), [0, 0, 1, 1, 0])
        XCTAssertEqual(entries.first { $0.title == "Two" }?.page, 4)
        XCTAssertThrowsError(try PDFTools.addOutline(document, entries: [(title: "Off the end", page: 9)]) as PDFDocument)
    }

    // MARK: Field authoring and permissions

    func testAuthoredFieldsAreFillableByTheExistingFill() throws {
        let url = try Fixtures.textPDF(pages: 2, in: dir)
        let document = try PDFTools.open(url)
        try PDFTools.addField(document, kind: .text, name: "Name", page: 0,
                              rect: CGRect(x: 72, y: 200, width: 200, height: 24))
        try PDFTools.addField(document, kind: .checkbox, name: "Agree", page: 0,
                              rect: CGRect(x: 72, y: 240, width: 18, height: 18))
        try PDFTools.addField(document, kind: .choice, name: "Size", page: 1,
                              rect: CGRect(x: 72, y: 100, width: 120, height: 24), options: ["S", "M", "L"])
        let out = dir.appendingPathComponent("form.pdf")
        try PDFTools.write(document, to: out)

        let reopened = try PDFTools.open(out)
        let before = PDFTools.fields(reopened)
        XCTAssertEqual(Set(before.map(\.name)), ["Name", "Agree", "Size"])
        try PDFTools.fill(reopened, values: ["Name": "David", "Agree": "true", "Size": "M"])
        let filledOut = dir.appendingPathComponent("filled.pdf")
        try PDFTools.write(reopened, to: filledOut)
        let filled = PDFTools.fields(try PDFTools.open(filledOut))
        XCTAssertEqual(filled.first { $0.name == "Name" }?.value, "David")
        XCTAssertEqual(filled.first { $0.name == "Agree" }?.value, "on")
        XCTAssertEqual(filled.first { $0.name == "Size" }?.value, "M")
        XCTAssertThrowsError(try PDFTools.addField(document, kind: .choice, name: "Empty", page: 0,
                                                   rect: CGRect(x: 0, y: 0, width: 10, height: 10)))
    }

    func testProtectPermissionFlagsRoundTrip() throws {
        let url = try Fixtures.textPDF(pages: 1, in: dir)
        let document = try PDFTools.open(url)
        let out = dir.appendingPathComponent("locked.pdf")
        try PDFTools.protect(document, to: out, userPassword: "pw", ownerPassword: "owner-pw", allowsPrinting: true, allowsCopying: false)
        let reopened = try PDFTools.open(out, password: "pw")
        XCTAssertTrue(reopened.allowsPrinting)
        XCTAssertFalse(reopened.allowsCopying, "no-copy must survive the save")
    }
}
