# sketcher — progress tracker

Living document. Update it in the same commit as the work it describes.

- **Plan of record:** `~/.claude/plans/i-want-to-build-humming-parnas.md`
- **Invariants:** `CLAUDE.md` (the 15 non-negotiables — read before touching rendering, undo, or input)
- **Architectural reference:** `/Users/phamqm/Projects/screenshot-editor` (native Swift, the code sketcher was modelled on)

---

## 0. Handoff — start here

**What sketcher is:** a lightweight native macOS sketching app (Windows-Paint-class
tools + Excalidraw-class vector editing) on a blank light/dark/transparent canvas.
Swift 6 + SwiftUI + CoreGraphics/CoreImage, **zero third-party deps, no Xcode
project**. Built in numbered milestones (M1–M8 = v1); each milestone stays runnable.

**Where it stands (2026-07-22):** M1 done, **M2 ~90% done**, **M3 core complete**
(shapes, multi-select, handles, clipboard, arrange), **M4 core complete** (color
system, eyedropper, blur/pixelate redaction, style inspector), **M5 core complete**
(multiline text), **M6 core complete** (raster layers + `SurfaceStore` carrying
real pixels, a perfect-freehand brush engine with six presets and a 1€ stabilizer,
three eraser modes, a layers panel, and **tile-quantized raster undo proven under
budget — T1 answered**). The app builds warning-clean, launches to a blank canvas
you can draw on, and has **139 unit tests + 25 pixel assertions all green**. The
single biggest open question — can SwiftUI `Canvas` hold frame rate — has been
**answered and resolved** (§7): the render cache is mandatory and it works. The
second — can raster undo stay under budget — is now **answered too** (§1 M6, the
T1 memory test). Nothing is blocked.

**M1–M6 are committed** on `main`; the working tree is clean. Next work is
**M7 (regions: select, move, copy, paste, bucket, wand)** — the floating-selection
subsystem. Commit when the user asks (don't commit unprompted).

### Resume in 60 seconds

```sh
cd /Users/phamqm/Projects/sketcher
make test      # 139 tests — must be green before you touch anything
make verify    # 25 pixel assertions through the real export pipeline
make run       # launches dist/Sketcher.app — draw a stroke to sanity-check
.build/release/Sketcher --perf   # re-run the perf gate if you touch rendering
```

Read order for a new agent: this section → §8 (file map) → `CLAUDE.md` (the 15
invariants) → §2 (decisions) → §3/§4 (traps + bugs) before editing.

### What to do next (M7, plus small tails)

**M3–M6 core are done** (see their subsections in §1). Next milestone is
**M7 — regions: select, move, copy, paste, bucket, wand**: the floating-selection
subsystem (lift → transform → drop as one undo entry), rect/ellipse/lasso/wand
with the five combine modes, animated marching ants (hand-written marching squares
for wand masks — T3), raster flood fill, and Rasterize Selection. **Spike the
`CGPath`-boolean figure-eight case in week one** (Risk 2) before the architecture
commits. `SurfaceStore` + the `RasterPatch` lifecycle from M6 are the foundation it
builds on, and `commitRasterMutation` is the pattern flood-fill/lift reuse.

**Small tails to mop up when convenient:**
- **M6 tails** (none blocking): the pixel eraser targets the active raster layer;
  on a vector layer it FALLS BACK to object-erase rather than prompting
  "Rasterize?" (D38 — no modal, but you must Rasterize Layer explicitly to paint
  pixels on a vector layer). The brush stabilizer bakes 1€-filtered points into the
  stored samples, so `streamline` is not re-editable after the fact (size/thinning
  still are — D34). No layer thumbnails in the panel yet; reorder is buttons
  (Raise/Lower), not drag. Calligraphy fakes a nib via per-sample pressure, not a
  true directional radius (D35).
- **M5 tails** (none blocking): while the text field editor is first responder,
  `⌘C/⌘X/⌘V/⌘A` are DISABLED (they'd otherwise paste objects onto the edit), so
  in-field text clipboard + select-all are deferred — the proper fix is
  first-responder-routed `cut:`/`copy:`/`paste:` menu items (see D33). `⌘Z`
  mid-edit ABORTS the whole edit (invariant 7) rather than doing within-field
  undo. IME composition is drawn by CoreText (sink glyphs are clear) and should
  work, but is **unverified on a device** — no headless way to test it. Font-panel
  underline/color effects (`changeAttributes:`) aren't handled; `⌘U` is.
- **M2 drag-out**: `PasteboardWriter.temporaryPNG` exists; needs an `NSItemProvider`
  drag source on a toolbar handle.
- **M2 export options** (1×/2×/3×, page vs selection, transparency): today `Export…`
  writes the page at 1×. `ExportService.renderRegion` / `renderObjects` exist.
- **M4 tails** (none blocking): inspector has no shadow/arrowhead/blend controls
  yet; the color UI has swatches + 8 recents but no shades-popover or hex field;
  non-destructive `.filter` objects are M9 (M4's blur is the destructive redaction).
- **M3 deferrals**: group *rotate* (general affine); non-polygon library shapes;
  align/distribute keyboard shortcuts. (Object-eraser tool: **done in M6.**)

### Gotchas that will waste your time if you don't know them

- **Leftover autosaved windows.** AppKit autosaves *untitled* documents and
  reopens them next launch (B8). If `make run` opens several windows, stale
  autosave docs from a prior session are being restored — they are real, not a
  bug. Clean them via Finder (the folder is TCC-protected; see B9):
  `osascript -e 'tell application "Finder" to delete (every item of folder ((path to library folder from user domain as text) & "Autosave Information") whose name contains "Sketcher")'`
- **Always `make test`, never bare `swift test`** (T4) — the CLT `Testing.framework`
  path injection lives in the Makefile.
- **`.unknown` objects render nothing by design** (forward-compat), so a decode
  bug looks identical to "drew nothing" (B7). If a shape vanishes, suspect the
  codec before the renderer. `make verify` catches this.
- The data layer is **nonisolated**; only the UI layer is `@MainActor` (D14). Do
  not add `@MainActor` to Model/Rendering/Persistence types.

---

## 1. Milestone status

Legend: ☐ not started · ◐ in progress · ☑ done & verified

| M | Title | Status | Verified by |
| --- | --- | --- | --- |
| M1 | Runnable app: window, blank light/dark canvas, one stroke, undo | ☑ | `make run` + `make test` (41 passing) |
| M2 | Viewport, render cache, pixel harness, export, codec, crash recovery | ◐ | `make verify` (21 checks), `--perf`, 54 tests |
| M3 | Shapes, multi-select, handles, clipboard, arrange | ◐ | 75 tests; core done, deferrals below |
| M4 | Color system, style inspector, blur redaction | ◐ | 89 tests; core done, tails below |
| M5 | Multiline text | ◐ | 108 tests + text pixel fixture; core done, tails below |
| M6 | Raster layers, brush engine, erasers, layers panel, raster undo | ◐ | 139 tests (T1 memory proven); core done, tails below |
| M7 | Regions: select, move, copy, paste, bucket, wand | ☐ | |
| M8 | Persistence, canvas ops, export formats — **v1 ships here** | ☐ | |
| M9–M11 | Appendix: filters, gradients, snapping, polish | ☐ | decided after M8 |

### M1 — done 2026-07-21

Delivered: `make run` opens an `NSDocument` window with a blank canvas
(light / dark / transparent) on a workspace backdrop with hairline + shadow.
Brush, eraser, rectangle, ellipse, line, arrow, polygon, hand. Pressure-aware
freehand with midpoint-quadratic smoothing. Multi-select scaffold, marquee,
undo/redo with mid-gesture abort, `Cmd+S` save/open through a real JSON codec,
cursor-anchored zoom, space-drag pan, contained/infinite toggle.

All M1 files exist and `make test` is green (41 tests, 4 suites).

**Scope pulled forward from later milestones** (cheaper now than retrofitting):
- Full `ObjectKind` enum including text/image/filter — see D13.
- `SceneCodec` + `KindCodec` (was M2) so `Cmd+S` is real rather than a stub.
- `Selection`, `SelectionShape`, `FloatingPixels` type declarations (was M3/M7)
  so multi-select and region selection do not force a later refactor.
- `SurfaceStore` (was M6) so the renderer signature never has to change.

**Deferred out of M1**: resize/rotate handles (M3), text editing (M5), the
committed/live render cache and `--test-render` harness (M2). `CanvasView`
currently re-renders the whole scene per frame — correct, not yet fast. **The M2
perf gate measures whether that matters.**

### M2 — in progress

Done and verified:

- [x] `ExportService` + `ImageExporter` (PNG / JPEG / TIFF / HEIC, DPI stamped as `72 × pixelsPerPoint`)
- [x] Headless `--test-render`, `--test-roundtrip`, `--perf` — exits before `NSApplication`, so it runs from a bare binary
- [x] **Perf gate answered** — see §7. Cache is mandatory; architecture holds
- [x] `RenderCaches` committed/live split, keyed on a `sceneRevision` counter
- [x] `make verify` — 21 pixel assertions through the real export pipeline
- [x] Named, flat geometry in the document format (D17)
- [x] Crash recovery — via AppKit, after deleting the hand-rolled version (D18)
- [x] `PasteboardWriter` + `⌘C` copies the canvas (PNG **and** TIFF, point-sized for Retina)
- [x] `Export…` (`⇧⌘E`) through `NSSavePanel`
- [x] Zoom tool (`Z`): click zooms in, Option-click zooms out; zoom-% readout
- [x] Cursor-anchored `⌘`+scroll, pinch, two-finger pan, Space-drag

Still open for M2:

- [ ] **Drag-out** — `ExportCommands.dragOutURL` exists but no UI invokes it yet
- [ ] Export options (1×/2×/3×, page vs selection, transparency toggle) — currently exports the page at 1×
- [ ] `CheckerboardView` / `ZoomControl` as separate views — both are currently inline in `CanvasView` / `ToolbarView`, which is fine but diverges from the planned file list

### M3 — core complete (2026-07-22)

Delivered and tested (21 new tests across `SelectionArrangeTests.swift`):

- [x] **Interactive resize handles.** A single shape shows an 8-handle box +
  rotate handle (`SelectionFrame`, `Model/SelectionFrame.swift`); rotated shapes
  keep the opposite WORLD corner pinned via the existing `resized(handle:to:)`.
  Handles are chrome-only, drawn in `CanvasView.drawFrame`, and hit-tested before
  object hits so an overlapping corner stays grabbable.
- [x] **Rotate handle** — a stalked circle above the top edge; Shift snaps to 15°.
- [x] **Group scale.** A multi-selection (or a single freehand stroke, which has
  no per-handle resize) scales as a group around the fixed opposite corner via
  `DrawObject.scaled(sx:sy:around:)`. **Group rotate is deferred** (needs a general
  per-child affine; see §6).
- [x] **Multi-select refinements** — Cmd-click select-behind (cycles the stack),
  Option-drag duplicate, group-aware click/marquee (clicking one group member
  selects the whole group).
- [x] **Object clipboard** — `⌘X`/`⌘C`/`⌘V`/`⇧⌘V`/`⌘D`. Copy writes a private UTI
  (`com.phamqm.sketcher.objects`, lossless `ObjectSpec` JSON — even unknown object
  types survive) **plus** PNG + TIFF for pasting into Mail/Preview.
  `⌘C` is context-sensitive: selection → objects, else the whole canvas.
- [x] **Arrange** — z-order (forward/backward/front/back within a layer),
  group/ungroup, align (6 ways), distribute (H/V, centers), lock/hide toggles.
  New **Arrange** menu. All route through the `Command` enum (invariant 13).
- [x] **Shape library** — a 20-entry data table (`Model/Shapes/ShapeLibrary.swift`)
  of regular polygons and stars, all mapping onto the existing
  `polygon(sides:starInnerRatio:)` kind, with a toolbar picker. **Non-polygon
  shapes (callout, heart, cloud) are deferred** — each needs a new `ObjectKind`
  threaded through render/hit-test/codec/resize.

Deferred within M3 (none blocking, all recorded in §6):

- [ ] Object-eraser *tool* → M6 (rides on the eraser-mode state machine). Object
  removal is already covered by Delete/Cut.
- [ ] Group *rotate* → needs a general group affine.
- [ ] Non-polygon library shapes → need new object kinds.
- [ ] Align/distribute keyboard shortcuts (menu-only for now; arrow-key equivalents
  are awkward and the plan's `Ctrl+Cmd+Arrows` collide with macOS Spaces on some
  setups).

### M4 — core complete (2026-07-22)

Delivered and tested (14 new tests: `ColorRedactionTests.swift`, `+StyleInspectorTests`):

- [x] **Color system** — primary/secondary slots, swap (`X`), reset to black/white
  (`D`), 8 de-duplicated recents, a preset+recents swatch strip in the toolbar.
  Clicking a swatch recolors the selection (one undo entry) or arms the next object.
- [x] **Eyedropper** — `I` samples the composited canvas (1×1 region through the
  real pipeline, read UN-premultiplied per invariant 10); `Shift+I` is the
  screen-wide `NSColorSampler` (no TCC prompt, D10). New **Color** menu.
- [x] **Blur / pixelate redaction** — `J` / `Shift+J`. Drag out a region; on commit
  it renders the composite, blurs/pixelates via one shared `CIContext`, DELETES
  every vector object fully inside, clips partially-covered ones (`addErasedRect`),
  and drops the opaque patch on top — one undo entry. **Destructive (D11)**: asserted
  by a pixel test (near-black count collapses) AND a file-content test (no
  `rectangle` geometry left in the saved JSON). Survives undo→redo via the new
  history-surface-retention fix (D25).
- [x] **Style inspector** — a trailing panel (toggle in the status bar) editing
  fill on/off + color, stroke width, dash, corner radius (rects), and opacity.
  With a selection it edits the objects; with none it edits the armed-tool defaults.
  Slider drags coalesce into ONE undo entry via `beginStyleEdit`/`endStyleEdit`
  (History's interactive bracket).

Tails (none blocking, in §0's "what to do next"):

- [ ] Inspector: no shadow / arrowhead / blend-mode controls yet.
- [ ] Color UI: swatches + recents, but no shades-popover or hex field.
- [ ] Non-destructive `.filter` objects (aesthetic blur that stays editable) are M9;
  M4's blur is the destructive privacy redaction only.

### M5 — core complete (2026-07-22)

Delivered and tested (19 new tests: `TextEditingTests.swift`; + a `text.png` pixel
fixture in the verify harness):

- [x] **Placement.** `T` click places an auto-width box; drag places a fixed-width
  box (auto-height). Clicking an existing text object edits it instead of stacking
  a new one. Routed through the existing draft machinery (`updateDraft` grows the
  box, `commitDraft` opens editing rather than finalizing).
- [x] **The editing sink (invariant T14).** A transparent `NSTextView`
  (`Text/TextEditingOverlay.swift`), a CHILD of `CanvasEventView`, is the
  IME/dictation/spellcheck/caret sink with its **glyphs drawn in clear** — CoreText
  draws the visible text through the one renderer, so there is no TextKit-vs-CoreText
  reflow pop at commit. It reports keystrokes back through `updateEditingText`;
  clicking away resigns it (→ commit); ⌘Return / Esc commit; tool change commits.
- [x] **One edit = one undo entry.** The whole session is a single `history.begin`/
  `end` bracket, so typing five lines + bold + a font change collapse into one
  "Text" entry. `Interaction.editingText` is now a mutating gesture; ⌘Z mid-edit
  aborts it (new box vanishes, existing one reverts).
- [x] **Rotated-box editing.** A rotated box un-rotates to 0° for editing (caret/IME
  geometry is wrong under a rotated parent) and re-rotates on commit — verified by
  a round-trip test.
- [x] **Styling.** Bold/italic/underline (`⌘B/I/U`), alignment, line height, font
  size, legibility plate, and the `NSFontPanel` (`⌘T`, via `changeFont:` routed to
  the sink while editing or to the window controller for a selected text object).
  A new **Format** menu and an inspector **Text** section drive them; edits fold
  into the open Text entry while editing, or record one entry against a selected
  text object. Empty boxes are discarded on commit (undoably for an existing one).
- [x] **Persistence.** Every text attribute (font, size, traits, alignment, line
  height, box/resize mode, plate) round-trips through `SceneCodec` — asserted.
- [x] **Byte-proof.** A `text.png` fixture renders a bold word through the REAL
  export pipeline: glyphs ink thousands of pixels, the empty region stays white,
  and the glyph band carries ink (a wrong y-flip in `TextMetrics.draw` would move
  it off-canvas).

Tails (none blocking, in §0's "what to do next"): in-field `⌘C/⌘X/⌘V/⌘A` are
disabled while the field editor is first responder (safe, but text clipboard +
select-all inside an edit are deferred to first-responder-routed menu items, D33);
`⌘Z` aborts the edit rather than doing within-field undo; IME is drawn by CoreText
and **unverified on a device**; font-panel underline/color effects aren't wired
(`⌘U` is).

### M6 — core complete (2026-07-22)

Delivered and tested (31 new tests: `BrushRasterTests.swift`, `RasterLayerTests.swift`):

- [x] **Brush engine — a perfect-freehand port** (`Model/Brush/Freehand.swift`).
  Samples → a FILLED variable-width outline polygon (CGContext has no variable-width
  stroke, so pressure REQUIRES a filled outline, not a stroked centerline). Pure and
  deterministic; `size`/`thinning` re-render losslessly. `StrokeGeometry.fill` fills
  it as ONE op so the highlighter's `.multiply` never double-darkens (T12).
- [x] **Six presets + Shift+B cycle** (`Model/Brush/BrushEngine.swift`): pen (clean
  constant), pressure, pencil (taper), highlighter (3× wide, multiply), calligraphy
  (nib faked by per-sample directional pressure — D35), marker. One switch, so
  render + hit-test + export agree on width.
- [x] **The stabilizer — a 1€ filter** (`Model/Brush/OneEuroFilter.swift`, D34).
  Runs at capture time: raw points in, smoothed points stored. Adaptive cutoff, so
  slow tremor is killed without lagging fast motion. `brush.streamline` drives it.
- [x] **Raster layers carry real pixels.** `SurfaceStore` (built empty in M1) now
  holds live surfaces. New raster layer, rasterize a vector layer, merge down,
  flatten — all route content through the ONE `SceneRenderer` via `RasterOps`
  (`Raster/RasterOps.swift`, nonisolated, invariant 11), so a baked layer cannot
  drift from its on-screen look.
- [x] **Tile-quantized raster undo — T1 answered.** A pixel edit stores a
  `RasterPatch` of MATERIALIZED 128-px tile crops (never `cropping(to:)`, which
  pins the whole canvas — the project-killer). `commitRasterMutation` builds the
  patch; `applyRasterPatch` composites the `before` tile on undo / `after` on redo.
  **Proven by the memory test**: 40 pixel-erase strokes stay under 30 MB (storing
  full surfaces would be ~80 MB), and one patch's two tiles together are smaller
  than a full canvas. A `.scene` entry in a 5-raster-layer doc is still kilobytes.
- [x] **Three eraser modes + Shift+E cycle** (`EraserMode`): object (delete touched
  objects), partial-vector (clip the swept outline out of `erasedGeometry`), pixel
  (clear alpha on a raster layer → a `RasterPatch`). Pixel erase on a transparent
  canvas yields **alpha 0, never white** (T15). **Overlapping partial erasures stay
  erased in the overlap** — the renderer punches each subpath as its own hole so a
  single even-odd union can't un-erase the crossing (T16-adjacent, D36).
- [x] **Layers panel** (`Views/LayersPanel.swift`) in the sidebar: per-layer
  visibility / lock / rename, active highlight, opacity (coalesced slider) + blend
  picker, and new-vector / new-raster / duplicate / merge / delete / raise / lower /
  rasterize. A new **Layer** menu + `⌘⌥N` / `⌘⌥⇧N` / `⌘E` / `⌘⌥E`, and an anti-alias
  toggle in **View** (pixel-art mode).

Tails (none blocking, in §0's "what to do next"): pixel erase on a vector layer
falls back to object-erase (no "Rasterize?" modal — D38); `streamline` bakes into
stored samples (D34); no layer thumbnails, reorder is buttons not drag; calligraphy
is a faked nib (D35).

---

## 2. Technical design decisions

Decisions already made, with the reasoning, so they are not re-litigated. Add to
this list rather than quietly reversing an entry.

| # | Decision | Why |
| --- | --- | --- |
| D1 | Native Swift 6 + SwiftUI + CoreGraphics, zero third-party deps, no `.xcodeproj` | Matches the reference project; ~5 MB app, instant launch. Large parts of screenshot-editor port nearly verbatim. |
| D2 | **Hybrid, vector-primary, layered.** A layer is `.vector([DrawObject])` or `.raster(SurfaceID)` | Pure vector cannot do bucket fill or pixel region select (Excalidraw/tldraw declined to build both). Pure raster throws away editable shapes and cheap undo. |
| D3 | `Scene` holds `SurfaceID` handles, never pixels | Keeps a snapshot kilobytes even with 5 raster layers — the single decision that makes snapshot undo survive contact with raster. |
| D4 | Region ops use a **floating-selection** model (lift → transform → drop) | Move, scale, rotate, flip, cut, copy, paste all become one code path instead of six. Matches Paint's mental model. |
| D5 | `NSDocument`-based regular windowed app, not a menu-bar accessory | Open Recent, Versions, autosave, edited dot, window tabs for ~150 lines. The reference was an accessory only because it was clipboard-triggered. |
| D6 | AppKit `NSView` for all input, from commit one | SwiftUI `DragGesture` exposes no pressure, tilt, scroll, or per-event modifiers, and coalesces samples. Retrofitting rewrites every gesture. |
| D7 | Working color space **sRGB**, recorded in `CanvasSpec.colorSpaceName` | Exports render identically everywhere. Per-document P3 stays cheap to add later. |
| D8 | Default canvas **2560×1600 @ pixelsPerPoint 2.0** | ~1280×800 pt on screen, 16.4 MB/raster layer, ~50 MB live during a raster drag. |
| D9 | Page rect exists in **both** canvas modes and is always the export boundary | Keeps export predictable and keeps "light/dark canvas" meaningful in infinite mode. `Trim to Content` snaps the page to the content bbox on demand. |
| D10 | **Zero TCC permissions** in v1 | Eyedropper uses `NSColorSampler`; screen capture is "New from Clipboard" only. Also avoids the ad-hoc-signing cdhash churn that resets grants on every rebuild. |
| D11 | Redaction is **destructive at commit**, not at export | Otherwise the saved file still contains recoverable geometry under the blur. Non-destructive aesthetic blur is a separate `.filter` object (M9). |
| D12 | Per-sample pressure in `StrokePayload` from day one | Retrofitting width-per-sample into `[CGPoint]` later forces a breaking `formatVersion` bump. |
| D13 | Full `ObjectKind` enum declared in M1 even though M1 only draws 2 kinds | Swift forces every `switch` to handle every case, so declaring late means revisiting every switch in M3. Mechanical now, churn later. |
| D14 | **No `.defaultIsolation(MainActor.self)`.** Data layer nonisolated; UI layer explicitly `@MainActor` | **Deviates from the plan and from screenshot-editor.** There, nearly everything is UI. Here the pure-data layer dominates and must run off-main (flood fill, PNG encode, autosave). MainActor-by-default isolated every `Codable` conformance on value types and made the renderer uncallable from a background context — see B1. |
| D15 | File-format enums are **string-backed**; enums with associated values get hand-written `Codable` | Synthesized `Codable` emits `{"solid":{}}` for a case-only enum and `{"solid":{"_0":…}}` for one with a payload. `_0` is a compiler artifact that would be baked into the document format forever. See B2. |
| D16 | `.sketcher` is a flat JSON file until M8, not a package | M1–M7 create no raster surfaces, so there is nothing to put in a package yet. `Info.plist` carries a comment marking the M8 flip to `LSTypeIsPackage`. |
| D17 | **Geometry in the document format is named and flat** (`{"x":20,"y":20,"width":100,"height":60}`), via `Persistence/GeometrySpec.swift` | CoreGraphics' own `Codable` encodes POSITIONALLY — `CGRect` as `[[x,y],[w,h]]`. That is opaque in a saved file and depends on a Foundation implementation detail that is not contractual. See B7. |
| D18 | **No hand-rolled crash recovery.** Rely on AppKit's `autosavesInPlace` | **Corrects the plan.** The plan asserted "autosavesInPlace only covers documents with a file URL, so untitled crash recovery is its own path". That is false on macOS 26: untitled documents ARE autosaved (to `~/Library/Autosave Information`) and reopened on the next launch, surviving `kill -9`. `ScratchAutosave` reimplemented a platform feature and the two fought. See B8. |
| D19 | **`SelectionFrame` is the single source of handle geometry**, chrome-only, rebuilt each access from the live scene | Handles must track a shape as it resizes/rotates. Deriving them on demand (never storing) means they can never go stale, and keeps invariant 4 (`Scene` is content only) intact. Rotate-handle offset is a canvas distance derived from `transform` so it stays constant on screen. |
| D20 | **Single-object resize uses `resized(handle:to:)`; multi/stroke uses `scaled(sx:sy:around:)`** | The per-shape resize keeps a rotated shape's opposite WORLD corner pinned — that math does not generalize to a heterogeneous group. A group instead scales every member's geometry uniformly around the fixed corner. Both recompute from the pre-gesture originals every frame (no float drift), the same discipline as `Interaction.resizing`. |
| D21 | **Group scale is geometry-only: shape stroke weight is NOT scaled**, but a freehand stroke's brush width and text's font size ARE | Figma's default — a resized rectangle keeps its border weight, so scaling a group does not balloon every outline. A freehand mark and text are expected to scale wholesale, so those scale their width/size. Recorded because it is a deliberate asymmetry someone will otherwise "fix". |
| D22 | **Object clipboard = private UTI (lossless `ObjectSpec` JSON) + PNG + TIFF.** Paste reads object JSON ONLY | The private type round-trips geometry, style, rotation, groups, and unknown types between Sketcher windows/launches; PNG+TIFF let other apps consume a copy. Pasting an EXTERNAL image as a raster object waits for M6/M7, where the `SurfaceStore` lifecycle across undo/redo is built — pruning a just-registered surface on undo would lose its pixels on redo. |
| D23 | **Groups are a flat id list, atomic for selection.** Clicking one member selects the whole outermost group; duplicate/paste remaps group ids | Excalidraw's model (D-none new: `groupIDs` existed from M1). No recursive scene graph, so `Scene` stays a flat value type. Remapping on copy stops a duplicated group from silently rejoining its original. Double-click-to-enter-group is deferred (M10-ish). |
| D24 | **Shape library maps entirely onto `polygon(sides:starInnerRatio:)`** | ~20 real entries (regular polygons + stars) with ZERO new render/hit-test/codec/resize paths — the whole library is free because the polygon kind already does N-gons and stars. Non-polygon shapes are the expensive ones and are deferred, not faked. |
| D25 | **Pruning keeps surfaces referenced by any HISTORY entry, not just the live scene** (`History.referencedSurfaceIDs` ∪ `scene.referencedSurfaceIDs`) | Redaction (and future image paste) registers a surface the scene references. After undo the scene no longer references it, but the redo stack does — so a plain `scene`-only keep-set would collect it and redo would render an empty patch. This is the lightweight M4 substitute for M6's full `RasterPatch` lifecycle; it is enough because `.scene` history entries carry the whole `Scene` (which holds the `SurfaceID`s). |
| D26 | **Redaction is a destructive `.image` object on the active vector layer**, not a new raster layer | The plan says "raster layer at the top", but raster layers are M6. An `.image` object renders through the identical path, so redaction ships in M4 with no M6 dependency. Covered objects are DELETED (secret gone from the file); partially-covered ones get the region appended to `erasedGeometry` in their LOCAL frame. Blur radius / pixelate block scale with region size. |
| D27 | **Eyedropper (`I`) arms the color; it does NOT recolor the selection.** Swatch clicks DO | Picking a color up and painting a color down are different intents — Paint's eyedropper never recolors what is selected. Discrete swatch/inspector actions apply to the selection (one undo entry each); the continuous main color well only arms, to avoid undo spam during a drag. |
| D28 | **The inspector edits the selection when there is one, else the armed-tool defaults**, and slider drags coalesce via History's interactive bracket | One panel answers both "how will the next shape look" and "restyle these". `beginStyleEdit`/`endStyleEdit` wrap a slider drag (SwiftUI `onEditingChanged`) so 40 value changes become one undo entry — the same coalescing `beginInteractive`/`endInteractive` was built for. |
| D29 | **The `NSTextView` sink draws its glyphs in CLEAR; CoreText draws the visible text** (invariant T14) | Letting TextKit lay out visible glyphs produces a reflow pop at commit (TextKit 2 and `CTFramesetter` disagree on line breaking). Keeping the sink glyphs clear means the object rendered live (it is in `liveObjectIDs`) via CoreText IS the committed layout — zero reflow by construction. The caret stays visible via `insertionPointColor`; IME composition is drawn by CoreText because `updateEditingText` receives the sink's full string (marked text included). |
| D30 | **A text edit is one long-lived `Interaction.editingText`, bracketed by a single `history.begin`/`end`** | Typing, bold, alignment, and font changes made during a session all fold into one "Text" undo entry. `editingText` is therefore a *mutating gesture* (so a stray `record` from a menu command can't push into the open bracket); the dedicated text setters mutate the scene directly. ⌘Z mid-edit aborts (invariant 7); tool change commits; clicking away resigns the sink → commit. |
| D31 | **The sink is a CHILD of `CanvasEventView`, not a sibling SwiftUI layer** | Clicks INSIDE it position the caret; clicks OUTSIDE reach the parent's `mouseDown`, which resigns it → commit. `CanvasEventLayer` carries `editingTextID`/`sceneRevision`/`transform` so SwiftUI re-runs `updateNSView` (→ `syncTextEditing`) exactly when the sink must appear, resize (auto-width growth, zoom), or tear down. The sink's font/paragraph are configured only on an attribute-signature change, so a keystroke never resets it mid-IME. |
| D32 | **A rotated text box un-rotates to 0° in the scene for editing, re-rotating on commit** | Caret and IME geometry are wrong under a rotated parent, and an axis-aligned overlay is far simpler than a rotated `NSView`. The pre-edit angle is held on `editingOriginalRotation`; net rotation change is zero, so an unchanged edit still pushes no entry. |
| D33 | **While the field editor is first responder, object-editing ⌘-keys (`⌘C/⌘X/⌘V/⌘A`/Delete/Duplicate) are DISABLED**, not re-routed | Their key equivalents would otherwise paste objects onto the text being typed. Disabling them (via `validateMenuItem`) is safe and non-destructive; the proper fix — first-responder-routed `cut:`/`copy:`/`paste:` menu items so the field editor owns them — is deferred rather than risk regressing M3's object clipboard, which is unit-tested but whose responder-chain routing is not. |
| D34 | **Stabilization is a 1€ filter at CAPTURE time (`OneEuroFilter`), separate from `Freehand`'s render-time geometry** | Upstream perfect-freehand folds `streamline` into the outline pass; this port splits it. Jitter is a property of the input device (fix it once, live), geometry is a property of the mark (derive it losslessly from stored samples). Consequence: `streamline` bakes into the stored points, so it is NOT re-editable after the fact — but `size`/`thinning` still re-render losslessly, which is what the invariant actually promises. A single stabilizer also means the two never fight over the same knob. |
| D35 | **Calligraphy fakes a nib via per-sample directional pressure**, not a true directional radius | `Freehand.Options` has one scalar width curve, no per-sample radius vector. `BrushEngine.inputPoints` sets each sample's pressure to `|sin(travel − nibAngle)|` (floored at 0.18) and runs the engine with `thinning` high, `simulatePressure` off — thick across the nib, thin along it. Good enough to read as calligraphy; a real angled-nib stamp is a later refinement. |
| D36 | **`erasedGeometry` is clipped subpath-by-subpath (sequential clips intersect), NOT as one even-odd union** | Two overlapping eraser strokes both cover the crossing → winding 2 → a single even-odd hole reads it as OUTSIDE the hole and UN-erases it (T16). Punching each subpath as its own `(hugeRect + subpath)` even-odd hole and letting the sequential clips intersect subtracts the true union. `hitTest` mirrors it (a point inside ANY subpath is erased). This also fixes the same latent bug for overlapping M4 redaction rects. |
| D37 | **A pixel edit is a `RasterPatch` (tile diff), NOT a `.scene` snapshot** | Setting a layer's `SurfaceID` to a new full surface DOES change `Scene`, so `history.end` would push a `.scene` entry — but that entry's surface must be retained, so 50 raster strokes would pin 50 full canvases (~800 MB). The eraser therefore opens NO gesture bracket; `commitRasterMutation` pushes a `RasterPatch` of materialized tile crops instead, and `pruneSurfaces` drops the superseded full surface. This is the whole reason `HistoryEntry` is heterogeneous. |
| D38 | **Pixel erase on a vector layer falls back to object-erase; it does NOT prompt "Rasterize layer?"** | The plan's routing table says prompt, but "lightweight = no modal dialogs" (Risk 7) wins. The eraser always does something sensible (delete the objects it sweeps); to paint pixels on a vector layer you run **Rasterize Layer** explicitly first. Keeps the eraser non-blocking and the seam predictable. |
| D39 | **Rasterize / merge / flatten build a throwaway `Scene` (transparent background) and draw it through `SceneRenderer`** | Reuses the ONE renderer (invariant 2) instead of a second bake path, so a rasterized layer is pixel-identical to its live look. The canvas background is a canvas property, not a layer, so it is deliberately NOT baked in — a transparent-canvas doc stays transparent after Flatten. Off-page content is clipped, because a surface is exactly page-sized (answers the M6 open question below). |

### Rejected, with reasons

| Rejected | Why |
| --- | --- |
| **PencilKit** | `PKCanvasView`/`PKToolPicker` do not exist in the macOS 26 SDK — Catalyst only. `PKDrawing(strokes:)` crashes outside an app bundle (6/6 runs), which would break the headless pixel harness. `PKDrawing` only vends `NSImage`, breaking the one-renderer invariant. |
| SwiftUI `DocumentGroup` / `FileDocument` | `FileDocument.write` hands back a regular-file `FileWrapper`; writing a package needs an undocumented swap. `ReferenceFileDocument` requires `ObservableObject`, fighting `@Observable`. |
| `CGDisplayCreateImage` | Obsoleted in macOS 15 — will not compile. |
| SVG export | Needs a second renderer, breaking invariant 2. |
| Bezier node editing | Comparable in size to the entire selection subsystem. |
| Skew / warp | Requires promoting every object to a full `CGAffineTransform`, touching every hit test. |
| QuickLook thumbnails | Needs an `.appex`, which SwiftPM cannot produce. Static document icon is the v1 answer. |
| Angular / diamond gradients | No CG or CI primitive; would need a hand-written `CIColorKernel`. Ship linear and radial only. |

---

## 3. Known traps — verified, and how they bite

These are real bug classes confirmed against the SDK or by measurement. Each has
a test that catches it; if you touch the area, keep the test.

| # | Trap | Symptom | Fix |
| --- | --- | --- | --- |
| T1 | `CGImage.cropping(to:)` does **not** copy pixels — the header states it retains the original | 50 undo patches silently pin 2.3 GB. **Invisible until you profile.** | Materialize patches into fresh bitmap contexts. Test: `SurfaceStore.totalBytes` after 50 strokes. |
| T2 | `CGContext.clip(to:mask:)` **rejects alpha-only images** | Magic-wand selection silently does nothing, or inverts | Masks are 8-bit **DeviceGray, `alphaInfo .none`**, polarity 255 = selected. |
| T3 | No system API converts a bitmap mask to a `CGPath` | Wand marching-ants impossible by the obvious route | Hand-written marching squares + Douglas–Peucker (~200–400 LOC, M7). |
| T4 | `Testing.framework` ships outside default search paths (CLT-only machines) | `swift test` → `no such module 'Testing'`; or it builds and the binary dies at launch | `make test` injects `-F` plus **two** rpaths. Never run bare `swift test`. |
| T5 | Swift's `Hasher` is per-process seeded | `hashValue`-derived filenames or RNG seeds change every launch; renders become non-reproducible | `CryptoKit.SHA256` for content addressing, UUID raw bytes for RNG seeds. |
| T6 | Tablet pressure: checking only `event.type` misses most drivers | Pressure reads 1.0 forever; strokes never taper | Check `e.subtype == .tabletPoint \|\| e.type == .tabletPoint`. |
| T7 | Backspace delivers U+007F, which does **not** equal `KeyEquivalent.delete` | `case .delete` silently never fires | Match the raw scalar (`\u{7F}`, `\u{8}`, `\u{F728}`). |
| T8 | `NSWindow` supplies its own empty `NSUndoManager` ahead of the controller | `Cmd+Z` is dead | Custom `performUndo:`/`performRedo:` selectors, not standard `undo:`/`redo:`. |
| T9 | CoreImage without `clampedToExtent()` | Dark halo at blur region edges | Clamp before every convolution, `.cropped(to:)` after. |
| T10 | `CIPixellate` with an unanchored `center` | Blocks visibly crawl while resizing the region | Anchor `filter.center` to the region origin. |
| T11 | Forcing sRGB output on a P3 source | Visible seam at patch edges | Preserve the source color space through `createCGImage`. |
| T12 | Stroking a polyline segment-by-segment | Highlighter double-darkens at every joint | One path, **one** stroke op, `.multiply` blend. |
| T13 | Round line caps do not render a zero-length line | A click without a drag draws nothing | Single point → filled ellipse. |
| T14 | `NSTextView` laying out while CoreText renders | Visible reflow pop at commit (TextKit 2 and `CTFramesetter` disagree on line breaking) | Use `NSTextView` purely as an IME sink with its own drawing disabled. |
| T15 | `.destinationOut` on an opaque context | Eraser paints white instead of clearing to alpha 0 | **M6:** `RasterOps.erase` clears with `.clear` blend on the always-premultiplied canvas context; asserted by `eraseIsTransparentNotWhite`. |
| T16 | Even-odd clip for accumulated eraser strokes | Overlapping eraser strokes **un-erase** in the overlap | **M6 (D36):** punch each `erasedGeometry` subpath as its own even-odd hole; sequential clips intersect. (Chose this over `CGPath.subtracting` — no path-flattening step needed.) Asserted by `overlappingVectorErase`. |
| T17 | `NSDocumentClass` under SwiftPM module mangling | Document class fails to resolve at launch | `@objc(SketchDocument)`. |

---

## 4. Bug log

Actual bugs hit during development. Newest first. Record the *symptom* too —
that is what makes it findable next time.

| # | Date | Symptom | Root cause | Fix | Test |
| --- | --- | --- | --- | --- | --- |
| B1 | 2026-07-21 | Build failed with a cascading wall of `main actor-isolated conformance of 'X' to 'Encodable' cannot be used in nonisolated context`, plus `NSDocument` overrides rejected for mismatched isolation | `.defaultIsolation(MainActor.self)` isolates *every* declared type, including the `Codable` conformances of pure value types — and AppKit declares `read(from:ofType:)` and `autosavesInPlace` nonisolated, so overrides could not match | Inverted the default: dropped `defaultIsolation`, marked the UI layer `@MainActor` explicitly (D14). `SurfaceStore` became a lock-guarded `@unchecked Sendable` class so the renderer can run off-main | build is warning-clean |
| B2 | 2026-07-21 | `CodecTests` round-trip failed: `expected Dictionary<String, Any> … found a string` at `style.dash` | `DashStyle` is a case-only enum but was `Codable` by synthesis, which emits `{"solid":{}}` rather than `"solid"`. Found by hand-writing a JSON fixture — the symmetric encode/decode path had hidden it | `DashStyle` is now `String`-backed; `CanvasBackground` got a hand-written `{"kind":…,"color":…}` encoding (D15) | `CodecTests.unknownObjectSurvivesRoundTrip` |
| B3 | 2026-07-21 | `#expect(!history.record(…))` failed to compile: *cannot use mutating member on immutable value* | The `#expect` macro decomposes the call into a closure over `$0`, which cannot call a `mutating` method | Hoist the call into a `let` before asserting. Applies to every `mutating` method under `#expect` | n/a — compile-time |
| B4 | 2026-07-21 | Two `TemporaryPointers` warnings in `TextMetrics` | `CTParagraphStyleSetting` stores a raw pointer into a local; passing `&alignment` inline yields a pointer valid only for the initializer call — a genuine dangling read, not a style nit | Nested `withUnsafePointer` so the locals outlive `CTParagraphStyleCreate` | build is warning-clean |
| B5 | 2026-07-21 | `var commandKey` rejected: *not concurrency-safe because it is nonisolated global shared mutable state* | Used the classic associated-object pattern, which needs a mutable global as its key | Dropped it entirely for `NSMenuItem.representedObject`, which is the field AppKit already provides | build is warning-clean |
| B6 | 2026-07-21 | `verify-render.swift` reported *could not load* for every PNG that had rendered fine | `CGBitmapContext` does not accept STRAIGHT alpha (`CGImageAlphaInfo.last`/`.first`) — the initializer returns nil for that combination. Only premultiplied or skip-alpha are valid | Draw premultiplied, un-premultiply on read in `Raster.pixel()`. That is what the colour comparisons needed anyway (invariant 10) | `make verify` |
| B7 | 2026-07-21 | Fixtures rendered a blank canvas: 0 inked pixels, though `--test-render` printed OK and the codec reported 5 objects | CoreGraphics `Codable` is POSITIONAL: `CGPoint` → `[x,y]`, `CGRect` → `[[x,y],[w,h]]`. The hand-written named-key fixture failed to decode, so `KindCodec.kind` returned nil and every shape silently became `.unknown` — which renders nothing **by design**. The forward-compat path masked a decode failure as valid data | Named, flat geometry in the format (D17). **The lesson: `.unknown` is indistinguishable from a decode bug, so the format must be hand-writable** | `make verify` (21 checks) |
| B8 | 2026-07-21 | Windows multiplied on every launch — 1, then 2, 3, 4 — each a separate document. `applicationShouldOpenUntitledFile` was never called | `Thread.callStackSymbols` showed `-[NSDocumentController reopenDocumentForURL:]` → AppKit was reopening **autosaved untitled documents**, a built-in feature that `ScratchAutosave` duplicated. Both mechanisms restored the same work and each restore re-armed the other | Deleted `ScratchAutosave` entirely (D18). Also `window.isRestorable = false` so Cocoa window restoration cannot compete | 2× SIGKILL relaunch → exactly 1 window |
| B9 | 2026-07-21 | `~/Library/Autosave Information` looked empty from the shell while AppKit reported files in it | The directory is **TCC-protected**: `ls`/`os.listdir` fail with *Operation not permitted*, and an empty listing is indistinguishable from a real one | Inspect and clean it via Finder (`osascript`), which holds the entitlement. **Never trust an empty listing of a protected path** | — |

---

## 5. Environment

Verified 2026-07-21 on this machine.

- macOS **26.5.2** (25F84), arm64
- **⚠️ macOS 26 / Swift 6.3** — the plan of record assumed macOS 15 (`.macOS(.v15)` is still the deploy target, which is correct). But several SDK facts differ from the plan's assumptions on this newer OS: PencilKit is Catalyst-only, `autosavesInPlace` covers untitled docs (D18/B8). Re-verify SDK claims against *this* OS, not the plan.
- Swift **6.3.3** (swiftlang-6.3.3.1.3), target `arm64-apple-macosx26.0`
- **Command Line Tools only** — no Xcode, no `xcodebuild`, no `.xcodeproj`
- `Testing.framework` present at `/Library/Developer/CommandLineTools/Library/Developer/Frameworks/`
- Display is **120 Hz ProMotion** → the frame budget is **8.3 ms**, not 16.6

```sh
make run       # build, bundle, launch
make run-fg    # same, logs stream to terminal (dev loop)
make test      # unit tests — USE THIS, never bare `swift test`
make verify    # end-to-end pixel-fidelity check (from M2)
make release   # optimized build + bundle
make clean
```

---

## 6. Future work / open questions

Things deliberately deferred. Not bugs — decisions with a "not yet" attached.

### Deferred to the M9–M11 appendix
- Generic filter pipeline (~20 curated CIFilters), non-destructive filter objects
- Linear + radial gradients with on-canvas handles and a multi-stop editor
- Smart guides, snap-to-grid, rulers, manual guides
- QuickShape recognition, mirror/radial symmetry, hand-drawn rough style
- Clone stamp, loupe, spotlight mask, laser pointer, zen mode
- Full accessibility pass, history byte-budget enforcement, stress tests

### Open questions to revisit
- ~~**Perf gate (M2)**~~ — **ANSWERED, see §7.**
- **Per-document color space** — sRGB is hardcoded as the default; `colorSpaceName` already exists in `CanvasSpec`, so exposing P3 in the New Canvas sheet is additive whenever it is wanted.
- **Editable PNG (`skTc` chunk)** — convenience round-trip only. Any third-party re-save or optimizer strips it; must be surfaced in the UI, never presented as the canonical format.
- ~~**Infinite mode + raster layers**~~ — **DECIDED at M6 (D39): a raster surface is exactly page-sized, so raster content is CLIPPED to the page.** Rasterize/flatten in infinite mode drop off-page content. If growing raster layers is ever wanted, it rides on the M8 canvas-resize path (Trim to Content / Canvas Size), not on the raster op.
- **Layer count cap** — 16 is the planned ceiling for memory reasons. Not yet enforced (M6 adds unbounded new-layer). Revisit once real documents exist; the cap belongs on `addLayer`.

---

## 7. Perf gate results (M2) — measured, not estimated

Run it yourself: `.build/release/Sketcher --perf [strokes] [pointsPerStroke]`

Measured on this machine (macOS 26.5.2, arm64, 120 Hz → **8.3 ms budget**),
release build, canvas 2560×1600, `SceneRenderer.draw` of the full scene into a
canvas-sized bitmap — which is exactly what a SwiftUI `Canvas` frame costs,
since `Canvas` re-runs its whole closure per invalidation and has no dirty-rect
concept.

| Strokes (×300 pts) | Median render | vs budget |
| --- | --- | --- |
| 10 | 2.67 ms | ✅ |
| 25 | 5.11 ms | ✅ |
| **~42** | **~8.3 ms** | **← threshold** |
| 50 | 9.97 ms | ❌ |
| 100 | 19.07 ms | ❌ |
| 200 | 40.59 ms | ❌ |
| 400 | 77.91 ms | ❌ |
| 800 | 156.15 ms | ❌ |
| 2000 | 393.50 ms | ❌ 47× over |
| **cached blit (any size)** | **0.34 ms** | ✅ **25× under** |

### What this establishes

1. **Cost is linear in total sample count**, ~0.00065 ms per point. The budget is
   ~12,700 points total — reachable in a few minutes of sketching.
2. **The committed/live cache is mandatory, not an optimization.** Without it the
   app becomes visibly janky at ~50 strokes.
3. **The cache is sufficient.** A cached blit is 0.34 ms regardless of scene
   complexity, leaving 8 ms of headroom for the in-flight stroke.
4. **The architecture is NOT falsified** — no `CALayer`/`NSView` swap needed. The
   escape hatch stays available but unused.
5. **Debug vs release is only ~20%** (474 ms vs 394 ms at 2000 strokes). The cost
   is CoreGraphics rasterization, not Swift overhead — so micro-optimizing Swift
   would be wasted effort. Only avoiding the work helps.

### Consequence for the design

`RenderCaches` keys on `(sceneRevision, canvasGeneration, pixelSize, excluded)`.
`sceneRevision` is a counter bumped by a `didSet` on `EditorViewModel.scene` —
NOT a `Scene ==` comparison, because deep-comparing 2,000 objects on the *equal*
path (the common case) costs as much as the render it was meant to avoid.

---

## 8. Architecture / file map

58 source files, ~9.6k lines; 9 test files, ~2.5k lines. Layered strictly:
**Model → Rendering → ViewModel → Input/Views/App**. The dependency arrow never
points backwards — Model knows nothing of AppKit, and nothing below the view
layer knows about points or zoom (invariant 1).

### Model — pure value types, nonisolated (`Sources/Sketcher/Model/`)
| File | Purpose |
| --- | --- |
| `Scene.swift` | `Scene` (the whole undoable document), `CanvasSpec`, `CanvasMode`, `CanvasBackground` (with `defaultInk`), `PixelSize`, `Guide`. The one type snapshotted for undo. |
| `Layer.swift` | `Layer`, `LayerContent` (`.vector([DrawObject])` / `.raster(SurfaceID)`), `SurfaceID`. |
| `DrawObject.swift` | `DrawObject`, `ObjectKind` (the full tagged union), and every payload (`StrokePayload`/`StrokeSample`, `ArrowPayload`, `TextPayload`, `RasterPayload`, `FilterPayload`, `PathGeometry`). Hand-written `Codable` where the format needs to stay clean. |
| `DrawObject+Geometry.swift` | `bounds`/`renderBounds`, `hitTest` (border-band + inverse-rotation), `translate`, `resized(handle:to:)` (anchors opposite corner in world space), `scaled(sx:sy:around:)` (group resize), `supportsHandleResize`. **The hit-testing + resize brain.** |
| `SelectionFrame.swift` | **(M3)** Chrome-only handle geometry derived from the selection: `.box` (single rotatable, 8 handles + rotate), `.endpoints` (line/arrow), `.group` (multi/stroke, 8 handles). `handleHit(at:tolerance:)`. |
| `Scene+Arrange.swift` | **(M3)** Z-order `reorder(_:_ :)` (front/back/forward/backward within a layer), group queries (`outerGroup`, `expandingGroups`), `align`/`distribute`. |
| `Geometry.swift` | `CGPoint`/`CGRect` helpers (`rotated`, `distanceToSegment`, `borderBandContains`, `ellipseBorderContains`, `dragFrom:to:`, `oppositeCorner`, `movingCorner`…) and the `Handle` enum. |
| `Shapes/ShapeLibrary.swift` | **(M3)** 20-entry polygon/star catalog (one data table) driving the toolbar shape picker; every entry maps onto the `polygon` kind. |
| `CanvasTransform.swift` | **The ONLY pixel↔view conversion site** (invariant 1). `toView`/`toCanvas`/`canvasTolerance`/`zoom(by:about:)`/`fit`/`actualSize`. |
| `ObjectStyle.swift` | `ObjectStyle`, `RGBAColor`, `Fill`, `DashStyle`, `ShadowSpec`. |
| `Selection.swift` | `Selection` (multi-select `Set<UUID>` + pixel region), `SelectionShape`, `FloatingPixels`, `LiftMode`. **Object multi-select wired (M3); pixel region ops are M7.** |
| `SurfaceStore.swift` | Lock-guarded `@unchecked Sendable` refcounted CGImage table. **Carries live raster pixels from M6.** `totalBytes` is the memory-budget probe (T1); `prune(keeping:)` GCs by scene+history reference, not refcount. |
| `PixelFormat.swift` | The one canonical pixel layout (BGRA premultiplied) + `makeContext` (handled-failure allocation) + `unpremultiply`. |
| `Tool.swift` | `Tool` enum + display names, SF Symbols, drag-behavior flags. |
| `Brush/Freehand.swift` | **(M6)** Perfect-freehand port: samples → a filled variable-width outline polygon. Pure, deterministic; the reason strokes are stored as samples, not paths. |
| `Brush/OneEuroFilter.swift` | **(M6)** The 1€ stabilizer (D34) — adaptive low-pass at capture time; `forStreamline` maps `brush.streamline` onto its cutoff/beta. |
| `Brush/BrushEngine.swift` | **(M6)** Six presets → `Freehand.Options`, plus the calligraphy nib fake (D35) and the Shift+B cycle order. One switch for render/hit-test/export. |

### Rendering — nonisolated (`Sources/Sketcher/Rendering/`)
| File | Purpose |
| --- | --- |
| `SceneRenderer.swift` | **The single draw routine** (invariant 2) for screen + export + cache. `drawImageYDown` (a y-flip site). Layer loop with isolated-offscreen compositing; raster layers blit their surface. Strokes fill the `BrushEngine` outline; `erasedGeometry` is punched subpath-by-subpath (D36). |
| `RenderCaches.swift` | Committed/live split. `committedImage(...)` rebuilds only on key change; `rebuildCount` is asserted by tests. |
| `ExportService.swift` | `renderFullResolution` / `renderRegion` / `renderObjects` (selection-only, for the clipboard image) + `pngData`. The export y-flip site. |
| `ObjectPaths.swift` | Pure `CGPath` construction shared by render + hit test (roundedRect, polygon/star, quad) and `ArrowGeometry` (shaft pullback + head shapes). |
| `StrokeGeometry.swift` | The capture-time sample gate (`shouldAppend`) + `fill` — one non-zero-winding fill op for a `Freehand`/`BrushEngine` outline, so the highlighter's multiply never double-darkens (T12). (M6 moved the geometry into `Model/Brush/`.) |
| `TextMetrics.swift` | CoreText measure/draw, 3-mode sizing. Screen == export by construction; the M5 editing overlay lives in `Text/` and never draws visible glyphs. |
| `CIContextProvider.swift` | **(M4)** One shared `CIContext` (linear working space) for every filter — never one per application. |
| `Redaction.swift` | **(M4)** Renders a region, blurs/pixelates it (halo-safe clamp+crop, anchored pixelate center), returns the opaque patch. |
| `PixelSampling.swift` | **(M4)** `CGImage.firstPixelUnpremultiplied` — the eyedropper's readback (invariant 10). |

### Raster — nonisolated (`Sources/Sketcher/Raster/`)
| File | Purpose |
| --- | --- |
| `RasterOps.swift` | **(M6)** The pixel-op free functions (invariant 11): `rasterizeContent`/`flatten` (through the ONE renderer, D39), `erase` (`.clear`, T15), `blank`, `materialize` (fresh-context tile crop — the T1 fix, NEVER `cropping(to:)`), `compositeTile` (apply a patch tile). Every result is a new immutable surface. |

### ViewModel — `@MainActor` (`Sources/Sketcher/ViewModel/`)
| File | Purpose |
| --- | --- |
| `EditorViewModel.swift` | The hub. Owns `scene` (with the `sceneRevision` didSet), `history`, `interaction`, `selection`, `transform`, tool + style, the live `OneEuroFilter`. Pointer handlers, commit gating, undo/redo, viewport commands. **The M5 text-editing, M6 eraser (3 modes), M6 raster-patch, and M6 layer lifecycles** all live here as same-file extensions — they mutate the file-private `scene`/`interaction`/`history`/`surfaces` like redaction does. `applyRasterPatch` composites tile diffs on undo/redo (D37). |
| `Interaction.swift` | The editing state machine (`idle`/`drawing`/`draggingObjects`/`resizing`/`rotating`/`editingText`/`marquee`/`panning`). Pointer + key handlers are its transitions. `resizing`/`rotating` carry the pre-gesture originals (M3); `editingText` is a mutating gesture bracketing a whole text session (M5). |
| `History.swift` | Snapshot undo. `begin`/`end` (push-only-if-changed), interactive-edit coalescing, `HistoryEntry` (scene \| rasterPatch), `RasterPatch` (materialized, tile-quantized — T1; **carries real pixels from M6**), byte-budget eviction (raster patches evict first, `.scene` never). |

### Input — AppKit, `@MainActor` (`Sources/Sketcher/Input/`)
| File | Purpose |
| --- | --- |
| `CanvasEventView.swift` | **The single input path** (invariant 8). NSView; pointer/keys/scroll/magnify/pressure/modifiers off one NSEvent. Converts to canvas space at the boundary. `CanvasEventLayer` bridges it into SwiftUI. |
| `PointerEvent.swift` | Reads location + pressure + tilt + modifiers off one NSEvent (tablet subtype check, T6). |
| `KeyMap.swift` | Tool-letter table, delete-key raw scalars (T7), arrow nudge, bracket brush-size. |

### Text — AppKit, `@MainActor` (`Sources/Sketcher/Text/`)
| File | Purpose |
| --- | --- |
| `TextEditingOverlay.swift` | **(M5)** `TextSinkView`: a transparent `NSTextView` used only as an IME/dictation/caret sink, glyphs drawn in clear so CoreText owns the visible text (T14, D29). Reports edits, commits on ⌘Return/Esc/resign, handles the font panel's `changeFont:`. Owned as a child of `CanvasEventView` (D31). |

### Views — SwiftUI (`Sources/Sketcher/Views/`)
| File | Purpose |
| --- | --- |
| `CanvasView.swift` | The drawing surface: workspace backdrop, artboard chrome (hairline+shadow, checkerboard), the cached-vs-live draw split, selection chrome + handles, redaction-region preview. Input overlay on top. |
| `ToolbarView.swift` | `ViewThatFits` 3-tier tool palette, shape picker, color wells + swap + swatch strip, size slider, background picker, undo/redo, zoom. Color⇄RGBAColor bridging lives here. |
| `InspectorView.swift` | **(M4)** Trailing style panel: fill, stroke width, dash, corner radius, opacity. Edits the selection or the tool defaults; sliders coalesce to one undo entry. |
| `LayersPanel.swift` | **(M6)** The layer stack (rows top→bottom): visibility/lock/rename per row, active highlight, opacity (coalesced) + blend picker, and new-vector/new-raster/duplicate/merge/delete/raise/lower/rasterize. Stacked under the inspector in the sidebar. |
| `EditorRootView.swift` | Toolbar / canvas / inspector + layers / status-bar layout + the contained/infinite and inspector toggles. |

### App shell — AppKit, `@MainActor` (`Sources/Sketcher/App/`, `Document/`, `Windows/`, `Commands/`, `Pasteboard/`, `Export/`)
| File | Purpose |
| --- | --- |
| `main.swift` | Headless early-exit into `TestRenderMode` **before** `NSApplication` (what makes the pixel harness bare-binary runnable), then the normal app. |
| `App/AppDelegate.swift` | Regular-app activation policy, builds the menu, opens the blank untitled canvas. |
| `App/Command.swift` + `CommandDispatch.swift` | **One command enum, one dispatch switch** (invariant 13). Menu/keyboard/toolbar all route here. Edit (cut/copy/paste/duplicate) + Arrange commands added in M3. |
| `App/MainMenu.swift` | Menu bar built from `Command`. Custom `performUndo:`/`performRedo:` (T8). **Arrange** (M3), **Format** (M5), **Layer** (M6) menus. |
| `Commands/LayerCommands.swift` | **(M6)** Pure `Scene` layer-stack edits (`insertLayer`/`removeLayer`/`moveLayer`); the view model brackets them and owns anything needing `SurfaceStore`. |
| `Document/SketchDocument.swift` | `@objc(SketchDocument)` NSDocument (T17). read/write via `SceneCodec`, edited-dot wiring, `isRestorable = false`. |
| `Windows/EditorWindowController.swift` | Hosts the SwiftUI view; `sizingOptions = [.minSize]`; the undo selectors. |
| `Commands/ExportCommands.swift` | Copy-canvas, `Export…` via NSSavePanel, `dragOutURL` (not yet wired to a drag source). |
| `Commands/ColorCommands.swift` | **(M4)** Screen eyedropper via `NSColorSampler` — kept out of the view model so it stays AppKit-free. |
| `Commands/FontCommands.swift` | **(M5)** Font-panel plumbing (`NSFontManager.orderFrontFontPanel`), kept out of the view model like `ColorCommands`. |
| `Pasteboard/PasteboardWriter.swift` | Writes PNG **and** TIFF, point-sized for Retina; temp-PNG for drag-out. |
| `Pasteboard/ObjectClipboard.swift` | **(M3)** Object cut/copy/paste via a private UTI (lossless `ObjectSpec` JSON) + PNG/TIFF for interop. Read is object-JSON only (external-image paste is M6/M7 — see D22). |
| `Export/ImageExporter.swift` | `CGImageDestination` wrapper (PNG/JPEG/TIFF/HEIC) + DPI stamping + decode. |
| `TestRenderMode.swift` | `--test-render` / `--test-roundtrip` / `--perf` headless entry points. |

### Persistence — nonisolated (`Sources/Sketcher/Persistence/`)
| File | Purpose |
| --- | --- |
| `SceneCodec.swift` | `encode`/`decode` + the `SceneFile`/`LayerSpec`/`ObjectSpec`/`StyleSpec` manifest. `decodeIfPresent ?? default` everywhere (additive-field forward compat). `BlendModeNames` (by name, not raw value). |
| `KindCodec.swift` | `ObjectKind` ↔ opaque `JSONValue` payload. Returns nil for unknown types → `.unknown` round-trips verbatim. |
| `GeometrySpec.swift` | Named/flat `RectSpec`/`PointSpec`/`SizeSpec`/`VectorSpec` (D17 — CoreGraphics `Codable` is positional and opaque). |
| `JSONValue.swift` | Any-JSON value for round-tripping unknown payloads. |

### Build + test scripts (`scripts/`, `Tests/`)
| File | Purpose |
| --- | --- |
| `scripts/bundle.sh` | Hand-assembles `dist/Sketcher.app`, ad-hoc signs, `plutil -lint`. |
| `scripts/Info.plist` | Bundle id, document type. Comment marks the M8 flip to `LSTypeIsPackage`. |
| `scripts/verify-render.{sh,swift}` + `make-fixture.swift` | The pixel-fidelity harness (21 assertions) + its fixtures. |
| `Tests/SketcherTests/` | `GeometryTests`, `HistoryTests` (+ `EditorViewModelTests`), `CodecTests`, `RenderCacheTests` (+ `ExportTests`), `SelectionArrangeTests` (M3), `ColorRedactionTests` (M4), `TextEditingTests` (M5), `BrushRasterTests` (M6: Freehand geometry, 1€ filter, brush presets), `RasterLayerTests` (M6: **T1 memory budget**, raster undo round-trip, layers, eraser modes, overlap-erase, opacity isolation). **139 tests.** |

### Not yet created (planned, per milestone)
`Model/Shapes/*` + `Grouping`/`HitTest`/`Handles` as separate files (M3 — currently
inline) · `Tools/*` per-tool files (the tools live in `EditorViewModel` extensions) ·
`Persistence/SceneFile`/`PackageIO` package format (M8) · `Model/{SelectionShape,
FloatingPixels}` fleshed out + `Raster/{FloodFill,MaskTrace,MaskOps}` + `Rendering/
MarchingAnts` (M7) · `Views/{CheckerboardView,ZoomControl}` (inline). The current
layout collapses several planned files into fewer; that is tracked in §1 and is not
a problem to fix, just a note so the plan's file list isn't taken literally. (M6's
`Model/Brush/*` landed as three files as planned; `History+RasterPatch` folded into
`EditorViewModel`/`History` for file-private access; `LayerCommands` is a pure
`Scene` extension with the stateful half in the view model.)
