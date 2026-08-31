//
//  HTMLRender.swift
//  PDFTools
//
//  Created by David Sherlock on 2026.
//
//  A web page as a PDF, through WebKit — the one corner of this library
//  that can touch the network, and it says so wherever it appears. Two
//  shapes: paginated onto real paper via the web view's print operation
//  (the default — createPDF alone yields one endless page), or that one
//  endless page when a caller asks for it. WKWebView lives on the main
//  thread and delivers its callbacks on the MAIN DISPATCH QUEUE — which
//  means the render must be genuinely async: pumping RunLoop.main from
//  inside a MainActor job can never drain the main queue again (the
//  drain is not re-entrant), and the first version of this file hung on
//  exactly that. Awaiting suspends the job, the queue drains, the
//  callbacks arrive.
//

#if os(macOS)
import Foundation
import PDFKit
@preconcurrency import WebKit

public extension PDFTools {

    /// How an HTML render comes out.
    struct HTMLOptions: Sendable {
        /// Paper for pagination, or `nil` for one long page.
        public var paper: PageSize?
        /// Margin on all sides, in points (ignored for the long page).
        public var margin: Double
        /// Seconds to let scripts settle after the page finishes loading.
        public var settle: TimeInterval
        /// Seconds before an unresponsive load is abandoned.
        public var timeout: TimeInterval

        public init(paper: PageSize? = .a4, margin: Double = 36, settle: TimeInterval = 2, timeout: TimeInterval = 60) {
            self.paper = paper
            self.margin = margin
            self.settle = settle
            self.timeout = timeout
        }
    }

    /// Renders a web page or local HTML file to PDF data.
    ///
    /// A plain `http://` URL may be refused by App Transport Security —
    /// the error says so and suggests `https://` or a local file.
    @MainActor
    static func renderHTML(_ source: URL, options: HTMLOptions = HTMLOptions()) async throws -> Data {
        // A window materialises AppKit enough for WebKit to lay out.
        _ = NSApplication.shared
        let paperSize = options.paper?.points ?? CGSize(width: 794, height: 1123)
        let view = WKWebView(frame: CGRect(origin: .zero,
                                           size: CGSize(width: paperSize.width - 2 * options.margin, height: paperSize.height)))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view

        let navigation = NavigationWatcher()
        view.navigationDelegate = navigation
        if source.isFileURL {
            view.loadFileURL(source, allowingReadAccessTo: source.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: source))
        }
        do {
            try await navigation.waitForLoad(timeout: options.timeout)
        } catch let error as NSError where error.domain != "PDFTools.timeout" {
            let ats = error.code == NSURLErrorAppTransportSecurityRequiresSecureConnection
            throw PDFToolsError.badValue(ats
                ? "\(source.absoluteString) is plain http and App Transport Security refused it — use https, or save the page and render the local file"
                : "\(source.absoluteString) would not load: \(error.localizedDescription)")
        } catch {
            throw PDFToolsError.badValue("\(source.absoluteString) did not finish loading within \(Int(options.timeout)) s")
        }
        // Let scripts settle.
        try? await Task.sleep(nanoseconds: UInt64(max(0, options.settle) * 1_000_000_000))

        guard let paper = options.paper else { return try await longPage(view) }
        return try await printed(view, in: window, paper: paper.points ?? paperSize, margin: options.margin)
    }

    // MARK: The two output shapes

    /// One endless page via WebKit's own PDF snapshot.
    @MainActor
    private static func longPage(_ view: WKWebView) async throws -> Data {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                view.createPDF { outcome in continuation.resume(with: outcome) }
            }
        } catch {
            throw PDFToolsError.writeFailed("The page would not render: \(error.localizedDescription)")
        }
    }

    /// Real pagination through the print system, saved straight to PDF.
    @MainActor
    private static func printed(_ view: WKWebView, in window: NSWindow, paper: CGSize, margin: Double) async throws -> Data {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdftools-html-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        let info = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: out,
        ])
        info.paperSize = paper
        info.topMargin = margin; info.bottomMargin = margin
        info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let operation = view.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // The print view needs real geometry or WebKit lays out nothing.
        operation.view?.frame = CGRect(origin: .zero, size: paper)

        let watcher = PrintWatcher()
        let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            watcher.done = { continuation.resume(returning: $0) }
            operation.runModal(for: window, delegate: watcher,
                               didRun: #selector(PrintWatcher.printOperationDidRun(_:success:contextInfo:)),
                               contextInfo: nil)
        }
        guard succeeded else {
            throw PDFToolsError.writeFailed("The print render failed")
        }
        guard let data = try? Data(contentsOf: out), !data.isEmpty else {
            throw PDFToolsError.writeFailed("The print render produced no file")
        }
        return data
    }
}

/// Watches a page load, resuming exactly one waiter. Main-actor only.
@MainActor
private final class NavigationWatcher: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    /// Suspends until the page finishes or fails, or the timeout passes.
    func waitForLoad(timeout: TimeInterval) async throws {
        if let outcome { return try outcome.get() }
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.settle(.failure(NSError(domain: "PDFTools.timeout", code: 1)))
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    private func settle(_ result: Result<Void, Error>) {
        guard outcome == nil else { return }
        outcome = result
        continuation?.resume(with: result)
        continuation = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { settle(.success(())) }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { settle(.failure(error)) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { settle(.failure(error)) }
    }
}

/// Hears the print operation finish.
private final class PrintWatcher: NSObject {
    var done: ((Bool) -> Void)?
    @objc func printOperationDidRun(_ printOperation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        done?(success)
    }
}
#endif
