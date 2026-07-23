import CoreGraphics
import Foundation
import Testing
@testable import Sketcher

/// End-to-end region / floating-selection behavior through the view model, the
/// milestone's headline: select → move → drop, plus cut/copy, fill, and bucket.
@MainActor
@Suite("M7 Region view model")
struct RegionViewModelTests {
    private let side = 100

    /// A transparent-canvas doc whose single (active) layer is a raster surface
    /// with an opaque red square painted at `square`.
    private func rasterVM(square: CGRect) -> EditorViewModel {
        let canvas = CanvasSpec(pixelSize: PixelSize(width: side, height: side),
                                background: .transparent)
        let store = SurfaceStore()
        let ctx = PixelFormat.makeContext(width: side, height: side,
                                          colorSpace: canvas.cgColorSpace)!
        ctx.translateBy(x: 0, y: CGFloat(side)); ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(RGBAColor(r: 1, g: 0, b: 0).cgColor)
        ctx.fill(square)
        var scene = Scene(canvas: canvas)
        let layer = Layer(name: "Raster", content: .raster(store.register(ctx.makeImage()!)))
        scene.layers = [layer]
        scene.activeLayerID = layer.id
        return EditorViewModel(scene: scene, surfaces: store)
    }

    /// Un-premultiplied pixel of the active raster layer.
    private func pixel(_ vm: EditorViewModel, _ x: Int, _ y: Int)
        -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        guard case .raster(let id) = vm.scene.layers[0].content,
              let image = vm.surfaces.image(id),
              let buffer = FloodFill.readBGRA(image, width: side, height: side) else {
            return (0, 0, 0, -1)
        }
        let p = (y * side + x) * 4
        return unpremultiply(r: buffer[p + 2], g: buffer[p + 1], b: buffer[p + 0], a: buffer[p + 3])
    }

    private func dragRegion(_ vm: EditorViewModel, from a: CGPoint, to b: CGPoint) {
        vm.pointerDown(at: a, tolerance: 1, modifiers: [])
        vm.pointerDragged(to: b)
        vm.pointerUp(at: b)
    }

    // MARK: Selection creation

    @Test("A marquee drag sets a rectangular region")
    func marqueeSetsRegion() {
        let vm = rasterVM(square: CGRect(x: 20, y: 20, width: 20, height: 20))
        vm.tool = .marquee
        dragRegion(vm, from: CGPoint(x: 15, y: 15), to: CGPoint(x: 45, y: 45))
        guard case .rect(let r)? = vm.selection.region else {
            #expect(Bool(false), "expected a rect region"); return
        }
        #expect(abs(r.width - 30) < 1 && abs(r.height - 30) < 1)
    }

    @Test("The wand selects the contiguous same-color blob")
    func wandSelectsBlob() {
        let vm = rasterVM(square: CGRect(x: 20, y: 20, width: 30, height: 30))
        vm.tool = .wand
        vm.pointerDown(at: CGPoint(x: 35, y: 35), tolerance: 1, modifiers: [])
        vm.pointerUp(at: CGPoint(x: 35, y: 35))
        guard case .mask(_, let bounds)? = vm.selection.region else {
            #expect(Bool(false), "expected a mask region"); return
        }
        #expect(abs(bounds.minX - 20) < 2 && abs(bounds.width - 30) < 2)
    }

    // MARK: Lift → move → drop (the headline)

    @Test("Select, move, and drop is ONE undo entry that relocates the pixels")
    func moveIsOneUndoEntry() {
        let vm = rasterVM(square: CGRect(x: 20, y: 20, width: 20, height: 20))
        vm.tool = .marquee
        dragRegion(vm, from: CGPoint(x: 15, y: 15), to: CGPoint(x: 45, y: 45))
        let entriesBefore = vm.history.undoStack.count

        // Drag from inside the selection lifts the pixels; a second drag moves them.
        vm.pointerDown(at: CGPoint(x: 30, y: 30), tolerance: 1, modifiers: [])
        #expect(vm.selection.floating != nil)          // lifted
        vm.pointerDragged(to: CGPoint(x: 70, y: 30))   // +40 in x
        vm.pointerUp(at: CGPoint(x: 70, y: 30))
        vm.commitFloating()                            // Return / drop
        #expect(vm.selection.floating == nil)

        #expect(vm.history.undoStack.count == entriesBefore + 1)   // ONE entry
        #expect(pixel(vm, 30, 30).a < 0.1)             // source cleared
        let moved = pixel(vm, 70, 30)
        #expect(moved.r > 0.8 && moved.a > 0.8)        // destination holds the pixels

        vm.undo()
        #expect(pixel(vm, 30, 30).r > 0.8)             // undo restores the original
        #expect(pixel(vm, 70, 30).a < 0.1)
    }

    @Test("⌘Z mid-float restores the source and abandons the lift")
    func undoMidFloatRestores() {
        let vm = rasterVM(square: CGRect(x: 20, y: 20, width: 20, height: 20))
        vm.tool = .marquee
        dragRegion(vm, from: CGPoint(x: 15, y: 15), to: CGPoint(x: 45, y: 45))
        vm.pointerDown(at: CGPoint(x: 30, y: 30), tolerance: 1, modifiers: [])
        vm.pointerDragged(to: CGPoint(x: 70, y: 30))
        vm.pointerUp(at: CGPoint(x: 70, y: 30))
        vm.undo()   // placed-but-undropped float: abort
        #expect(vm.selection.floating == nil)
        #expect(pixel(vm, 30, 30).r > 0.8)   // source intact, not moved
    }

    // MARK: Fill / delete

    @Test("Fill Selection paints the region and clears it on delete")
    func fillAndDelete() {
        let vm = rasterVM(square: CGRect(x: 0, y: 0, width: 1, height: 1))
        vm.tool = .marquee
        dragRegion(vm, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 60, y: 60))
        vm.fillSelection(with: RGBAColor(r: 0, g: 0, b: 1))
        let filled = pixel(vm, 45, 45)
        #expect(filled.b > 0.8 && filled.a > 0.8)
        #expect(pixel(vm, 10, 10).a < 0.1)     // outside the region: untouched

        vm.deleteSelectionPixels()
        #expect(pixel(vm, 45, 45).a < 0.1)     // cleared to transparent, not white
    }

    // MARK: Bucket

    @Test("The bucket flood-fills a contiguous raster region")
    func bucketRasterFill() {
        let vm = rasterVM(square: CGRect(x: 20, y: 20, width: 60, height: 60))
        vm.tool = .bucket
        vm.primaryColor = RGBAColor(r: 0, g: 1, b: 0)
        vm.applyBucket(at: CGPoint(x: 50, y: 50), modifiers: [])   // inside the red square
        let filled = pixel(vm, 50, 50)
        #expect(filled.g > 0.8 && filled.r < 0.2)   // red → green
    }

    @Test("The bucket sets a closed vector shape's fill (non-destructive)")
    func bucketVectorFill() {
        let canvas = CanvasSpec(pixelSize: PixelSize(width: side, height: side),
                                background: .light)
        var scene = Scene(canvas: canvas)
        var rect = DrawObject(kind: .rectangle(rect: CGRect(x: 20, y: 20, width: 40, height: 40),
                                               cornerRadius: 0),
                              style: ObjectStyle(strokeColor: .black))
        rect.style.fill = .none
        scene.layers[0].objects = [rect]
        let vm = EditorViewModel(scene: scene)
        vm.tool = .bucket
        vm.primaryColor = RGBAColor(r: 0, g: 0, b: 1)
        vm.applyBucket(at: CGPoint(x: 40, y: 40), modifiers: [])   // inside the rectangle
        guard case .rectangle? = vm.scene.object(with: rect.id)?.kind,
              case .solid(let color)? = vm.scene.object(with: rect.id)?.style.fill else {
            #expect(Bool(false), "expected a solid fill"); return
        }
        #expect(color.b > 0.8)
    }

    // MARK: Invert / grow

    @Test("Invert selects the complement within the page")
    func invertComplement() {
        let vm = rasterVM(square: CGRect(x: 0, y: 0, width: 1, height: 1))
        vm.tool = .marquee
        dragRegion(vm, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 40))
        #expect(vm.selectionContains(CGPoint(x: 25, y: 25)))
        vm.invertSelection()
        #expect(!vm.selectionContains(CGPoint(x: 25, y: 25)))   // inside the old rect: now out
        #expect(vm.selectionContains(CGPoint(x: 80, y: 80)))    // outside it: now in
    }
}
