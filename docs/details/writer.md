# Writer

Writer is a small page editor for letters and short documents. Open it from Home. The document fills the canvas, with a resizable inspector on the left. Its toolbar, colours, section headings and control spacing use the same styles as the other remile tools.

## Write and arrange

The inspector shows settings for the current selection. Text groups font, size, bold, italic and colour. Font names appear in their own typeface. Font, spacing and list choices use compact native menus with the current selection marked. List choices pair a short name with a marker preview. Paragraph groups alignment, spacing and lists. Line spacing defaults to 1. Lists support dots, dashes, open circles, squares, numbers and both cases of letters and Roman numerals. Enter continues the list. Enter on an empty item ends it. Lines show stroke and independent arrow ends. Tables offer rows, columns, text and border settings.

Insert has four buttons: Shapes, LaTeX, Image and Table. Shapes offers only lines and rectangles. LaTeX opens a short source editor and renders locally. Double-click a rectangle or table cell to write. Tab and Shift-Tab move between table cells. Paste or drop an image onto the document. Drag a corner to resize it. Rectangle fill has a separate colour and opacity.

Objects move independently of body text by default. Enable Text wrap to keep body text outside an object. The body reflows when a drag ends. Narrow gaps at the margin are closed rather than filled with tiny text columns. Lock position prevents moving or resizing an object and is separate from text wrap. It still allows editing or deleting the object.

Moving an object shows guides for page margins, the centre, nearby objects and current body text rows. Hold Option to bypass snapping. Hold Shift to move on one axis or make a line horizontal or vertical when adjusting an endpoint. Guides are calculated only during a drag and never appear in exports.

The preview toolbar shows one-column and two-column buttons with page diagrams. Settings repeats these choices alongside shared header and footer text, top and bottom rules and page numbers. Columns apply to the whole document, with a 20-point gutter. Text flows down the left column, then the right, then onto the next page. Inline images and equations fit the column width. Headers and footers accept up to 200 characters on one line. These settings have Undo and persist in DOCX and PDF output. Mixed column sections and balancing the final page are not supported.

Settings below the static remile banner opens Page controls inside the inspector, with a back button to return to formatting. It controls paper, orientation, columns, headers, footers and rulers. Rulers are off initially and mark centimetres above and to the right of the page. They are read-only guides and do not change margins. A4 is the default. The inspector starts at a width proportional to the window, within a bounded range. Its divider remembers manual adjustments. Writer has no animated lighthouse. The preview toolbar offers zoom from 25% to 200% and Fit for the current viewport width. Paper recentres when the viewport width or zoom changes. Ordinary document updates preserve manual horizontal scrolling. The shared theme button sits at the bottom right. These view controls never modify document content.

Colour opens four palettes and the native custom colour picker. The default is [Okabe–Ito](https://jfly.uni-koeln.de/color/). Other choices are [IBM Carbon](https://www.carbondesignsystem.com/building-blocks/data-visualization/color-palettes) and [Paul Tol Bright and Muted](https://sronpersonalpages.nl/~pault/).

## Save and export

| Action | Result |
| --- | --- |
| **Save** | Save changes to the working DOCX at its current location. A new page asks for a name once. |
| **Save As…** | Save a new editable DOCX and continue working in that file. Available in File or the Save button's context menu. |
| **Export** | Create a separate PDF or DOCX copy. Keep the working file and its unsaved state unchanged. |

PDF preserves the page layout and searchable body text. Writer's DOCX contains editable text and objects plus a verified editing snapshot. The export panel chooses the copy's format. Saving a working document uses DOCX.

DOCX files open from Home, drop targets and the document chooser. The original filename and path are retained. Opening alone does not mark a document as edited or ask for a save when closing. Recently opened uses a muted rose DOCX badge, distinct from PDF gold.

Supported text-only edits to an external Word document can save in place. The original package, paragraph properties and unrelated parts are preserved. The current path is checked for external changes before writing. Edits that change paragraph structure, formatting or rich objects need a Writer DOCX copy instead. Save offers a separate name in that case. The original remains unchanged.

Supported inline images, shapes and equations use the local Word renderer and become inline images. Floating Word objects, tables, headers, footers and other unsupported layouts are rejected. A failed open keeps the current document intact. Full Word and Pages layout compatibility has not been verified.

Undo and Redo cover body edits, formatting, objects and page changes. Closing an edited document offers Save, Discard or Cancel. There is no crash recovery yet.

## Automation

The editor bridge exposes Writer as a target. Its `status` and `read` operations report the document revision, text and object metadata. Image bytes are excluded from reads. `replace` requires the revision from the latest read and replaces the body as plain text, preserving floating objects. Object creation and editing are currently GUI operations.

`writer-view [--zoom 0.25..2|--fit] [--rulers on|off] [--target UUID]` reads or changes the current view. `status` reports zoom and ruler visibility. These operations do not change the document revision or create Undo entries.

`writer-page` reads page furniture and column count. Add `--columns 1|2`, `--header`, `--footer`, `--clear-header`, `--clear-footer`, `--top-line on|off`, `--bottom-line on|off` or `--page-numbers on|off` to change it. `writer-object --id UUID` reads an object's wrap and lock state. Add `--wrap on|off` or `--lock on|off` to change it. Both commands require `--expected-sha256 HASH` from the latest `read` when editing. They share native Undo and accept `--target UUID`.

`save` writes the selected destination. An unsaved document must first be saved in Writer or exported. `export` takes a new absolute `.docx` or `.pdf` path and refuses to overwrite an existing file.

## Document limits

Writer creates its native text layout only while open. Pagination follows edits rather than a repeating timer. Limits are 40 pages, 200,000 UTF-16 text units, 100 objects and 20 images. Photos are reduced to at most 1,600 pixels per edge, with a 10 MB combined image budget. The undo history is limited to 30 groups. Undo and Redo sit in the top bar.
