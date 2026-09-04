//
//  PagesTests.swift
//  PDFToolsTests
//
//  Created by David Sherlock on 2026.
//
//  Cutting a document to a size limit, where the limit is what a mail server
//  or an upload form will accept.
//

import Foundation
import PDFKit
import XCTest
@testable import PDFTools

// MARK: - Splitting by size

final class SplitBySizeTests: XCTestCase {

    private func document(pages: Int) throws -> (PDFDocument, URL) {
        let dir = try Fixtures.scratch()
        let url = try Fixtures.fatPDF(pages: pages, in: dir)
        return (PDFDocument(url: url)!, dir)
    }

    func testEveryPartIsUnderTheLimit() throws {
        let (document, dir) = try document(pages: 12)
        defer { try? FileManager.default.removeItem(at: dir) }
        let whole = document.dataRepresentation()!.count
        let limit = whole / 4

        let parts = try PDFTools.split(document, maxBytes: limit)
        XCTAssertGreaterThan(parts.count, 1)
        for part in parts {
            XCTAssertLessThanOrEqual(part.dataRepresentation()!.count, limit,
                                     "a part exceeded the limit it was cut to")
        }
    }

    func testNoPageIsLostOrDuplicated() throws {
        // The failure a size split invites: an off-by-one at a boundary that
        // silently drops the page it cut on.
        let (document, dir) = try document(pages: 12)
        defer { try? FileManager.default.removeItem(at: dir) }
        let parts = try PDFTools.split(document, maxBytes: document.dataRepresentation()!.count / 5)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.pageCount }, 12)
    }

    func testADocumentThatAlreadyFitsComesBackWhole() throws {
        let (document, dir) = try document(pages: 4)
        defer { try? FileManager.default.removeItem(at: dir) }
        let parts = try PDFTools.split(document, maxBytes: 50_000_000)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].pageCount, 4)
    }

    func testAPageTooBigForTheLimitIsReportedAndStillEmitted() throws {
        // The alternative is an empty part and a loop that never advances.
        // The caller has to be able to say the limit was not met, and why.
        let (document, dir) = try document(pages: 3)
        defer { try? FileManager.default.removeItem(at: dir) }
        var oversize: [Int] = []
        let parts = try PDFTools.split(document, maxBytes: 200) { oversize.append($0) }
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(oversize, [1, 2, 3])
        XCTAssertEqual(parts.reduce(0) { $0 + $1.pageCount }, 3)
    }

    func testAZeroLimitIsRefused() throws {
        let (document, dir) = try document(pages: 2)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try PDFTools.split(document, maxBytes: 0))
    }
}

final class ByteSizeTests: XCTestCase {

    func testUnitsArePowersOf1024() {
        // What a mail server's "25 MB" means. Using 1000 would be 5% out,
        // which is the difference between a file that sends and one that
        // bounces.
        XCTAssertEqual(ByteSize.parse("1kb"), 1024)
        XCTAssertEqual(ByteSize.parse("1MB"), 1_048_576)
        XCTAssertEqual(ByteSize.parse("1gb"), 1_073_741_824)
        XCTAssertEqual(ByteSize.parse("25 MB"), 26_214_400)
    }

    func testShortAndLongSpellings() {
        XCTAssertEqual(ByteSize.parse("500k"), ByteSize.parse("500KB"))
        XCTAssertEqual(ByteSize.parse("5m"), ByteSize.parse("5MiB"))
    }

    func testFractionsAndBareBytes() {
        XCTAssertEqual(ByteSize.parse("2.5mb"), 2_621_440)
        XCTAssertEqual(ByteSize.parse("1048576"), 1_048_576)
    }

    func testNonsenseIsRefused() {
        XCTAssertNil(ByteSize.parse("big"))
        XCTAssertNil(ByteSize.parse(""))
        XCTAssertNil(ByteSize.parse("-5mb"))
        XCTAssertNil(ByteSize.parse("0"))
    }
}
