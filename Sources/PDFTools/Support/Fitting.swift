//
//  Fitting.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  Setting a line of ink — a watermark, a page number — into the room a
//  page has for it, without ever cutting it. Shrink first, down to a
//  smallest readable size; then wrap onto more lines; and when even that
//  cannot fit, set it whole at the smallest size and say it does not fit.
//  A stamp that silently loses "CONFIDENTIAL — NOT FOR DIS" off both edges
//  reads as a different instruction.
//
//  Measured once at a reference size and scaled: a face's advance widths
//  scale linearly with the point size, so the search costs one measurement
//  per distinct string, not one per size tried.
//

import CoreText
import Foundation

extension PDFTools {

    /// How lines of a set block line up against each other.
    enum Alignment: Sendable { case left, centre, right }

    /// Text set at one size, on one or more lines.
    struct SetText {
        let lines: [CTLine]
        let widths: [CGFloat]
        let size: CGFloat
        /// Whether it fits the room it was set for.
        let fits: Bool

        var leading: CGFloat { size * 1.2 }
        var width: CGFloat { widths.max() ?? 0 }
        var height: CGFloat { leading * CGFloat(lines.count) }

        /// The upright box the block covers once turned by `degrees`.
        func rotatedSize(_ degrees: Double) -> CGSize {
            Fitting.rotated(CGSize(width: width, height: height), degrees)
        }

        /// Draws the block. By default it is centred on the origin; with
        /// `fromBaseline` the origin is the first line's baseline and the
        /// rest follow beneath it. `align` places each line against x = 0.
        func draw(in ctx: CGContext, align: Alignment, fromBaseline: Bool = false) {
            for (index, line) in lines.enumerated() {
                let width = widths[index]
                let x: CGFloat = align == .left ? 0 : align == .right ? -width : -width / 2
                let y: CGFloat = fromBaseline
                    ? -CGFloat(index) * leading
                    : height / 2 - (CGFloat(index) + 0.5) * leading - size * 0.35
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, ctx)
            }
        }
    }

    /// Sets `text` as large as it will go, up to `preferred`, so that the
    /// block turned by `angle` degrees fits `room`.
    ///
    /// One line if it fits at `minimum` or larger; otherwise the wrap onto
    /// up to `maxLines` lines that allows the largest size. When nothing
    /// reaches `minimum`, the best of those is set at `minimum` and comes
    /// back with `fits == false` — whole, never shortened.
    static func fit(_ text: String, font name: String, preferred: CGFloat, minimum: CGFloat,
                    angle: Double, within room: CGSize, color: CGColor, maxLines: Int = 8) -> SetText {
        let reference = Fitting.reference
        let referenceFont = CTFontCreateWithName(name as CFString, reference, nil)
        var cache: [String: CGFloat] = [:]
        func measure(_ string: String) -> CGFloat {
            if let known = cache[string] { return known }
            let width = CGFloat(CTLineGetTypographicBounds(line(string, font: referenceFont, color: color), nil, nil, nil))
            cache[string] = width
            return width
        }

        let paragraphs = text.components(separatedBy: .newlines)
        func size(for lines: [String]) -> CGFloat {
            let block = CGSize(width: lines.map(measure).max() ?? 0,
                               height: reference * 1.2 * CGFloat(lines.count))
            return min(preferred, Fitting.largestSize(for: block, at: reference, angle: angle, within: room))
        }

        var best = paragraphs
        var bestSize = size(for: best)
        if bestSize < minimum, paragraphs.count < maxLines {
            for count in (paragraphs.count + 1)...maxLines {
                let lines = Fitting.balanced(paragraphs, into: count, measure: measure)
                let candidate = size(for: lines)
                if candidate > bestSize { best = lines; bestSize = candidate }
            }
        }

        let fits = bestSize >= minimum
        let chosen = max(bestSize, minimum)
        if !fits {
            // Nothing fits at a readable size. Wrap to the full length the
            // room allows along the line, however many lines that takes:
            // the block then overruns only across its lines — onto the page
            // — rather than off both ends of it.
            let length = Fitting.longestLine(at: angle, within: room) * reference / chosen
            best = Fitting.wrap(paragraphs, limit: length, measure: measure)
        }
        let font = CTFontCreateWithName(name as CFString, chosen, nil)
        let set = best.map { line($0, font: font, color: color) }
        return SetText(lines: set,
                       widths: set.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) },
                       size: chosen, fits: fits)
    }
}

/// The arithmetic behind ``PDFTools/fit(_:font:preferred:minimum:angle:within:color:maxLines:)``,
/// kept apart so it can be pinned without drawing anything.
enum Fitting {

    /// The size text is measured at before scaling.
    static let reference: CGFloat = 100

    /// The upright box a `size` box covers once turned by `degrees`.
    static func rotated(_ size: CGSize, _ degrees: Double) -> CGSize {
        let radians = degrees * .pi / 180
        let c = CGFloat(abs(cos(radians))), s = CGFloat(abs(sin(radians)))
        return CGSize(width: size.width * c + size.height * s,
                      height: size.width * s + size.height * c)
    }

    /// The largest point size at which a block measured as `block` at
    /// `reference` points fits `room` once turned. Unbounded for an empty
    /// block.
    static func largestSize(for block: CGSize, at reference: CGFloat, angle: Double,
                            within room: CGSize) -> CGFloat {
        let span = rotated(block, angle)
        let scaleX = span.width > 0 ? room.width / span.width : .greatestFiniteMagnitude
        let scaleY = span.height > 0 ? room.height / span.height : .greatestFiniteMagnitude
        return reference * min(scaleX, scaleY)
    }

    /// The longest single line that fits `room` when turned by `degrees`,
    /// ignoring its height.
    static func longestLine(at degrees: Double, within room: CGSize) -> CGFloat {
        let radians = degrees * .pi / 180
        let c = CGFloat(abs(cos(radians))), s = CGFloat(abs(sin(radians)))
        return min(c > 0.0001 ? room.width / c : .greatestFiniteMagnitude,
                   s > 0.0001 ? room.height / s : .greatestFiniteMagnitude)
    }

    /// Greedy wrap at `limit`, honouring the paragraphs given. A word wider
    /// than the limit is broken between characters rather than overflowing;
    /// every character is kept, in order.
    static func wrap(_ paragraphs: [String], limit: CGFloat, measure: (String) -> CGFloat) -> [String] {
        var lines: [String] = []
        for paragraph in paragraphs {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
                let candidate = line.isEmpty ? word : line + " " + word
                if measure(candidate) <= limit { line = candidate; continue }
                if !line.isEmpty { lines.append(line); line = "" }
                var piece = ""
                for character in word {
                    if !piece.isEmpty, measure(piece + String(character)) > limit {
                        lines.append(piece)
                        piece = ""
                    }
                    piece.append(character)
                }
                line = piece
            }
            lines.append(line)
        }
        return lines
    }

    /// The narrowest greedy wrap that takes no more than `count` lines —
    /// lines of even length, rather than one long and one stub.
    static func balanced(_ paragraphs: [String], into count: Int, measure: (String) -> CGFloat) -> [String] {
        let widest = paragraphs.map(measure).max() ?? 0
        var low: CGFloat = 0, high = max(widest, 1)
        var best = wrap(paragraphs, limit: high, measure: measure)
        for _ in 0..<24 {
            let middle = (low + high) / 2
            let lines = wrap(paragraphs, limit: middle, measure: measure)
            if lines.count <= count { best = lines; high = middle } else { low = middle }
        }
        return best
    }
}
