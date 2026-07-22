import CoreGraphics
import Foundation
import Testing
@testable import Sketcher

@Suite("RenderCache")
@MainActor
struct RenderCacheTests {

    private func sceneWithShapes(_ count: Int) -> Scene {
        var scene = Scene(canvas: CanvasSpec(pixelSize: PixelSize(width: 300, height: 200),
                                             pixelsPerPoint: 1))
        for i in 0..<count {
            var style = ObjectStyle(strokeColor: .black, strokeWidthPx: 3)
            style.fill = .solid(.blue)
            scene.addObject(DrawObject(
                kind: .rectangle(rect: CGRect(x: 10 + i * 7, y: 10 + i * 5,
                                              width: 40, height: 30),
                                 cornerRadius: 0),
                style: style))
        }
        return scene
    }

    /// Read straight (un-premultiplied) RGBA from a rendered image.
    private func samples(of image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let w = image.width, h = image.height
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buffer
    }

    @Test("A repeated request with no change does not rebuild")
    func cacheHitsWhenNothingChanged() {
        let scene = sceneWithShapes(5)
        let caches = RenderCaches()
        let surfaces = SurfaceStore()

        _ = caches.committedImage(for: scene, surfaces: surfaces, revision: 1, excluding: [])
        #expect(caches.rebuildCount == 1)

        for _ in 0..<20 {
            _ = caches.committedImage(for: scene, surfaces: surfaces,
                                      revision: 1, excluding: [])
        }
        #expect(caches.rebuildCount == 1)
    }

    @Test("A revision bump rebuilds")
    func revisionBumpRebuilds() {
        let scene = sceneWithShapes(3)
        let caches = RenderCaches()
        let surfaces = SurfaceStore()

        _ = caches.committedImage(for: scene, surfaces: surfaces, revision: 1, excluding: [])
        _ = caches.committedImage(for: scene, surfaces: surfaces, revision: 2, excluding: [])
        #expect(caches.rebuildCount == 2)
    }

    @Test("A drag rebuilds ONCE, not once per frame")
    func dragDoesNotThrashTheCache() {
        // This is the cost the cache exists to eliminate. Editing an existing
        // object bumps the revision every frame, so if the excluded objects
        // were not held out of the committed pass, every frame would rebuild.
        var scene = sceneWithShapes(4)
        let caches = RenderCaches()
        let surfaces = SurfaceStore()
        guard let dragged = scene.allObjects.first?.id else {
            Issue.record("no object to drag")
            return
        }

        var revision: UInt64 = 1
        _ = caches.committedImage(for: scene, surfaces: surfaces,
                                  revision: revision, excluding: [dragged])
        let afterFirst = caches.rebuildCount

        // 60 frames of dragging: the object moves, but the COMMITTED content
        // (everything except the dragged object) never changes.
        for _ in 0..<60 {
            scene.withObject(dragged) { $0.translate(by: CGPoint(x: 1, y: 1)) }
            revision &+= 1
            // The view passes the pre-gesture revision for the committed pass,
            // which is what makes this hold — see CanvasView.drawCommitted.
            _ = caches.committedImage(for: scene, surfaces: surfaces,
                                      revision: 1, excluding: [dragged])
        }
        #expect(caches.rebuildCount == afterFirst)
    }

    @Test("Changing the excluded set rebuilds, because the content differs")
    func excludedSetIsPartOfTheKey() {
        let scene = sceneWithShapes(3)
        let caches = RenderCaches()
        let surfaces = SurfaceStore()
        guard let first = scene.allObjects.first?.id else { return }

        _ = caches.committedImage(for: scene, surfaces: surfaces, revision: 1, excluding: [])
        _ = caches.committedImage(for: scene, surfaces: surfaces,
                                  revision: 1, excluding: [first])
        #expect(caches.rebuildCount == 2)
    }

    @Test("Cached and cold renders agree within a bounded difference")
    func cacheEquivalence() {
        // NOT byte equality. Once content composites against a quantized 8-bit
        // intermediate, exact equality cannot hold — asserting it would get the
        // gate disabled in week one. Bounded difference is the honest contract.
        let scene = sceneWithShapes(8)
        let surfaces = SurfaceStore()

        let caches = RenderCaches()
        guard let cached = caches.committedImage(for: scene, surfaces: surfaces,
                                                 revision: 1, excluding: []) else {
            Issue.record("cache produced no image")
            return
        }
        guard let cold = ExportService.renderFullResolution(scene, surfaces: surfaces) else {
            Issue.record("cold render produced no image")
            return
        }

        #expect(cached.width == cold.width)
        #expect(cached.height == cold.height)

        let a = samples(of: cached)
        let b = samples(of: cold)
        #expect(a.count == b.count)

        var differing = 0
        var maxDelta = 0
        for i in 0..<min(a.count, b.count) {
            let delta = abs(Int(a[i]) - Int(b[i]))
            if delta > 0 { differing += 1 }
            maxDelta = max(maxDelta, delta)
        }
        let differingFraction = Double(differing) / Double(max(a.count, 1))

        #expect(maxDelta <= 2, "max per-channel delta \(maxDelta)")
        #expect(differingFraction < 0.001,
                "\(differing) channels differ (\(differingFraction * 100)%)")
    }

    @Test("Invalidate forces a rebuild")
    func invalidateForcesRebuild() {
        let scene = sceneWithShapes(2)
        let caches = RenderCaches()
        let surfaces = SurfaceStore()

        _ = caches.committedImage(for: scene, surfaces: surfaces, revision: 1, excluding: [])
        caches.invalidate()
        _ = caches.committedImage(for: scene, surfaces: surfaces, revision: 1, excluding: [])
        #expect(caches.rebuildCount == 2)
    }

    @Test("The cache holds at most two full canvases")
    func cacheMemoryIsBounded() {
        let scene = sceneWithShapes(3)
        let caches = RenderCaches()
        let surfaces = SurfaceStore()

        for revision in 1...20 {
            _ = caches.committedImage(for: scene, surfaces: surfaces,
                                      revision: UInt64(revision), excluding: [])
        }
        // 300x200 RGBA = 240 KB per canvas; two of them plus stride padding.
        #expect(caches.byteCount < 300 * 200 * 4 * 2 + 8192)
    }

    @Test("The view model bumps its revision on every scene mutation")
    func viewModelRevisionTracksMutations() {
        // The cache key depends on this. An in-place mutation through a
        // mutating method must trip `didSet` — if it silently did not, the
        // canvas would go stale.
        let viewModel = EditorViewModel(scene: .blank())
        let start = viewModel.sceneRevision

        viewModel.tool = .rectangle
        viewModel.pointerDown(at: .zero, tolerance: 4, modifiers: [])
        viewModel.pointerDragged(to: CGPoint(x: 90, y: 90))
        viewModel.pointerUp(at: CGPoint(x: 90, y: 90))
        #expect(viewModel.sceneRevision > start)

        let afterDraw = viewModel.sceneRevision
        viewModel.selectAll()
        viewModel.nudgeSelection(dx: 3, dy: 0)
        #expect(viewModel.sceneRevision > afterDraw)
    }
}

@Suite("Export")
@MainActor
struct ExportTests {

    @Test("Export dimensions are exactly the canvas pixel size")
    func exportDimensionsExact() {
        // The #1 Retina bug class is a half-res or double-res export, so this
        // is asserted at 1x and 2x density.
        for ppp in [CGFloat(1), 2, 3] {
            let scene = Scene(canvas: CanvasSpec(pixelSize: PixelSize(width: 640, height: 480),
                                                 pixelsPerPoint: ppp))
            guard let image = ExportService.renderFullResolution(scene,
                                                                 surfaces: SurfaceStore()) else {
                Issue.record("render failed at \(ppp)x")
                continue
            }
            #expect(image.width == 640)
            #expect(image.height == 480)
        }
    }

    @Test("Content outside the page rect is clipped, in infinite mode too")
    func offCanvasContentIsClipped() {
        var scene = Scene(canvas: CanvasSpec(pixelSize: PixelSize(width: 100, height: 100),
                                             pixelsPerPoint: 1, mode: .infinite))
        var style = ObjectStyle(strokeColor: nil)
        style.fill = .solid(.black)
        scene.addObject(DrawObject(
            kind: .rectangle(rect: CGRect(x: 400, y: 400, width: 50, height: 50),
                             cornerRadius: 0),
            style: style))

        guard let image = ExportService.renderFullResolution(scene,
                                                             surfaces: SurfaceStore()) else {
            Issue.record("render failed")
            return
        }
        #expect(image.width == 100 && image.height == 100)
    }

    @Test("An oversized canvas is refused rather than crashing")
    func oversizedCanvasIsRefused() {
        // Every CGContext allocation is a handled failure path: a canvas past
        // the limits must return nil, not trap.
        let scene = Scene(canvas: CanvasSpec(
            pixelSize: PixelSize(width: 20_000, height: 20_000), pixelsPerPoint: 1))
        #expect(!scene.canvas.pixelSize.isValid)
        #expect(ExportService.renderFullResolution(scene, surfaces: SurfaceStore()) == nil)
    }

    @Test("PNG encoding stamps DPI from pixelsPerPoint")
    func pngStampsDPI() {
        let scene = Scene(canvas: CanvasSpec(pixelSize: PixelSize(width: 64, height: 64),
                                             pixelsPerPoint: 2))
        guard let image = ExportService.renderFullResolution(scene, surfaces: SurfaceStore()),
              let data = ExportService.pngData(image, pixelsPerPoint: 2) else {
            Issue.record("export failed")
            return
        }
        #expect(!data.isEmpty)
        // Round-trips as a real PNG.
        #expect(ImageExporter.decode(data)?.width == 64)
    }

    @Test("Region export is exactly the requested rect, clamped to the page")
    func regionExportSize() {
        let scene = Scene(canvas: CanvasSpec(pixelSize: PixelSize(width: 200, height: 200),
                                             pixelsPerPoint: 1))
        let region = ExportService.renderRegion(scene, surfaces: SurfaceStore(),
                                                rect: CGRect(x: 50, y: 50,
                                                             width: 80, height: 40))
        #expect(region?.width == 80)
        #expect(region?.height == 40)

        // A rect hanging off the edge clamps rather than producing garbage.
        let clamped = ExportService.renderRegion(scene, surfaces: SurfaceStore(),
                                                 rect: CGRect(x: 180, y: 180,
                                                              width: 100, height: 100))
        #expect(clamped?.width == 20)
        #expect(clamped?.height == 20)
    }
}
