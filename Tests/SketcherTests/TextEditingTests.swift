import CoreGraphics
import Foundation
import Testing
@testable import Sketcher

// Helpers shared by the M5 text suites.

private func makeScene(_ objects: [DrawObject] = []) -> Scene {
    var scene = Scene(canvas: CanvasSpec(pixelSize: PixelSize(width: 600, height: 400),
                                         pixelsPerPoint: 1))
    for object in objects { scene.addObject(object) }
    return scene
}

private func textObject(_ string: String, x: CGFloat = 40, y: CGFloat = 40,
                        rotation: CGFloat = 0, fontSizePx: CGFloat = 40) -> DrawObject {
    var object = DrawObject(
        kind: .text(TextPayload(string: string, origin: CGPoint(x: x, y: y),
                                fontSizePx: fontSizePx)),
        style: ObjectStyle(strokeColor: .black))
    object.rotation = rotation
    return object
}

private func payload(of object: DrawObject?) -> TextPayload? {
    guard case .text(let p)? = object?.kind else { return nil }
    return p
}

// MARK: - Placement

@Suite("M5 Text placement")
@MainActor
struct TextPlacementTests {

    @Test("A click places an auto-width box and opens it for editing")
    func clickPlacesAutoWidth() {
        let viewModel = EditorViewModel(scene: makeScene())
        viewModel.tool = .text
        viewModel.pointerDown(at: CGPoint(x: 100, y: 100), tolerance: 6, modifiers: [])
        viewModel.pointerUp(at: CGPoint(x: 100, y: 100))

        #expect(viewModel.isEditingText)
        #expect(payload(of: viewModel.editingTextObject)?.resize == .autoWidth)
        #expect(payload(of: viewModel.editingTextObject)?.origin == CGPoint(x: 100, y: 100))
    }

    @Test("A drag places a fixed-size box")
    func dragPlacesFixed() {
        let viewModel = EditorViewModel(scene: makeScene())
        viewModel.tool = .text
        viewModel.pointerDown(at: CGPoint(x: 50, y: 50), tolerance: 6, modifiers: [])
        viewModel.pointerDragged(to: CGPoint(x: 250, y: 150))
        viewModel.pointerUp(at: CGPoint(x: 250, y: 150))

        #expect(viewModel.isEditingText)
        let p = payload(of: viewModel.editingTextObject)
        #expect(p?.resize == .fixed)
        #expect(p?.boxSize == CGSize(width: 200, height: 100))
    }

    @Test("Clicking an existing text object edits it instead of stacking a new one")
    func clickEditsExisting() {
        let existing = textObject("Hi", x: 40, y: 40)
        let viewModel = EditorViewModel(scene: makeScene([existing]))
        let id = viewModel.scene.allObjects[0].id
        viewModel.tool = .text
        // A point inside the text's bounds.
        viewModel.pointerDown(at: CGPoint(x: 50, y: 55), tolerance: 6, modifiers: [])
        viewModel.pointerUp(at: CGPoint(x: 50, y: 55))

        #expect(viewModel.editingTextID == id)
        #expect(viewModel.scene.allObjects.count == 1)   // no new box
    }
}

// MARK: - Editing lifecycle

@Suite("M5 Text editing")
@MainActor
struct TextEditingLifecycleTests {

    private func placeAndType(_ viewModel: EditorViewModel, _ string: String,
                              at p: CGPoint = CGPoint(x: 80, y: 80)) {
        viewModel.tool = .text
        viewModel.pointerDown(at: p, tolerance: 6, modifiers: [])
        viewModel.pointerUp(at: p)
        viewModel.updateEditingText(string)
    }

    @Test("Typing then committing keeps the object as one undo entry")
    func commitKeepsText() {
        let viewModel = EditorViewModel(scene: makeScene())
        placeAndType(viewModel, "Hello")
        let committed = viewModel.commitTextEditing()

        #expect(committed)
        #expect(!viewModel.isEditingText)
        #expect(viewModel.scene.allObjects.count == 1)
        #expect(payload(of: viewModel.scene.allObjects.first)?.string == "Hello")
        #expect(viewModel.history.undoStack.count == 1)
    }

    @Test("Many keystrokes collapse into exactly one undo entry")
    func typingCoalescesToOneEntry() {
        let viewModel = EditorViewModel(scene: makeScene())
        viewModel.tool = .text
        viewModel.pointerDown(at: CGPoint(x: 80, y: 80), tolerance: 6, modifiers: [])
        viewModel.pointerUp(at: CGPoint(x: 80, y: 80))
        for s in ["H", "He", "Hel", "Hell", "Hello"] { viewModel.updateEditingText(s) }
        viewModel.commitTextEditing()

        #expect(viewModel.history.undoStack.count == 1)
        // And that single entry undoes the whole text at once.
        viewModel.undo()
        #expect(viewModel.scene.allObjects.isEmpty)
    }

    @Test("Committing an empty box leaves nothing behind and pushes no entry")
    func emptyBoxDiscarded() {
        let viewModel = EditorViewModel(scene: makeScene())
        viewModel.tool = .text
        viewModel.pointerDown(at: CGPoint(x: 80, y: 80), tolerance: 6, modifiers: [])
        viewModel.pointerUp(at: CGPoint(x: 80, y: 80))
        let committed = viewModel.commitTextEditing()

        #expect(!committed)
        #expect(viewModel.scene.allObjects.isEmpty)
        #expect(viewModel.history.undoStack.isEmpty)
    }

    @Test("Clearing an existing box to empty removes it, undoably")
    func clearingExistingRemovesIt() {
        let viewModel = EditorViewModel(scene: makeScene([textObject("Keep me")]))
        let id = viewModel.scene.allObjects[0].id
        viewModel.beginEditing(id)
        viewModel.updateEditingText("")
        viewModel.commitTextEditing()

        #expect(viewModel.scene.allObjects.isEmpty)
        #expect(viewModel.history.undoStack.count == 1)
        viewModel.undo()
        #expect(payload(of: viewModel.scene.allObjects.first)?.string == "Keep me")
    }

    @Test("Cancelling a new box discards it with no entry")
    func cancelNewBox() {
        let viewModel = EditorViewModel(scene: makeScene())
        placeAndType(viewModel, "temp")
        viewModel.cancelTextEditing()

        #expect(!viewModel.isEditingText)
        #expect(viewModel.scene.allObjects.isEmpty)
        #expect(viewModel.history.undoStack.isEmpty)
    }

    @Test("Cancelling an existing edit reverts to the original text")
    func cancelExistingReverts() {
        let viewModel = EditorViewModel(scene: makeScene([textObject("original")]))
        let id = viewModel.scene.allObjects[0].id
        viewModel.beginEditing(id)
        viewModel.updateEditingText("changed")
        viewModel.cancelTextEditing()

        #expect(payload(of: viewModel.scene.object(with: id))?.string == "original")
        #expect(viewModel.history.undoStack.isEmpty)
    }

    @Test("Switching tools commits the edit, keeping the text")
    func toolChangeCommits() {
        let viewModel = EditorViewModel(scene: makeScene())
        placeAndType(viewModel, "kept")
        viewModel.tool = .select   // tool change resolves the in-flight edit

        #expect(!viewModel.isEditingText)
        #expect(payload(of: viewModel.scene.allObjects.first)?.string == "kept")
    }
}

// MARK: - Rotation round-trip

@Suite("M5 Text rotation")
@MainActor
struct TextRotationTests {

    @Test("A rotated box un-rotates for editing and re-rotates on commit")
    func unrotateThenRestore() {
        let angle = CGFloat.pi / 6
        let viewModel = EditorViewModel(scene: makeScene([textObject("spin", rotation: angle)]))
        let id = viewModel.scene.allObjects[0].id

        viewModel.beginEditing(id)
        #expect(viewModel.scene.object(with: id)?.rotation == 0)   // flat for editing
        #expect(viewModel.editingOriginalRotation == angle)

        viewModel.updateEditingText("spin!")
        viewModel.commitTextEditing()
        #expect(viewModel.scene.object(with: id)?.rotation == angle)   // restored
    }
}

// MARK: - Text styling

@Suite("M5 Text style")
@MainActor
struct TextStyleTests {

    private func editing(_ string: String = "styled") -> (EditorViewModel, UUID) {
        let viewModel = EditorViewModel(scene: makeScene([textObject(string)]))
        let id = viewModel.scene.allObjects[0].id
        viewModel.beginEditing(id)
        return (viewModel, id)
    }

    @Test("Bold, italic, underline toggle on the edited object")
    func traitsToggle() {
        let (viewModel, id) = editing()
        viewModel.toggleTextBold()
        viewModel.toggleTextItalic()
        viewModel.toggleTextUnderline()
        let p = payload(of: viewModel.scene.object(with: id))
        #expect(p?.isBold == true)
        #expect(p?.isItalic == true)
        #expect(p?.isUnderlined == true)
        // Toggling bold again clears it.
        viewModel.toggleTextBold()
        #expect(payload(of: viewModel.scene.object(with: id))?.isBold == false)
    }

    @Test("Alignment, line height, font size, and plate apply while editing")
    func attributesApply() {
        let (viewModel, id) = editing()
        viewModel.setTextAlignment(.center)
        viewModel.setTextLineHeight(1.5)
        viewModel.setTextFontSize(72)
        viewModel.toggleTextPlate()
        let p = payload(of: viewModel.scene.object(with: id))
        #expect(p?.alignment == .center)
        #expect(p?.lineHeightMultiple == 1.5)
        #expect(p?.fontSizePx == 72)
        #expect(p?.plateColor != nil)
    }

    @Test("Style edits during a session fold into the single Text entry")
    func styleFoldsIntoTextEntry() {
        let viewModel = EditorViewModel(scene: makeScene())
        viewModel.tool = .text
        viewModel.pointerDown(at: CGPoint(x: 80, y: 80), tolerance: 6, modifiers: [])
        viewModel.pointerUp(at: CGPoint(x: 80, y: 80))
        viewModel.updateEditingText("Hi")
        viewModel.toggleTextBold()
        viewModel.setTextAlignment(.right)
        viewModel.commitTextEditing()
        // Typing + bold + align = ONE undo entry, not three.
        #expect(viewModel.history.undoStack.count == 1)
    }

    @Test("Bold on a SELECTED (not editing) text object records one entry")
    func boldOnSelectionRecordsEntry() {
        let viewModel = EditorViewModel(scene: makeScene([textObject("pick me")]))
        let id = viewModel.scene.allObjects[0].id
        viewModel.selection.select(id)

        let before = viewModel.history.undoStack.count
        viewModel.toggleTextBold()
        #expect(payload(of: viewModel.scene.object(with: id))?.isBold == true)
        #expect(viewModel.history.undoStack.count == before + 1)
    }

    @Test("hasEditableText reflects editing or a text selection")
    func hasEditableTextTracks() {
        let viewModel = EditorViewModel(scene: makeScene([textObject("t"), rectObject()]))
        #expect(!viewModel.hasEditableText)
        viewModel.selection.select(viewModel.scene.allObjects[0].id)   // the text
        #expect(viewModel.hasEditableText)
        viewModel.selection.select(viewModel.scene.allObjects[1].id)   // the rect
        #expect(!viewModel.hasEditableText)
    }

    private func rectObject() -> DrawObject {
        DrawObject(kind: .rectangle(rect: CGRect(x: 200, y: 200, width: 40, height: 40),
                                    cornerRadius: 0),
                   style: ObjectStyle(strokeColor: .black))
    }
}

// MARK: - Layout fidelity & persistence

@Suite("M5 Text layout & codec")
struct TextLayoutCodecTests {

    @Test("A committed box's bounds are the CoreText layout — no TextKit-derived size")
    func committedBoundsAreCoreText() {
        // The whole point of T14: editing-time and committed layout are the same
        // CoreText measurement, so there is no reflow pop at commit.
        let p = TextPayload(string: "Two\nlines", origin: CGPoint(x: 10, y: 10),
                            fontSizePx: 32)
        let object = DrawObject(kind: .text(p), style: ObjectStyle(strokeColor: .black))
        let coreTextSize = TextMetrics.layoutSize(of: p)
        #expect(object.bounds.size == coreTextSize)
        #expect(coreTextSize.width > 0 && coreTextSize.height > 0)
    }

    @Test("Multiline auto-height wraps taller than a single line")
    func autoHeightWraps() {
        var single = TextPayload(string: "word", fontSizePx: 24, alignment: .left)
        single.resize = .autoWidth
        var wrapped = TextPayload(string: "word word word word word word",
                                  boxSize: CGSize(width: 80, height: 0),
                                  resize: .autoHeight, fontSizePx: 24)
        wrapped.resize = .autoHeight
        #expect(TextMetrics.layoutSize(of: wrapped).height
                > TextMetrics.layoutSize(of: single).height)
    }

    @Test("Font traits and paragraph attributes survive save/load")
    func styledTextRoundTrips() throws {
        var p = TextPayload(string: "Round trip", origin: CGPoint(x: 12, y: 34),
                            resize: .fixed, fontName: "Menlo", fontSizePx: 36,
                            isBold: true, isItalic: true, isUnderlined: true,
                            alignment: .center, lineHeightMultiple: 1.4,
                            plateColor: RGBAColor(r: 1, g: 1, b: 1, a: 0.8))
        p.boxSize = CGSize(width: 220, height: 90)
        let scene = makeScene([DrawObject(kind: .text(p), style: ObjectStyle(strokeColor: .red))])

        let decoded = try SceneCodec.decode(SceneCodec.encode(scene))
        guard case .text(let d)? = decoded.allObjects.first?.kind else {
            return #expect(Bool(false))
        }
        #expect(d.string == "Round trip")
        #expect(d.fontName == "Menlo")
        #expect(d.fontSizePx == 36)
        #expect(d.isBold && d.isItalic && d.isUnderlined)
        #expect(d.alignment == .center)
        #expect(d.lineHeightMultiple == 1.4)
        #expect(d.resize == .fixed)
        #expect(d.boxSize == CGSize(width: 220, height: 90))
        #expect(d.plateColor?.a == 0.8)
    }
}
