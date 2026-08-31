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

## Requirements

macOS 14+ / iOS 17+, Swift 6. PDFKit, Core Graphics, Core Text, ImageIO — nothing third-party.

## License

MIT — see LICENSE.
