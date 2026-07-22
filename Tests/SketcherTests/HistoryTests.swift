import CoreGraphics
import Foundation
import Testing
@testable import Sketcher

@Suite("History")
struct HistoryTests {

    private func sceneWithRectangle() -> Scene {
        var scene = Scene.blank()
        scene.addObject(DrawObject(
            kind: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                             cornerRadius: 0),
            style: ObjectStyle()))
        return scene
    }

    @Test("A gesture that changes nothing pushes nothing")
    func unchangedGesturePushesNothing() {
        let scene = Scene.blank()
        var history = History()
        history.begin(scene)
        let pushed = history.end(scene, name: "No-op")

        #expect(!pushed)
        #expect(!history.canUndo)
    }

    @Test("A gesture that changes the scene pushes exactly one entry")
    func changedGesturePushesOne() {
        var scene = Scene.blank()
        var history = History()
        history.begin(scene)
        scene.addObject(DrawObject(kind: .ellipse(rect: CGRect(x: 0, y: 0, width: 5, height: 5)),
                                   style: ObjectStyle()))
        let pushed = history.end(scene, name: "Draw")

        #expect(pushed)
        #expect(history.undoStack.count == 1)
        #expect(history.undoActionName == "Draw")
    }

    @Test("Undo restores the pre-gesture scene and redo replays it")
    func undoRedoRoundTrip() {
        let empty = Scene.blank()
        var scene = empty
        var history = History()

        history.begin(scene)
        scene = sceneWithRectangle()
        history.end(scene, name: "Draw")

        guard case .scene(let restored, _)? = history.undo(current: scene) else {
            Issue.record("expected a scene entry")
            return
        }
        #expect(restored.allObjects.isEmpty)

        guard case .scene(let replayed, _)? = history.redo(current: restored) else {
            Issue.record("expected a redo entry")
            return
        }
        #expect(replayed.allObjects.count == 1)
    }

    @Test("A new edit clears the redo stack")
    func newEditClearsRedo() {
        var scene = Scene.blank()
        var history = History()

        history.begin(scene)
        scene = sceneWithRectangle()
        history.end(scene, name: "Draw")
        _ = history.undo(current: scene)
        #expect(history.canRedo)

        history.push(.scene(scene, name: "Other"))
        #expect(!history.canRedo)
    }

    @Test("Nested begin does not clobber the outer snapshot")
    func nestedBeginKeepsOuterSnapshot() {
        let original = Scene.blank()
        var scene = original
        var history = History()

        history.begin(scene)
        scene = sceneWithRectangle()
        history.begin(scene)      // must be ignored
        history.end(scene, name: "Draw")

        guard case .scene(let restored, _)? = history.undo(current: scene) else {
            Issue.record("expected a scene entry")
            return
        }
        // If the nested begin had won, this would restore to the one-rectangle
        // state instead of the empty one.
        #expect(restored.allObjects.isEmpty)
    }

    @Test("A slider drag coalesces into exactly one undo entry")
    func interactiveEditCoalesces() {
        var scene = Scene.blank()
        var history = History()

        // Six value ticks, as a real slider drag would produce.
        history.beginInteractive(scene)
        for i in 1...6 {
            scene.canvas.pixelsPerPoint = CGFloat(i)
            if i == 1 { history.beginInteractive(scene) }   // re-entrancy is safe
        }
        history.endInteractive(scene, name: "Size")
        history.endInteractive(scene, name: "Size")

        #expect(history.undoStack.count == 1)
    }

    @Test("Aborting returns the pre-gesture scene and pushes nothing")
    func abortRestoresWithoutPushing() {
        let original = Scene.blank()
        var history = History()
        history.begin(original)

        let restored = history.abort()
        #expect(restored?.allObjects.isEmpty == true)
        #expect(!history.canUndo)
        #expect(!history.isGestureInFlight)
    }

    @Test("record() is a no-op when nothing changed")
    func recordNoOp() {
        let scene = Scene.blank()
        var history = History()
        // Hoisted: #expect decomposes the call, which it cannot do for a
        // mutating method.
        let recorded = history.record(from: scene, to: scene, name: "Nothing")
        #expect(!recorded)
        #expect(!history.canUndo)
    }

    @Test("Scene snapshots stay small because layers hold SurfaceIDs, not pixels")
    func sceneSnapshotIsHandlesOnly() {
        // The claim that `.scene` entries are never worth evicting rests on
        // this: adding raster layers must not grow the snapshot.
        var scene = Scene.blank()
        for i in 0..<5 {
            var layer = Layer(name: "Raster \(i)", content: .raster(SurfaceID()))
            layer.opacity = 0.5
            scene.layers.append(layer)
        }
        let entry = HistoryEntry.scene(scene, name: "Test")
        #expect(entry.byteCount < 100_000)
        #expect(scene.referencedSurfaceIDs.count == 5)
    }

    @Test("Raster patch rects quantize outward to tile boundaries and clamp")
    func rasterPatchQuantizes() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let dirty = CGRect(x: 130, y: 10, width: 5, height: 5)
        let quantized = RasterPatch.quantize(dirty, in: bounds)

        #expect(quantized == CGRect(x: 128, y: 0, width: 128, height: 128))
        #expect(quantized.contains(dirty))
    }

    @Test("Quantized patch rects clamp to the canvas")
    func rasterPatchClampsToCanvas() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let quantized = RasterPatch.quantize(CGRect(x: 190, y: 190, width: 5, height: 5),
                                             in: bounds)
        #expect(bounds.contains(quantized))
    }
}

@Suite("Editor")
@MainActor
struct EditorViewModelTests {

    @Test("Cmd+Z mid-gesture aborts the gesture rather than popping history")
    func undoMidGestureAborts() {
        let viewModel = EditorViewModel(scene: .blank())
        viewModel.tool = .rectangle

        // One committed shape, so there IS something on the undo stack.
        viewModel.pointerDown(at: CGPoint(x: 0, y: 0), tolerance: 4, modifiers: [])
        viewModel.pointerDragged(to: CGPoint(x: 100, y: 100))
        viewModel.pointerUp(at: CGPoint(x: 100, y: 100))
        #expect(viewModel.scene.allObjects.count == 1)
        #expect(viewModel.canUndo)

        // Start a second shape and undo mid-drag.
        viewModel.pointerDown(at: CGPoint(x: 200, y: 200), tolerance: 4, modifiers: [])
        viewModel.pointerDragged(to: CGPoint(x: 300, y: 300))
        viewModel.undo()

        // The in-flight draft is gone, but the committed shape survives —
        // the abort consumed this ⌘Z, it did not pop history.
        #expect(viewModel.scene.allObjects.count == 1)
        #expect(viewModel.canUndo)

        // The NEXT ⌘Z pops for real.
        viewModel.undo()
        #expect(viewModel.scene.allObjects.isEmpty)
    }

    @Test("A degenerate drag commits nothing and leaves no undo entry")
    func degenerateDraftIsRejected() {
        let viewModel = EditorViewModel(scene: .blank())
        viewModel.tool = .rectangle

        viewModel.pointerDown(at: CGPoint(x: 10, y: 10), tolerance: 4, modifiers: [])
        viewModel.pointerDragged(to: CGPoint(x: 11, y: 11))   // under the 4px floor
        viewModel.pointerUp(at: CGPoint(x: 11, y: 11))

        #expect(viewModel.scene.allObjects.isEmpty)
        #expect(!viewModel.canUndo)
    }

    @Test("A single click with the brush commits a dot")
    func brushClickCommitsDot() {
        let viewModel = EditorViewModel(scene: .blank())
        viewModel.tool = .brush

        viewModel.pointerDown(at: CGPoint(x: 50, y: 50), tolerance: 4, modifiers: [])
        viewModel.pointerUp(at: CGPoint(x: 50, y: 50))

        // A click without a drag is a legitimate mark, unlike a degenerate rect.
        #expect(viewModel.scene.allObjects.count == 1)
    }

    @Test("A dark canvas flips the default ink so the first stroke is visible")
    func darkCanvasFlipsInk() {
        let viewModel = EditorViewModel(scene: .blank(background: .light))
        #expect(viewModel.primaryColor.luminance < 0.5)   // black on white

        viewModel.setCanvasBackground(.dark)
        #expect(viewModel.primaryColor.luminance > 0.5)   // white on dark
    }

    @Test("Switching the background does not overwrite a hand-picked color")
    func manualColorSurvivesBackgroundChange() {
        let viewModel = EditorViewModel(scene: .blank(background: .light))
        viewModel.primaryColor = .red

        viewModel.setCanvasBackground(.dark)
        #expect(viewModel.primaryColor == .red)
    }

    @Test("History-mutating actions are refused mid-gesture")
    func historyActionsRefusedMidGesture() {
        let viewModel = EditorViewModel(scene: .blank())
        viewModel.tool = .rectangle
        viewModel.pointerDown(at: .zero, tolerance: 4, modifiers: [])
        viewModel.pointerDragged(to: CGPoint(x: 80, y: 80))
        viewModel.pointerUp(at: CGPoint(x: 80, y: 80))

        viewModel.selectAll()
        #expect(viewModel.selection.objectIDs.count == 1)

        // Start dragging the shape, then try to delete mid-drag. The single
        // pre-gesture snapshot slot is occupied; writing to it would corrupt
        // history, so the delete must be refused.
        viewModel.tool = .select
        viewModel.pointerDown(at: CGPoint(x: 0, y: 40), tolerance: 6, modifiers: [])
        viewModel.pointerDragged(to: CGPoint(x: 20, y: 60))
        viewModel.deleteSelection()

        #expect(viewModel.scene.allObjects.count == 1)
    }

    @Test("Shift constrains a rectangle drag to a square")
    func shiftConstrainsToSquare() {
        let viewModel = EditorViewModel(scene: .blank())
        viewModel.tool = .rectangle

        viewModel.pointerDown(at: .zero, tolerance: 4, modifiers: [.shift])
        viewModel.pointerDragged(to: CGPoint(x: 200, y: 80), modifiers: [.shift])
        viewModel.pointerUp(at: CGPoint(x: 200, y: 80))

        guard case .rectangle(let rect, _)? = viewModel.scene.allObjects.first?.kind else {
            Issue.record("expected a rectangle")
            return
        }
        #expect(rect.width == rect.height)
    }

    @Test("Switching tools mid-draft discards the draft")
    func toolSwitchResolvesDraft() {
        let viewModel = EditorViewModel(scene: .blank())
        viewModel.tool = .rectangle
        viewModel.pointerDown(at: .zero, tolerance: 4, modifiers: [])
        viewModel.pointerDragged(to: CGPoint(x: 100, y: 100))

        viewModel.tool = .ellipse

        #expect(viewModel.scene.allObjects.isEmpty)
        #expect(viewModel.draftObject == nil)
    }

    @Test("Brush size steps a non-linear ladder")
    func brushSizeLadder() {
        let viewModel = EditorViewModel(scene: .blank())
        let ppp = viewModel.scene.canvas.pixelsPerPoint
        viewModel.brush.sizePx = 8 * ppp

        viewModel.adjustBrushSize(step: 1)
        #expect(viewModel.brush.sizePx == 12 * ppp)

        viewModel.adjustBrushSize(step: -1)
        #expect(viewModel.brush.sizePx == 8 * ppp)
    }
}
