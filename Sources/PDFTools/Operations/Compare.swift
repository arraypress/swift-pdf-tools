//
//  Compare.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  Two documents rendered and held up to the light. The comparison is
//  visual — pages rasterised at the same density and compared pixel by
//  pixel with a small tolerance, because re-rendering the same content
//  twice never lands on identical antialiasing and that is not a
//  difference a person cares about. Pages one document has and the
//  other lacks are wholly different by definition.
//

import CoreGraphics
import Foundation
import PDFKit

public extension PDFTools {

    /// How one page pair compares.
    struct PageDiff: Sendable, Equatable {
        /// The page, counting from 1.
        public let page: Int
        /// `same`, `changed`, `added` (only in the second document) or
        /// `removed` (only in the first).
        public let status: String
        /// Pixels that differ beyond tolerance, as a share of the page, 0…100.
        public let changedPercent: Double
        /// Contiguous changed areas, counted on a coarse grid — "three
        /// regions" reads better than a raw pixel count.
        public let regions: Int
    }

    /// Compares two documents page by page at `dpi`.
    ///
    /// - Parameters:
    ///   - tolerance: Per-channel difference (0…255) below which a pixel
    ///     counts as the same. The default absorbs antialiasing jitter.
    /// - Returns: One entry per page of the longer document, in order.
    static func compare(_ first: PDFDocument, _ second: PDFDocument,
                        dpi: Double = 144, tolerance: Int = 8) throws -> [PageDiff] {
        guard (36...600).contains(dpi) else { throw PDFToolsError.badValue("--dpi is 36…600") }
        var out: [PageDiff] = []
        let count = max(first.pageCount, second.pageCount)
        for index in 0..<count {
            if index >= first.pageCount {
                out.append(PageDiff(page: index + 1, status: "added", changedPercent: 100, regions: 1))
                continue
            }
            if index >= second.pageCount {
                out.append(PageDiff(page: index + 1, status: "removed", changedPercent: 100, regions: 1))
                continue
            }
            let a = try render(first, page: index, dpi: dpi)
            let b = try render(second, page: index, dpi: dpi)
            out.append(diff(a, b, page: index + 1, tolerance: tolerance))
        }
        return out
    }

    /// The changed pixels of one page pair, tinted red over a desaturated
    /// render of the second document — the picture a reviewer flips through.
    static func diffImage(_ first: PDFDocument, _ second: PDFDocument,
                          page index: Int, dpi: Double = 144, tolerance: Int = 8) throws -> CGImage {
        let a = try render(first, page: index, dpi: dpi)
        let b = try render(second, page: index, dpi: dpi)
        let (bytesA, _, _) = try rgba(a)
        let (bytesB, width, height) = try rgba(b)
        var out = [UInt8](repeating: 255, count: width * height * 4)
        let sameSize = a.width == b.width && a.height == b.height
        for pixel in 0..<(width * height) {
            let i = pixel * 4
            let gray = UInt8((Int(bytesB[i]) + Int(bytesB[i + 1]) + Int(bytesB[i + 2])) / 3)
            let changed = !sameSize || Self.differs(bytesA, bytesB, at: i, tolerance: tolerance)
            if changed {
                out[i] = 220
                out[i + 1] = UInt8(Int(gray) / 4)
                out[i + 2] = UInt8(Int(gray) / 4)
            } else {
                // Desaturated and lifted, so the red reads at a glance.
                let soft = UInt8(155 + Int(gray) * 100 / 255)
                out[i] = soft; out[i + 1] = soft; out[i + 2] = soft
            }
            out[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw PDFToolsError.writeFailed("The diff image for page \(index + 1) would not build")
        }
        return image
    }

    // MARK: Internals

    private static func diff(_ a: CGImage, _ b: CGImage, page: Int, tolerance: Int) -> PageDiff {
        guard a.width == b.width, a.height == b.height,
              let (bytesA, width, height) = try? rgba(a),
              let (bytesB, _, _) = try? rgba(b) else {
            // Different paper sizes cannot be overlaid; the page is simply different.
            return PageDiff(page: page, status: "changed", changedPercent: 100, regions: 1)
        }
        let cells = 32
        var cellHit = [Bool](repeating: false, count: cells * cells)
        var changed = 0
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width {
                let i = row + x * 4
                if Self.differs(bytesA, bytesB, at: i, tolerance: tolerance) {
                    changed += 1
                    cellHit[(y * cells / height) * cells + (x * cells / width)] = true
                }
            }
        }
        let percent = Double(changed) / Double(width * height) * 100
        return PageDiff(page: page,
                        status: changed == 0 ? "same" : "changed",
                        changedPercent: (percent * 100).rounded() / 100,
                        regions: regions(in: cellHit, side: cells))
    }

    private static func differs(_ a: [UInt8], _ b: [UInt8], at i: Int, tolerance: Int) -> Bool {
        abs(Int(a[i]) - Int(b[i])) > tolerance
            || abs(Int(a[i + 1]) - Int(b[i + 1])) > tolerance
            || abs(Int(a[i + 2]) - Int(b[i + 2])) > tolerance
    }

    /// Connected changed cells (4-neighbour) counted as one region each.
    private static func regions(in hit: [Bool], side: Int) -> Int {
        var seen = hit.map { !$0 }   // unchanged cells are pre-visited
        var count = 0
        for start in seen.indices where !seen[start] {
            count += 1
            var stack = [start]
            seen[start] = true
            while let cell = stack.popLast() {
                let x = cell % side, y = cell / side
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && nx < side && ny >= 0 && ny < side {
                    let next = ny * side + nx
                    if !seen[next] { seen[next] = true; stack.append(next) }
                }
            }
        }
        return count
    }

    private static func rgba(_ image: CGImage) throws -> ([UInt8], Int, Int) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PDFToolsError.writeFailed("Could not read a page's pixels")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }
}
