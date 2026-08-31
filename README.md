# Swift PDF Tools

Manipulating PDFs that already exist — merge, split, shuffle, rotate, crop, watermark, number, sign, fill, encrypt, render, shrink — over the frameworks the Mac ships. Creation lives elsewhere (`swift-text-pdf` and its family); this library never writes a document from scratch, it changes the one you hand it.

```swift
import PDFTools

let contract = try PDFTools.open(url)
let signature = try PDFTools.image(at: sigURL)
let (signed, where) = try PDFTools.sign(contract, signature: signature,
                                        placement: .above("Authorized signature"))
try PDFTools.write(signed, to: outURL)
print("signed page \(where.page) at \(where.rect)")   // points, top-left origin
```

## What it does

- 📄 **Pages** — `merge`, `split(every:)`, `split(before:)`, `extract`, `delete`, `reorder` (a full permutation, because a partial one silently dropping pages is a data-loss trap), `rotate` (quarter turns), `crop` (a top-left box, converted to PDF space correctly)
- ✍️ **Ink** — `watermark` (text and/or image, tiled or anchored), `number` (`"Page %d of %d"`), and `sign`: a PNG placed at a point, **above a label found by text search**, or into a named form field — pinned inside the page, never drawn off it
- 🔍 **Content** — `text`, and `find`, which answers *where* text sits: page + rectangle in points with a top-left origin. That rectangle is what turns "above the signature line" into coordinates
- 📝 **Forms** — `fields` and `fill`; widget values persist through save
- 🔐 **Security** — `protect` (user + owner password) and `unlocked`: writing an unlocked `PDFDocument` back to disk *keeps* its encryption, so the password-free copy comes from moving the pages into a fresh document
- 🖼️ **Raster** — `render` pages to images, `fromImages` (a4 / letter / fit), and `compress`: honest re-rendering to JPEG that writes **whichever version is smaller** and says which it kept

## The honest notes

- A signature placed here is a **stamped image**, flattened into the page — not a cryptographic signature.
- `compress` rasterises: scans and image decks shrink, text stops being selectable, and a vector-text PDF (already small) comes back with `keptCompressed == false` and its original bytes.
- Overlays re-render the document; extraction still works on the output (tested), but the file is a new drawing of the old pages.

## Measured

100 single-page documents merge in 0.22 s. Twenty letter pages render to 144-dpi PNGs in 0.88 s. A five-photo A4 PDF re-rendered at 120 dpi / q0.6 dropped 535 KB → 462 KB; a 13 KB text PDF would have *grown* to 51 KB, so the original was kept and the report said so. Fifteen tests pin all of it, pixel probes included.

## The second wave

- **HTML → PDF** — `renderHTML` (macOS): WebKit, properly paginated through
  the print system (`createPDF` alone yields one endless page — offered as
  the long-page option). The one corner of this library that can touch the
  network, and genuinely `async`: pumping the main run loop from inside a
  MainActor job can never drain the main queue again, so the render awaits
  its callbacks instead — the first version hung on exactly that.
- **Compare** — pages rendered at one density and diffed per pixel with a
  small tolerance (antialiasing is not "change"), regions counted on a
  coarse grid; pages only one document has count as added/removed.
  `diffImage` tints the changes red over a desaturated render.
- **Repair** — salvage, never a promise: every page that still parses is
  copied into a fresh document and the LOST pages are named. Empirically:
  damage that spares the cross-reference table costs the pages it hit;
  damage that reaches the xref costs everything, and the error says so.
- **Live annotations** — `markup` (highlight/underline/strikeout on every
  match, per text line), `note`, `link`: real annotations a reader can
  select and delete, unlike the overlay engine's burned-in ink. Freehand
  ink is deliberately absent — a terminal has no hand to draw with.
- **Metadata** — `metadata`/`setMetadata` over the document attributes.
- **Outline** — `outline` reads; `addOutline` WRITES THROUGH CORE GRAPHICS,
  because PDFKit's save drops a changed `outlineRoot` in every permutation
  on current macOS (probed: assign before/after building, `write(to:)`,
  `dataRepresentation()`, from URL and from data). The price is a
  re-render, the same trade as the overlay verbs.
- **Field authoring** — `addField` (text, checkbox, choice). The ORDER is
  load-bearing: a field name set before the field type is discarded by the
  save and the field reopens as "text0" — type first, name second.
- **Permissions** — `protect` gained `allowsPrinting`/`allowsCopying`.
  They bind USER-password openers only; with one password everyone opens
  as owner and a restriction binds nobody — pass a distinct owner password.

Measured, second wave: 220 paragraphs of HTML paginate to 8 A4 pages in
about 1.2 s; a 24-page pair compares in 1.5 s at 144 dpi; salvage of a
24-page file with eight damaged spots recovers 21 pages, names the three
lost, and takes 0.08 s.

## Requirements

macOS 14+ / iOS 17+, Swift 6. PDFKit, Core Graphics, Core Text, ImageIO — nothing third-party.

## License

MIT — see LICENSE.
