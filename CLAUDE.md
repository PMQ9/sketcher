# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## What this is

A lightweight native macOS sketching app: blank canvas, Paint-class pixel tools,
Excalidraw-class vector editing. Swift 6 + SwiftUI + CoreGraphics/CoreImage,
**no third-party dependencies, no Xcode project**. An `NSDocument`-based regular
windowed app — not a menu-bar accessory.

Progress, decisions, known traps, and the bug log live in [PROGRESS.md](PROGRESS.md).
Read it before starting work; update it in the same commit as the work.

## Build / run / test

Requires macOS 15+ and the Xcode **Command Line Tools only** — full Xcode and
`xcodebuild` are never used and there is no `.xcodeproj`. SwiftPM drives
everything, wrapped by the Makefile and `scripts/`.

```sh
make run        # build debug, bundle dist/Sketcher.app, launch
make run-fg     # same, but foreground so logs stream to the terminal (dev loop)
make release    # optimized build + bundle
make app        # bundle only, no launch
make test       # unit tests — USE THIS, not `swift test` (see below)
make verify     # end-to-end pixel-fidelity check (from M2)
make clean
swift build -c debug        # compile only, no bundle
```

**Always run tests with `make test`, never bare `swift test`.** The Command Line
Tools ship `Testing.framework` outside the default search paths, so `make test`
injects framework and rpath flags (`TEST_FLAGS` in the [Makefile](Makefile));
plain `swift test` fails with `no such module 'Testing'`. **Both** rpaths are
required — without the second, the build succeeds and the test binary dies at
launch.

There is no linter or formatter configured. Keep `swift build` warning-clean.

## Non-negotiable architecture invariants

These are the load-bearing decisions. Most bugs in a drawing app come from
violating one. Preserve them.

**1. One coordinate space below the view layer: canvas pixels, top-left origin,
y-down.** All geometry in [Model/](Sources/Sketcher/Model/),
[ViewModel/](Sources/Sketcher/ViewModel/), and
[Rendering/](Sources/Sketcher/Rendering/) is in canvas pixels. Nothing below the
view layer knows about points, screen scale, or zoom.
[CanvasTransform](Sources/Sketcher/Model/CanvasTransform.swift) is the ONLY place
pixel↔view conversion happens; gestures, hit tolerance, overlay positions, and
canvas drawing all route through it. No other code multiplies by a scale factor.
Conversion happens exactly at the event boundary in
[CanvasEventView](Sources/Sketcher/Input/CanvasEventView.swift). *This is what
keeps the renderer swappable in one file.*

**2. One renderer for screen and export — they cannot diverge.**
[SceneRenderer](Sources/Sketcher/Rendering/SceneRenderer.swift)`.draw` is the
single draw routine for document content. The on-screen `Canvas` calls it inside
`withCGContext`; export calls it into a bitmap context at exact pixel dimensions;
the committed cache builder calls it into its own. Never add a screen-only or
export-only draw path. Chrome (handles, marching ants, guides, grid, brush ring,
the transparency checkerboard) is drawn in the SwiftUI overlay ONLY and must never
appear in an export — this is pixel-asserted.

**3. Three y-flip sites plus one Core Image boundary.** The renderer's contract is
y-down, but CoreGraphics and CoreImage are y-up. Flipping is isolated to
`CGContext.drawImageYDown`, the export context's initial flip, the
rasterize/flatten flip — and `CanvasTransform.ciVector(forCanvasPoint:in:)`,
through which every center-parameterized CIFilter routes. Do not add ad-hoc flips.

**4. `Scene` contains content only.** Selection, active tool, viewport transform,
interaction state, editing-group path, and color slots live on
[EditorViewModel](Sources/Sketcher/ViewModel/EditorViewModel.swift) and are NEVER
snapshotted. `Scene` is a value type, and `Scene ==` is what `endGesture()`'s
push-only-if-changed check depends on.

**5. Raster pixels never live in `Scene`.** Layers hold `SurfaceID` handles into a
refcounted [SurfaceStore](Sources/Sketcher/Model/SurfaceStore.swift). This is what
keeps a `.scene` history entry kilobytes even in a five-raster-layer document, and
it is why `.scene` entries are never evicted.

**6. Raster surfaces are immutable.** Every pixel operation produces a NEW
`CGImage` registered as a new surface. History patches must be **materialized**
into fresh bitmap contexts — `CGImage.cropping(to:)` does not copy pixels, it
retains the entire parent, so a naive dirty-rect patch secretly pins the whole
canvas.

**7. The gesture bracket is sacred.** `begin()`/`end()` in
[History](Sources/Sketcher/ViewModel/History.swift) bracket everything; `end()`
pushes ONLY if the scene actually changed. `⌘Z` mid-gesture **aborts the gesture**
(restoring the snapshot) rather than popping history — the next `⌘Z` pops.
History-mutating actions are refused unless `interaction.isMutatingGesture` is
false. `beginInteractive()`/`endInteractive()` coalesce slider drags into one
entry. Every entry is **named**, so a History panel comes free.

**8. All input comes through `CanvasEventView`.** Pointer, keys, scroll, magnify,
pressure, tilt, and modifiers are all captured on the SAME `NSEvent`, which
eliminates the modifier race entirely. SwiftUI's `DragGesture` exposes no
pressure, no tilt, no scroll, and no per-event modifiers, and it coalesces
samples — it is not an option. Any SwiftUI `.onKeyPress` is dead code and must be
deleted. Menu key equivalents are the one exception, and they own every Command
combination.

**9. Redaction is destructive at commit** and leaves nothing recoverable — not in
the render, not in the save file. Asserted by a pixel test *and* a file-content
test. (M4.)

**10. One canonical pixel format**, declared once in
[PixelFormat](Sources/Sketcher/Model/PixelFormat.swift) and asserted at every raw
buffer entry point: 8 bits/component, `premultipliedFirst | byteOrder32Little`
(BGRA), canvas color space. Tolerance and eyedropper comparisons happen on
**un-premultiplied** values.

**11. The data layer is nonisolated; the UI layer is `@MainActor`.** This package
deliberately does NOT set `.defaultIsolation(MainActor.self)` — see the comment in
[Package.swift](Package.swift). Model, Rendering, and Persistence are pure data
and must be callable off-main; flood fill, magic wand, CIFilter application, and
PNG encode all block the UI otherwise. Mark UI types `@MainActor` explicitly.

**12. Determinism is testable.** No `hashValue` anywhere a value crosses a process
boundary or feeds an RNG or a cache key — Swift's `Hasher` is per-process seeded.
Use UUID raw bytes or `CryptoKit.SHA256`.

**13. One `Command` enum, one dispatch switch.** Menu bar, context menu, toolbar,
and keyboard all route through [Command](Sources/Sketcher/App/Command.swift) and
[CommandDispatch](Sources/Sketcher/App/CommandDispatch.swift). At this tool count
that is the difference between one maintainable app and four diverging copies of
the feature list — and it makes macOS's Help-menu search a free command palette.

**14. Prove behavior in bytes.** Every rendering or raster change ships with a
pixel assertion through the real export pipeline, or a byte-budget assertion on
`SurfaceStore.totalBytes`. Assert pixel values and population counts at known
coordinates, **never image hashes**. Cache-vs-cold comparisons assert *bounded
difference*, not byte equality.

**15. Always `make test`, never bare `swift test`.**

## Structural notes

- **Editing is an explicit state machine.** The `Interaction` enum in
  [Interaction.swift](Sources/Sketcher/ViewModel/Interaction.swift) is the single
  source of truth; pointer and keyboard handlers are its transitions.
  `resizing`/`rotating` carry the ORIGINAL objects so every frame recomputes from
  them rather than accumulating float drift.
- **Units convert at the UI boundary.** Stroke width and font size are
  point-denominated in the UI and multiplied by `pixelsPerPoint` when written into
  the model. `CanvasSpec.px(fromPoints:)` is the only place that multiplication is
  allowed outside `CanvasTransform`.
- **Hit testing uses the border band, not the interior**, so an unfilled shape can
  be clicked through. Filled shapes also hit their interior. Rotation is handled by
  inverse-transforming the probe point into the shape's local frame — one line at
  the top of `hitTest` covers every rotated kind.
- **Marquee selects by intersection** (touching is enough), matching Figma, Sketch,
  and Illustrator. That deliberately differs from click hit-testing.
- **Forward compatibility is built in.** Every `Codable` init uses
  `decodeIfPresent ?? default`, so adding a field never bumps `formatVersion`. An
  object with an unrecognized `type` keeps its payload as an opaque `JSONValue`,
  renders as nothing, and re-encodes byte-identically. Enums in the file format are
  string-backed — a case-only enum synthesizes as `{"solid":{}}` and an enum with
  associated values as `{"solid":{"_0":…}}`, and `_0` would be a compiler artifact
  baked into the format forever.
- **Swift 6, strict.** `swift-tools-version: 6.2`, language mode v6. Expect full
  concurrency checking.

## Milestones

v1 is M1–M8; see [PROGRESS.md](PROGRESS.md) for status and the full plan. Each
milestone is independently runnable — never leave the app in a state where
`make run` does not produce a usable window.
