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

**Where it stands (2026-07-22):** M1 done, **M2 ~90% done**. The app builds
warning-clean, launches to a blank canvas you can draw on, and has **54 unit
tests + 21 pixel assertions all green**. The single biggest open question — can
SwiftUI `Canvas` hold frame rate — has been **answered and resolved** (§7): the
render cache is mandatory and it works. Nothing is blocked.

**Nothing is committed.** `git log` shows only the upstream "Initial commit"; the
entire app is uncommitted in the working tree. First action on resuming should
probably be a commit (the user controls when — don't commit unprompted).

### Resume in 60 seconds

```sh
cd /Users/phamqm/Projects/sketcher
make test      # 54 tests — must be green before you touch anything
make verify    # 21 pixel assertions through the real export pipeline
make run       # launches dist/Sketcher.app — draw a stroke to sanity-check
.build/release/Sketcher --perf   # re-run the perf gate if you touch rendering
```

Read order for a new agent: this section → §8 (file map) → `CLAUDE.md` (the 15
invariants) → §2 (decisions) → §3/§4 (traps + bugs) before editing.

### What to do next (M2 close-out, then M3)

**Finish M2** (small — see the "Still open for M2" checklist in §1):
- Wire **drag-out**: `ExportCommands.dragOutURL` already renders the PNG; it needs
  an `NSItemProvider` drag source on a toolbar handle. No new model work.
- Export **options** (1×/2×/3×, page vs selection, transparency): today `Export…`
  writes the page at 1×. `ExportService.renderRegion` already exists for selection.

**Then M3 — shapes, multi-select, handles, clipboard, arrange.** Much is already
scaffolded (see §1 "pulled forward"): `Selection` (multi-select `Set<UUID>`),
`Handle` geometry, `DrawObject.resized(handle:to:)`, and marquee-by-intersection
all exist. M3 is mostly: draw the resize/rotate handles as chrome, wire pointer
hits on them into `Interaction.resizing`/`.rotating`, add object `⌘C`/`⌘V` via a
private UTI, and the arrange commands (group, z-order, align, nudge). The plan of
record has the full M3 spec.

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
| M3 | Shapes, multi-select, handles, clipboard, arrange | ☐ | |
| M4 | Color system, style inspector, blur redaction | ☐ | |
| M5 | Multiline text | ☐ | |
| M6 | Raster layers, brush engine, erasers, layers panel, raster undo | ☐ | |
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
| T15 | `.destinationOut` on an opaque context | Eraser paints white instead of clearing to alpha 0 | Raster layers are always premultiplied-with-alpha. |
| T16 | Even-odd clip for accumulated eraser strokes | Overlapping eraser strokes **un-erase** in the overlap | `CGPath.subtracting` (native, macOS 13+). |
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
- **Infinite mode + raster layers** — a raster layer is bounded by the page rect. Painting outside the page in infinite mode is currently undefined; decide at M6 whether raster layers grow, clip, or refuse.
- **Layer count cap** — 16 is the planned ceiling for memory reasons. Revisit once real documents exist.

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

41 source files, ~5.9k lines; 4 test files, ~1k lines. Layered strictly:
**Model → Rendering → ViewModel → Input/Views/App**. The dependency arrow never
points backwards — Model knows nothing of AppKit, and nothing below the view
layer knows about points or zoom (invariant 1).

### Model — pure value types, nonisolated (`Sources/Sketcher/Model/`)
| File | Purpose |
| --- | --- |
| `Scene.swift` | `Scene` (the whole undoable document), `CanvasSpec`, `CanvasMode`, `CanvasBackground` (with `defaultInk`), `PixelSize`, `Guide`. The one type snapshotted for undo. |
| `Layer.swift` | `Layer`, `LayerContent` (`.vector([DrawObject])` / `.raster(SurfaceID)`), `SurfaceID`. |
| `DrawObject.swift` | `DrawObject`, `ObjectKind` (the full tagged union), and every payload (`StrokePayload`/`StrokeSample`, `ArrowPayload`, `TextPayload`, `RasterPayload`, `FilterPayload`, `PathGeometry`). Hand-written `Codable` where the format needs to stay clean. |
| `DrawObject+Geometry.swift` | `bounds`/`renderBounds`, `hitTest` (border-band + inverse-rotation), `translate`, `resized(handle:to:)` (anchors opposite corner in world space). **The hit-testing + resize brain.** |
| `Geometry.swift` | `CGPoint`/`CGRect` helpers (`rotated`, `distanceToSegment`, `borderBandContains`, `ellipseBorderContains`, `dragFrom:to:`…) and the `Handle` enum. |
| `CanvasTransform.swift` | **The ONLY pixel↔view conversion site** (invariant 1). `toView`/`toCanvas`/`canvasTolerance`/`zoom(by:about:)`/`fit`/`actualSize`. |
| `ObjectStyle.swift` | `ObjectStyle`, `RGBAColor`, `Fill`, `DashStyle`, `ShadowSpec`. |
| `Selection.swift` | `Selection` (multi-select `Set<UUID>` + pixel region), `SelectionShape`, `FloatingPixels`, `LiftMode`. **Scaffolded for M3/M7; region ops not wired yet.** |
| `SurfaceStore.swift` | Lock-guarded `@unchecked Sendable` refcounted CGImage table. `totalBytes` is the M6 memory-budget probe. |
| `PixelFormat.swift` | The one canonical pixel layout (BGRA premultiplied) + `makeContext` (handled-failure allocation) + `unpremultiply`. |
| `Tool.swift` | `Tool` enum + display names, SF Symbols, drag-behavior flags. |

### Rendering — nonisolated (`Sources/Sketcher/Rendering/`)
| File | Purpose |
| --- | --- |
| `SceneRenderer.swift` | **The single draw routine** (invariant 2) for screen + export + cache. `drawImageYDown` (a y-flip site). Layer loop with isolated-offscreen compositing. |
| `RenderCaches.swift` | Committed/live split. `committedImage(...)` rebuilds only on key change; `rebuildCount` is asserted by tests. |
| `ExportService.swift` | `renderFullResolution` / `renderRegion` (both clip to the page rect) + `pngData`. The export y-flip site. |
| `ObjectPaths.swift` | Pure `CGPath` construction shared by render + hit test (roundedRect, polygon/star, quad) and `ArrowGeometry` (shaft pullback + head shapes). |
| `StrokeGeometry.swift` | Midpoint-quadratic smoothing + one-op polyline stroke (single point → filled ellipse). **M6 replaces the outline with a perfect-freehand port.** |
| `TextMetrics.swift` | CoreText measure/draw, 3-mode sizing. **M5 adds the editing overlay.** |

### ViewModel — `@MainActor` (`Sources/Sketcher/ViewModel/`)
| File | Purpose |
| --- | --- |
| `EditorViewModel.swift` | The hub. Owns `scene` (with the `sceneRevision` didSet), `history`, `interaction`, `selection`, `transform`, tool + style. Pointer handlers, commit gating, undo/redo, viewport commands. |
| `Interaction.swift` | The editing state machine (`idle`/`drawing`/`draggingObjects`/`resizing`/`rotating`/`marquee`/`panning`/…). Pointer + key handlers are its transitions. |
| `History.swift` | Snapshot undo. `begin`/`end` (push-only-if-changed), interactive-edit coalescing, `HistoryEntry` (scene | rasterPatch), `RasterPatch` (materialized, tile-quantized — T1), eviction budget. |

### Input — AppKit, `@MainActor` (`Sources/Sketcher/Input/`)
| File | Purpose |
| --- | --- |
| `CanvasEventView.swift` | **The single input path** (invariant 8). NSView; pointer/keys/scroll/magnify/pressure/modifiers off one NSEvent. Converts to canvas space at the boundary. `CanvasEventLayer` bridges it into SwiftUI. |
| `PointerEvent.swift` | Reads location + pressure + tilt + modifiers off one NSEvent (tablet subtype check, T6). |
| `KeyMap.swift` | Tool-letter table, delete-key raw scalars (T7), arrow nudge, bracket brush-size. |

### Views — SwiftUI (`Sources/Sketcher/Views/`)
| File | Purpose |
| --- | --- |
| `CanvasView.swift` | The drawing surface: workspace backdrop, artboard chrome (hairline+shadow, checkerboard), the cached-vs-live draw split, selection chrome. Input overlay on top. |
| `ToolbarView.swift` | `ViewThatFits` 3-tier tool palette, color well, size slider, background picker, undo/redo, zoom. Color⇄RGBAColor bridging lives here. |
| `EditorRootView.swift` | Toolbar / canvas / status-bar layout + the contained/infinite toggle. |

### App shell — AppKit, `@MainActor` (`Sources/Sketcher/App/`, `Document/`, `Windows/`, `Commands/`, `Pasteboard/`, `Export/`)
| File | Purpose |
| --- | --- |
| `main.swift` | Headless early-exit into `TestRenderMode` **before** `NSApplication` (what makes the pixel harness bare-binary runnable), then the normal app. |
| `App/AppDelegate.swift` | Regular-app activation policy, builds the menu, opens the blank untitled canvas. |
| `App/Command.swift` + `CommandDispatch.swift` | **One command enum, one dispatch switch** (invariant 13). Menu/keyboard/toolbar all route here. |
| `App/MainMenu.swift` | Menu bar built from `Command`. Custom `performUndo:`/`performRedo:` (T8). |
| `Document/SketchDocument.swift` | `@objc(SketchDocument)` NSDocument (T17). read/write via `SceneCodec`, edited-dot wiring, `isRestorable = false`. |
| `Windows/EditorWindowController.swift` | Hosts the SwiftUI view; `sizingOptions = [.minSize]`; the undo selectors. |
| `Commands/ExportCommands.swift` | Copy-canvas, `Export…` via NSSavePanel, `dragOutURL` (not yet wired to a drag source). |
| `Pasteboard/PasteboardWriter.swift` | Writes PNG **and** TIFF, point-sized for Retina; temp-PNG for drag-out. |
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
| `Tests/SketcherTests/` | `GeometryTests`, `HistoryTests` (+ `EditorViewModelTests`), `CodecTests`, `RenderCacheTests` (+ `ExportTests`). 54 tests. |

### Not yet created (planned, per milestone)
`Model/Brush/*` + `Raster/*` (M6) · `Model/Shapes/*` + `Grouping`/`HitTest`/`Handles`
as separate files (M3 — currently inline) · `Text/*` editing overlay (M5) ·
`Tools/*` per-tool files (M3+) · `Persistence/SceneFile`/`PackageIO` package format
(M8) · `Views/{CheckerboardView,ZoomControl,LayersPanel,InspectorView}` (inline or
later). The current layout collapses several planned files into fewer; that is
tracked in §1 and is not a problem to fix, just a note so the plan's file list
isn't taken literally.
