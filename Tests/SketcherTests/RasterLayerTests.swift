import CoreGraphics
import Foundation
import Testing
@testable import Sketcher

/// A small transparent canvas whose one layer has been rasterized from a filled
/// red square at (100,100)-(300,300) — a raster layer with real pixels to edit.
@MainActor
private func rasterVM(side: Int = 512) -> EditorViewModel {
    var scene = Scene(canvas: CanvasSpec(pixelSize: PixelSize(width: side, height: side),
                                         background: .transparent))
    var style = ObjectStyle(strokeColor: nil)
    style.fill = .solid(.red)
    scene.addObject(DrawObject(
        kind: .rectangle(rect: CGRect(x: 100, y: 100, width: 200, height: 200), cornerRadius: 0),
        style: style))
    let vm = EditorViewModel(scene: scene)
    vm.rasterizeActiveLayer()
    return vm
}

@MainActor
private func erasePixels(_ vm: EditorViewModel, at p: CGPoint, size: CGFloat = 60) {
    vm.tool = .eraser
    vm.eraserMode = .pixel
    var brush = vm.brush; brush.sizePx = size
    vm.commitEraserStroke(StrokePayload(samples: [StrokeSample(point: p)], brush: brush))
}

// MARK: - Raster undo memory (T1, the project-killer)

@Suite("M6 Raster undo memory")
@MainActor
struct RasterUndoMemoryTests {
    @Test("A raster patch stores tile crops, not full canvases")
    func patchIsTileSized() {
        let vm = rasterVM()
        let baseBytes = vm.surfaces.totalBytes          // one full canvas surface
        erasePixels(vm, at: CGPoint(x: 200, y: 200))
        let afterOne = vm.surfaces.totalBytes
        // The live surface is one full canvas again; the patch adds only its two
        // tile crops. Both tiles together MUST be smaller than a full canvas — if
        // the patch stored whole surfaces (or `cropping(to:)` pinned them), this
        // delta would exceed a full canvas.
        #expect(afterOne - baseBytes < baseBytes)
    }

    @Test("Fifty raster strokes stay far under budget")
    func fiftyStrokesBounded() {
        let vm = rasterVM()
        for i in 0..<40 {
            let x = CGFloat(120 + (i % 8) * 22)
            let y = CGFloat(120 + (i / 8) * 22)
            erasePixels(vm, at: CGPoint(x: x, y: y), size: 30)
        }
        // 40 raster patches (plus the one Rasterize scene entry from the helper).
        #expect(vm.history.undoStack.filter(\.isRaster).count == 40)
        // Correct (tile diffs): ~1 MB live + ~40×2 tiles ≈ under 25 MB.
        // Storing full before/after surfaces would be ~80 MB.
        #expect(vm.surfaces.totalBytes < 30 * 1024 * 1024)
    }

    @Test("A scene entry stays kilobytes even with five raster layers")
    func sceneEntryIsKilobytes() {
        var scene = Scene(canvas: CanvasSpec(pixelSize: PixelSize(width: 256, height: 256)))
        let store = SurfaceStore()
        for _ in 0..<5 {
            let id = store.register(RasterOps.blank(scene.canvas)!)
            scene.layers.append(Layer(name: "R", content: .raster(id)))
        }
        #expect(scene.referencedSurfaceIDs.count == 5)
        // The SurfaceID indirection is the whole point: the history entry is a
        // handle bundle, not pixels, regardless of how many rasters exist.
        #expect(HistoryEntry.scene(scene, name: "x").byteCount < 8192)
    }
}

// MARK: - Raster undo correctness

@Suite("M6 Raster undo")
@MainActor
struct RasterUndoTests {
    @Test("Pixel erase clears alpha, and undo/redo round-trips the pixels")
    func eraseUndoRedo() {
        let vm = rasterVM()
        let center = CGPoint(x: 200, y: 200)

        #expect((vm.sampleCanvas(at: center)?.a ?? 0) > 0.5)   // red, opaque
        erasePixels(vm, at: center)
        #expect((vm.sampleCanvas(at: center)?.a ?? 1) < 0.5)   // cleared

        vm.undo()
        #expect((vm.sampleCanvas(at: center)?.a ?? 0) > 0.5)   // restored
        vm.redo()
        #expect((vm.sampleCanvas(at: center)?.a ?? 1) < 0.5)   // re-erased
    }

    @Test("Erasing on a transparent canvas yields alpha 0, never white")
    func eraseIsTransparentNotWhite() {
        let vm = rasterVM()
        erasePixels(vm, at: CGPoint(x: 200, y: 200))
        guard let sample = vm.sampleCanvas(at: CGPoint(x: 200, y: 200)) else {
            Issue.record("sample failed"); return
        }
        #expect(sample.a < 0.1)   // the classic eraser bug is white (a=1) here
    }
}

// MARK: - Layers

@Suite("M6 Layers")
@MainActor
struct LayerTests {
    @Test("New layer adds one, is active, and undoes cleanly")
    func newLayer() {
        let vm = EditorViewModel(scene: .blank())
        vm.addVectorLayer()
        #expect(vm.layers.count == 2)
        #expect(vm.activeLayerID == vm.layers.last?.id)
        vm.undo()
        #expect(vm.layers.count == 1)
    }

    @Test("A new raster layer carries a real surface")
    func newRasterLayer() {
        let vm = EditorViewModel(scene: .blank(pixelSize: PixelSize(width: 128, height: 128)))
        vm.addRasterLayer()
        #expect(vm.activeLayer?.isRaster == true)
        if case .raster(let id) = vm.activeLayer?.content {
            #expect(vm.surfaces.image(id) != nil)
        } else {
            Issue.record("active layer is not raster")
        }
    }

    @Test("The last layer cannot be deleted")
    func cannotDeleteLastLayer() {
        let vm = EditorViewModel(scene: .blank())
        vm.deleteActiveLayer()
        #expect(vm.layers.count == 1)
    }

    @Test("Duplicating a vector layer copies its objects with fresh ids")
    func duplicateVectorLayer() {
        var scene = Scene.blank()
        scene.addObject(DrawObject(kind: .ellipse(rect: CGRect(x: 0, y: 0, width: 20, height: 20)),
                                   style: ObjectStyle()))
        let vm = EditorViewModel(scene: scene)
        vm.duplicateActiveLayer()
        #expect(vm.layers.count == 2)
        let ids = vm.scene.allObjects.map(\.id)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)   // distinct identities
    }

    @Test("Rasterize converts a vector layer while preserving its look")
    func rasterizePreservesPixels() {
        let vm = rasterVM()   // already rasterized in the helper
        #expect(vm.activeLayer?.isRaster == true)
        #expect((vm.sampleCanvas(at: CGPoint(x: 200, y: 200))?.r ?? 0) > 0.8)   // still red
    }

    @Test("Merge down collapses two layers into one raster layer")
    func mergeDown() {
        var scene = Scene.blank(pixelSize: PixelSize(width: 128, height: 128))
        scene.addObject(DrawObject(kind: .rectangle(rect: CGRect(x: 10, y: 10, width: 40, height: 40),
                                                    cornerRadius: 0), style: ObjectStyle()))
        let vm = EditorViewModel(scene: scene)
        vm.addVectorLayer()
        #expect(vm.layers.count == 2)
        vm.mergeDownActiveLayer()
        #expect(vm.layers.count == 1)
        #expect(vm.layers[0].isRaster)
    }

    @Test("Flatten collapses everything to one raster layer")
    func flatten() {
        let vm = EditorViewModel(scene: .blank(pixelSize: PixelSize(width: 128, height: 128)))
        vm.addVectorLayer()
        vm.addRasterLayer()
        #expect(vm.layers.count == 3)
        vm.flattenImage()
        #expect(vm.layers.count == 1)
        #expect(vm.layers[0].isRaster)
    }

    @Test("Raise and lower reorder the active layer")
    func reorder() {
        let vm = EditorViewModel(scene: .blank())
        let first = vm.activeLayerID
        vm.addVectorLayer()               // active is now the new top layer
        vm.setActiveLayer(first)
        #expect(vm.layers.first?.id == first)
        vm.raiseActiveLayer()
        #expect(vm.layers.last?.id == first)   // moved to top
    }

    @Test("Layer property edits each record one undo entry")
    func propertyEdits() {
        let vm = EditorViewModel(scene: .blank())
        let id = vm.activeLayerID
        let before = vm.history.undoStack.count
        vm.setLayerVisible(id, false)
        #expect(vm.activeLayer?.isVisible == false)
        #expect(vm.history.undoStack.count == before + 1)
        vm.setLayerBlend(id, .multiply)
        #expect(vm.activeLayer?.blend == .multiply)
        #expect(vm.history.undoStack.count == before + 2)
    }
}

// MARK: - Eraser modes

@Suite("M6 Eraser")
@MainActor
struct EraserTests {
    private func vmWithRect() -> EditorViewModel {
        var scene = Scene.blank()
        var style = ObjectStyle(strokeColor: .red)
        style.fill = .solid(.red)
        scene.addObject(DrawObject(
            kind: .rectangle(rect: CGRect(x: 100, y: 100, width: 100, height: 100), cornerRadius: 0),
            style: style))
        return EditorViewModel(scene: scene)
    }

    private func eraseStroke(_ vm: EditorViewModel, size: CGFloat = 40) {
        var brush = vm.brush; brush.sizePx = size
        vm.commitEraserStroke(StrokePayload(samples: [
            StrokeSample(point: CGPoint(x: 150, y: 150)),
        ], brush: brush))
    }

    @Test("Object erase removes a touched object, as one undo entry")
    func objectErase() {
        let vm = vmWithRect()
        vm.tool = .eraser
        vm.eraserMode = .object
        let before = vm.history.undoStack.count
        eraseStroke(vm)
        #expect(vm.scene.allObjects.isEmpty)
        #expect(vm.history.undoStack.count == before + 1)
        vm.undo()
        #expect(vm.scene.allObjects.count == 1)   // comes back
    }

    @Test("Partial-vector erase clips the object rather than deleting it")
    func vectorErase() {
        let vm = vmWithRect()
        vm.tool = .eraser
        vm.eraserMode = .vector
        eraseStroke(vm)
        #expect(vm.scene.allObjects.count == 1)                    // still there
        #expect(vm.scene.allObjects.first?.erasedGeometry != nil)  // but clipped
    }

    @Test("Pixel erase on a vector layer falls back to erasing objects")
    func pixelEraseFallsBack() {
        let vm = vmWithRect()      // active layer is vector
        vm.tool = .eraser
        vm.eraserMode = .pixel
        eraseStroke(vm)
        #expect(vm.scene.allObjects.isEmpty)   // fell back to object erase
    }

    @Test("Overlapping partial erasures stay erased in the overlap")
    func overlappingVectorErase() {
        var scene = Scene(canvas: CanvasSpec(pixelSize: PixelSize(width: 400, height: 400),
                                             background: .transparent))
        var style = ObjectStyle(strokeColor: nil); style.fill = .solid(.red)
        scene.addObject(DrawObject(
            kind: .rectangle(rect: CGRect(x: 0, y: 0, width: 400, height: 400), cornerRadius: 0),
            style: style))
        let vm = EditorViewModel(scene: scene)
        vm.tool = .eraser
        vm.eraserMode = .vector
        var brush = vm.brush; brush.sizePx = 60
        // A horizontal scrub, then a vertical one crossing it at (200,200).
        vm.commitEraserStroke(StrokePayload(samples: [
            StrokeSample(point: CGPoint(x: 80, y: 200)),
            StrokeSample(point: CGPoint(x: 320, y: 200)),
        ], brush: brush))
        vm.commitEraserStroke(StrokePayload(samples: [
            StrokeSample(point: CGPoint(x: 200, y: 80)),
            StrokeSample(point: CGPoint(x: 200, y: 320)),
        ], brush: brush))

        let object = vm.scene.allObjects.first
        #expect(object?.erasedGeometry?.subpaths.count == 2)
        // The crossing point lies in BOTH erasures — an even-odd union clip would
        // un-erase it. It must read as erased in both hit testing and pixels.
        #expect(object?.hitTest(CGPoint(x: 200, y: 200), tolerance: 1) == false)
        #expect((vm.sampleCanvas(at: CGPoint(x: 200, y: 200))?.a ?? 1) < 0.1)
    }

    @Test("A 50% opacity layer does not double-darken overlapping shapes")
    func opacityNoDoubleDarken() {
        var scene = Scene(canvas: CanvasSpec(pixelSize: PixelSize(width: 100, height: 100),
                                             background: .transparent))
        var style = ObjectStyle(strokeColor: nil); style.fill = .solid(.black)
        scene.addObject(DrawObject(
            kind: .rectangle(rect: CGRect(x: 10, y: 10, width: 50, height: 50), cornerRadius: 0),
            style: style))
        scene.addObject(DrawObject(
            kind: .rectangle(rect: CGRect(x: 40, y: 40, width: 50, height: 50), cornerRadius: 0),
            style: style))
        scene.layers[0].opacity = 0.5
        let vm = EditorViewModel(scene: scene)
        // The overlap of two opaque shapes on a 50% layer is one 50% black, not
        // 75% — the isolated-layer offscreen composites once.
        guard let overlap = vm.sampleCanvas(at: CGPoint(x: 50, y: 50)) else {
            Issue.record("sample failed"); return
        }
        #expect(abs(overlap.a - 0.5) < 0.12)
    }
}
