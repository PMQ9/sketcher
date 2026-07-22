import CoreGraphics
import Foundation
import Testing
@testable import Sketcher

// Helpers shared by the M3 suites.
private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                  filled: Bool = true) -> DrawObject {
    var style = ObjectStyle(strokeColor: .black, strokeWidthPx: 2)
    if filled { style.fill = .solid(.blue) }
    return DrawObject(kind: .rectangle(rect: CGRect(x: x, y: y, width: w, height: h),
                                       cornerRadius: 0), style: style)
}

private func scene(_ objects: [DrawObject]) -> Scene {
    var scene = Scene(canvas: CanvasSpec(pixelSize: PixelSize(width: 500, height: 500),
                                         pixelsPerPoint: 1))
    for object in objects { scene.addObject(object) }
    return scene
}

// MARK: - Frame geometry

@Suite("M3 SelectionFrame")
struct SelectionFrameTests {

    @Test("A single rotatable shape gets a box frame with 8 handles and a rotate handle")
    func singleBoxFrame() {
        let object = rect(50, 50, 100, 80)
        let frame = SelectionFrame.make(for: [object], rotateOffset: 20)
        #expect(frame?.style == .box)
        #expect(frame?.handles.count == 9)               // 8 box + rotate
        #expect(frame?.handles[.rotate] != nil)
        // The rotate handle floats above the top edge.
        #expect(frame?.handles[.rotate]?.y ?? 0 < frame?.handles[.top]?.y ?? 0)
        #expect(frame?.handles[.bottomRight] == CGPoint(x: 150, y: 130))
    }

    @Test("A single line gets endpoint handles, no box")
    func lineEndpoints() {
        let line = DrawObject(kind: .line(start: CGPoint(x: 10, y: 10),
                                          end: CGPoint(x: 90, y: 40), control: nil),
                              style: ObjectStyle(strokeColor: .black))
        let frame = SelectionFrame.make(for: [line], rotateOffset: 20)
        #expect(frame?.style == .endpoints)
        #expect(frame?.handles[.start] == CGPoint(x: 10, y: 10))
        #expect(frame?.handles[.end] == CGPoint(x: 90, y: 40))
        #expect(frame?.handles[.rotate] == nil)
    }

    @Test("A multi-selection gets a group box with 8 handles and no rotate handle")
    func groupFrame() {
        let frame = SelectionFrame.make(for: [rect(0, 0, 50, 50), rect(100, 100, 50, 50)],
                                        rotateOffset: 20)
        #expect(frame?.style == .group)
        #expect(frame?.handles.count == 8)
        #expect(frame?.handles[.rotate] == nil)
        #expect(frame?.box == CGRect(x: 0, y: 0, width: 150, height: 150))
    }

    @Test("Handle hit-testing prefers corners over edges and finds the rotate handle")
    func handleHitPriority() {
        let frame = SelectionFrame.make(for: [rect(0, 0, 100, 100)], rotateOffset: 24)!
        #expect(frame.handleHit(at: CGPoint(x: 100, y: 100), tolerance: 8) == .bottomRight)
        #expect(frame.handleHit(at: CGPoint(x: 50, y: 0), tolerance: 8) == .top)
        // Above the top edge by the rotate offset.
        #expect(frame.handleHit(at: CGPoint(x: 50, y: -24), tolerance: 8) == .rotate)
        // Empty interior: nothing.
        #expect(frame.handleHit(at: CGPoint(x: 50, y: 50), tolerance: 8) == nil)
    }
}

// MARK: - Resize / rotate geometry

@Suite("M3 Resize")
@MainActor
struct ResizeTests {

    @Test("Resizing a corner keeps the opposite corner fixed")
    func cornerResizeFixesOpposite() {
        let object = rect(10, 10, 100, 80)
        let resized = object.resized(handle: .bottomRight, to: CGPoint(x: 200, y: 200))
        guard case .rectangle(let r, _) = resized.kind else { return #expect(Bool(false)) }
        #expect(r.minX == 10 && r.minY == 10)      // top-left fixed
        #expect(r.maxX == 200 && r.maxY == 200)
    }

    @Test("A rotated shape resizes with the opposite WORLD corner pinned")
    func rotatedResizeFixesWorldCorner() {
        var object = rect(50, 50, 100, 100)
        object.rotation = .pi / 2
        // World position of the fixed (top-left) corner before the drag.
        let fixedBefore = CGPoint(x: 50, y: 50).rotated(around: CGPoint(x: 100, y: 100),
                                                        by: .pi / 2)
        let resized = object.resized(handle: .bottomRight, to: CGPoint(x: 300, y: 260))
        // That corner must still be one of the resized shape's world corners.
        let nearest = resized.outlineCorners.map { $0.distance(to: fixedBefore) }.min() ?? 999
        #expect(nearest < 0.001)
    }

    @Test("Repeated resize from the original never drifts")
    func resizeIsDriftFree() {
        let scene0 = scene([rect(50, 50, 100, 100)])
        let viewModel = EditorViewModel(scene: scene0)
        viewModel.tool = .select
        let id = viewModel.scene.allObjects[0].id
        viewModel.selection.select(id)

        let handle = viewModel.selectionFrame!.handles[.bottomRight]!
        viewModel.pointerDown(at: handle, tolerance: 6, modifiers: [])
        // 200 jittery frames, then a definitive final point.
        for i in 0..<200 {
            let t = CGFloat(i)
            viewModel.pointerDragged(to: CGPoint(x: 200 + sin(t) * 40,
                                                 y: 220 + cos(t) * 40))
        }
        let final = CGPoint(x: 250, y: 220)
        viewModel.pointerDragged(to: final)
        viewModel.pointerUp(at: final)

        // Identical to a single clean resize to the same point — no accumulation.
        guard case .rectangle(let r, _) = viewModel.scene.object(with: id)?.kind else {
            return #expect(Bool(false))
        }
        #expect(r == CGRect(x: 50, y: 50, width: 200, height: 170))
    }

    @Test("Group resize scales every member around the fixed corner")
    func groupResizeScales() {
        let scene0 = scene([rect(0, 0, 50, 50), rect(100, 100, 50, 50)])
        let viewModel = EditorViewModel(scene: scene0)
        viewModel.tool = .select
        let ids = viewModel.scene.allObjects.map(\.id)
        viewModel.selection.objectIDs = Set(ids)

        // Union box is (0,0,150,150); drag its bottom-right from (150,150) to (300,300).
        viewModel.pointerDown(at: CGPoint(x: 150, y: 150), tolerance: 6, modifiers: [])
        viewModel.pointerDragged(to: CGPoint(x: 300, y: 300))
        viewModel.pointerUp(at: CGPoint(x: 300, y: 300))

        // Everything scales 2x about the fixed top-left corner (0,0).
        func box(_ id: UUID) -> CGRect {
            if case .rectangle(let r, _) = viewModel.scene.object(with: id)?.kind { return r }
            return .null
        }
        #expect(box(ids[0]) == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(box(ids[1]) == CGRect(x: 200, y: 200, width: 100, height: 100))
    }

    @Test("Dragging the rotate handle 90° sets the rotation")
    func rotateGesture() {
        let scene0 = scene([rect(100, 100, 80, 80)])
        let viewModel = EditorViewModel(scene: scene0)
        viewModel.tool = .select
        let id = viewModel.scene.allObjects[0].id
        viewModel.selection.select(id)

        let center = CGPoint(x: 140, y: 140)
        let rotateHandle = viewModel.selectionFrame!.handles[.rotate]!  // above center
        viewModel.pointerDown(at: rotateHandle, tolerance: 6, modifiers: [])
        // Drag to directly right of center: a quarter turn from "up".
        viewModel.pointerDragged(to: CGPoint(x: center.x + 100, y: center.y))
        viewModel.pointerUp(at: CGPoint(x: center.x + 100, y: center.y))

        let rotation = viewModel.scene.object(with: id)?.rotation ?? 0
        #expect(abs(rotation - .pi / 2) < 0.0001)
    }

    @Test("scaled maps a rect's corners about the pivot")
    func scaledGeometry() {
        let object = rect(10, 10, 20, 20)
        let s = object.scaled(sx: 2, sy: 3, around: CGPoint(x: 10, y: 10))
        guard case .rectangle(let r, _) = s.kind else { return #expect(Bool(false)) }
        // Pivot (10,10) is fixed; far corner (30,30) -> (10+40, 10+60) = (50,70).
        #expect(r == CGRect(x: 10, y: 10, width: 40, height: 60))
    }
}

// MARK: - Arrange

@Suite("M3 Arrange")
@MainActor
struct ArrangeTests {

    @Test("Z-order: front, back, forward, backward move within the layer")
    func zOrder() {
        var s = scene([rect(0, 0, 10, 10), rect(0, 0, 10, 10), rect(0, 0, 10, 10)])
        let ids = s.allObjects.map(\.id)   // [A, B, C] bottom -> top

        s.reorder([ids[1]], .front)                    // A C B
        #expect(s.allObjects.map(\.id) == [ids[0], ids[2], ids[1]])

        s.reorder([ids[1]], .back)                     // B A C
        #expect(s.allObjects.map(\.id) == [ids[1], ids[0], ids[2]])

        s.reorder([ids[1]], .forward)                  // A B C
        #expect(s.allObjects.map(\.id) == [ids[0], ids[1], ids[2]])

        s.reorder([ids[2]], .backward)                 // A C B
        #expect(s.allObjects.map(\.id) == [ids[0], ids[2], ids[1]])
    }

    @Test("A contiguous multi-selection moves forward as one block")
    func multiForward() {
        var s = scene([rect(0, 0, 1, 1), rect(0, 0, 1, 1),
                       rect(0, 0, 1, 1), rect(0, 0, 1, 1)])
        let ids = s.allObjects.map(\.id)   // A B C D
        s.reorder([ids[0], ids[1]], .forward)          // C A B D
        #expect(s.allObjects.map(\.id) == [ids[2], ids[0], ids[1], ids[3]])
    }

    @Test("Align left snaps every box to the union's left edge")
    func alignLeft() {
        var s = scene([rect(10, 0, 20, 20), rect(50, 50, 40, 20), rect(80, 90, 10, 10)])
        let ids = Set(s.allObjects.map(\.id))
        s.align(ids, .left)
        for object in s.allObjects { #expect(object.bounds.minX == 10) }
    }

    @Test("Distribute horizontally evens out the center spacing")
    func distributeHorizontal() {
        // Centers start at x = 5, 40, 200; distribute should re-center the middle.
        var s = scene([rect(0, 0, 10, 10), rect(35, 0, 10, 10), rect(195, 0, 10, 10)])
        let ids = Set(s.allObjects.map(\.id))
        s.distribute(ids, .horizontal)
        let centers = s.allObjects.map(\.bounds.midX).sorted()
        // First (5) and last (200) stay; the middle lands exactly between them.
        #expect(abs(centers[0] - 5) < 0.001)
        #expect(abs(centers[2] - 200) < 0.001)
        #expect(abs(centers[1] - 102.5) < 0.001)
    }

    @Test("Group assigns a shared id; expandingGroups selects the whole group")
    func grouping() {
        let scene0 = scene([rect(0, 0, 10, 10), rect(20, 20, 10, 10), rect(40, 40, 10, 10)])
        let viewModel = EditorViewModel(scene: scene0)
        let ids = viewModel.scene.allObjects.map(\.id)
        viewModel.selection.objectIDs = [ids[0], ids[1]]
        viewModel.groupSelection()

        let g0 = viewModel.scene.object(with: ids[0])?.groupIDs.first
        let g1 = viewModel.scene.object(with: ids[1])?.groupIDs.first
        #expect(g0 != nil && g0 == g1)
        #expect(viewModel.scene.object(with: ids[2])?.groupIDs.isEmpty == true)

        // Selecting one member expands to the whole group, but not the loner.
        #expect(viewModel.scene.expandingGroups([ids[0]]) == Set([ids[0], ids[1]]))
        #expect(viewModel.scene.expandingGroups([ids[2]]) == Set([ids[2]]))

        viewModel.selection.objectIDs = [ids[0]]
        viewModel.ungroupSelection()
        #expect(viewModel.scene.object(with: ids[0])?.groupIDs.isEmpty == true)
    }

    @Test("Clicking a grouped object selects the whole group")
    func clickSelectsGroup() {
        let scene0 = scene([rect(0, 0, 40, 40), rect(100, 100, 40, 40)])
        let viewModel = EditorViewModel(scene: scene0)
        let ids = viewModel.scene.allObjects.map(\.id)
        viewModel.selection.objectIDs = Set(ids)
        viewModel.groupSelection()
        viewModel.selection.clear()

        viewModel.tool = .select
        viewModel.pointerDown(at: CGPoint(x: 20, y: 20), tolerance: 6, modifiers: [])
        #expect(viewModel.selection.objectIDs == Set(ids))
        viewModel.pointerUp(at: CGPoint(x: 20, y: 20))
    }

    @Test("Arrange commands each produce exactly one undo entry")
    func arrangeUndo() {
        let scene0 = scene([rect(0, 0, 10, 10), rect(50, 50, 10, 10)])
        let viewModel = EditorViewModel(scene: scene0)
        viewModel.selection.objectIDs = Set(viewModel.scene.allObjects.map(\.id))

        let before = viewModel.history.undoStack.count
        viewModel.alignSelection(.left)
        #expect(viewModel.history.undoStack.count == before + 1)
        viewModel.undo()
        #expect(viewModel.history.undoStack.count == before)
        // Undo restored the original geometry.
        #expect(viewModel.scene.allObjects.contains { $0.bounds.minX == 50 })
    }
}

// MARK: - Clipboard

@Suite("M3 Clipboard", .serialized)
@MainActor
struct ClipboardTests {

    @Test("Objects round-trip through the private pasteboard type losslessly")
    func objectRoundTrip() {
        let original = [rect(10, 10, 40, 30), rect(100, 20, 20, 20, filled: false)]
        #expect(ObjectClipboard.write(original, image: nil, pixelsPerPoint: 1))
        guard let read = ObjectClipboard.read() else { return #expect(Bool(false)) }
        #expect(read.count == 2)
        #expect(read[0].bounds == original[0].bounds)
        // Fresh identities are the caller's job — the payload preserves the id,
        // but paste reassigns it. Here we just prove geometry survived.
        if case .rectangle(let r, _) = read[1].kind {
            #expect(r == CGRect(x: 100, y: 20, width: 20, height: 20))
        } else {
            #expect(Bool(false))
        }
    }

    @Test("Paste inserts fresh-identity copies at an offset, as one undo entry")
    func pasteInsertsCopies() {
        let scene0 = scene([rect(10, 10, 40, 30)])
        let viewModel = EditorViewModel(scene: scene0)
        let originalID = viewModel.scene.allObjects[0].id
        viewModel.selection.select(originalID)
        viewModel.copySelection()

        let before = viewModel.history.undoStack.count
        viewModel.paste()
        #expect(viewModel.scene.allObjects.count == 2)
        #expect(viewModel.history.undoStack.count == before + 1)
        // The paste is selected, has a new id, and is offset from the original.
        #expect(!viewModel.selection.objectIDs.contains(originalID))
        let pasted = viewModel.scene.allObjects.first { $0.id != originalID }
        #expect(pasted?.bounds.minX ?? 0 > 10)
    }

    @Test("Cut copies then removes, in one undo entry")
    func cutRemoves() {
        let scene0 = scene([rect(10, 10, 40, 30)])
        let viewModel = EditorViewModel(scene: scene0)
        viewModel.selection.select(viewModel.scene.allObjects[0].id)
        viewModel.cut()
        #expect(viewModel.scene.allObjects.isEmpty)
        #expect(ObjectClipboard.hasObjects)
        viewModel.undo()
        #expect(viewModel.scene.allObjects.count == 1)
    }

    @Test("Duplicating a group makes the copies their own group")
    func duplicateRemapsGroup() {
        let scene0 = scene([rect(0, 0, 20, 20), rect(40, 40, 20, 20)])
        let viewModel = EditorViewModel(scene: scene0)
        let ids = viewModel.scene.allObjects.map(\.id)
        viewModel.selection.objectIDs = Set(ids)
        viewModel.groupSelection()
        let originalGroup = viewModel.scene.object(with: ids[0])?.groupIDs.first

        viewModel.selection.objectIDs = Set(ids)
        viewModel.duplicateSelection()
        // Four objects now; the two copies share a group that is NOT the original.
        #expect(viewModel.scene.allObjects.count == 4)
        let copyGroups = Set(viewModel.selection.objectIDs.compactMap {
            viewModel.scene.object(with: $0)?.groupIDs.first
        })
        #expect(copyGroups.count == 1)
        #expect(copyGroups.first != originalGroup)
    }
}
